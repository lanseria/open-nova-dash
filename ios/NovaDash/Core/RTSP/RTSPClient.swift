import Foundation
import Network

/// 极简 RTSP 客户端: 仅 TCP 交织模式 (RTP/AVP/TCP), 面向 H.264 裸流行车记录仪。
/// 信令 OPTIONS → DESCRIBE(解析 SDP) → SETUP → PLAY;
/// 数据面解析 '$' 交织帧中的 RTP, 解包 H.264 后按"帧"(marker 位)回调。
final class RTSPClient: @unchecked Sendable {
    enum Event {
        case connecting
        case negotiating
        case playing                  // PLAY 成功 (首帧前)
        case accessUnit([Data])       // 一帧 H.264 (NAL 列表, 可含 SPS/PPS/SEI/切片)
        case failed(String)
    }

    let onEvent: @Sendable (Event) -> Void

    private let url: URL
    private var urlString: String
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "novadash.rtsp")

    private var buffer = Data()
    private let bufferLock = NSLock()

    private var cseq = 0
    private var sessionID: String?
    private var contentBase: String?
    private var videoControl: String?
    private var payloadType: UInt8 = 96
    private var spropSPS: Data?
    private var spropPPS: Data?

    private let assembler = H264Assembler()
    private var keepaliveTask: Task<Void, Never>?
    private var reportedPlaying = false

    private let responseLock = NSLock()
    private var pendingResponse: CheckedContinuation<String, Error>?
    private var pendingTimer: Task<Void, Never>?

    enum RTSPError: Error { case timeout, connectionClosed }

    init(url: URL, onEvent: @escaping @Sendable (Event) -> Void) {
        self.url = url
        self.urlString = url.absoluteString
        self.onEvent = onEvent
    }

    // MARK: - 对外控制

    func connectAndPlay() {
        emit(.connecting)
        queue.async { self.startConnection() }
    }

    func teardown() {
        queue.async { self.shutdown(message: nil) }
    }

    // MARK: - 连接与握手

    private func startConnection() {
        guard let host = url.host else {
            shutdown(message: "RTSP 地址无效"); return
        }
        let port = UInt16(url.port ?? 554)
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            shutdown(message: "RTSP 端口无效"); return
        }
        let conn = NWConnection(
            host: NWEndpoint.Host(host), port: endpointPort, using: .tcp
        )
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.emit(.negotiating)
                self?.receiveLoop()
                Task { await self?.handshake() }
            case .failed(let error):
                self?.shutdown(message: "网络错误: \(error.localizedDescription)")
            default:
                break   // waiting/setup 属临时状态, 不中断
            }
        }
        conn.start(queue: queue)
    }

    private func handshake() async {
        do {
            _ = try await request("OPTIONS", uri: urlString)
            let describe = try await request(
                "DESCRIBE", uri: urlString, extraHeaders: ["Accept": "application/sdp"]
            )
            parseSDP(describe)
            guard let control = videoControl else {
                throw RTSPError.connectionClosed
            }
            let setup = try await request(
                "SETUP",
                uri: resolveControl(control),
                extraHeaders: ["Transport": "RTP/AVP/TCP;unicast;interleaved=0-1"]
            )
            if let session = header(of: setup, "Session") {
                sessionID = String(session.split(separator: ";").first ?? "")
            }
            _ = try await request("PLAY", uri: urlString)
            if !reportedPlaying {
                reportedPlaying = true
                emit(.playing)
            }
            startKeepalive()
        } catch {
            shutdown(message: "直播握手失败: 设备可能不支持 RTSP 或地址不正确")
        }
    }

    /// SDP: 取视频轨 control / 载荷类型 / sprop-parameter-sets (SPS+PPS)
    private func parseSDP(_ response: String) {
        contentBase = header(of: response, "Content-Base")
        var inVideo = false
        for rawLine in response.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(rawLine)
            if line.hasPrefix("m=video") { inVideo = true; continue }
            if line.hasPrefix("m=") { inVideo = false; continue }
            guard inVideo else { continue }
            if line.hasPrefix("a=control:") {
                videoControl = String(line.dropFirst("a=control:".count))
                    .trimmingCharacters(in: .whitespaces)
            } else if line.contains("H264/"), line.hasPrefix("a=rtpmap:") {
                let pt = line.dropFirst("a=rtpmap:".count).split(separator: " ").first ?? ""
                payloadType = UInt8(pt) ?? 96
            } else if line.contains("sprop-parameter-sets"), let range = line.range(of: "sprop-parameter-sets=") {
                let pair = String(line[range.upperBound...]).split(separator: ",")
                if pair.count >= 2 {
                    spropSPS = base64(String(pair[0]))
                    spropPPS = base64(String(pair[1]))
                }
            }
        }
        // SDP 带 sprop 时直接交给解码器兜底 (流内无参数集也能起播)
        if let sps = spropSPS, let pps = spropPPS {
            assembler.seed(sps: sps, pps: pps)
        }
    }

    private func base64(_ text: String) -> Data? {
        var padded = text.trimmingCharacters(in: .whitespaces)
        while padded.count % 4 != 0 { padded.append("=") }
        return Data(base64Encoded: padded)
    }

    private func resolveControl(_ control: String) -> String {
        if control.hasPrefix("rtsp://") { return control }
        if control == "*" { return urlString }
        if let base = contentBase { return base.hasSuffix("/") ? base + control : base + "/" + control }
        return urlString.hasSuffix("/") ? urlString + control : urlString + "/" + control
    }

    // MARK: - RTSP 请求 (握手/保活, 串行使用)

    private func request(
        _ method: String, uri: String, extraHeaders: [String: String] = [:]
    ) async throws -> String {
        cseq += 1
        var req = "\(method) \(uri) RTSP/1.0\r\nCSeq: \(cseq)\r\n"
        if let sessionID { req += "Session: \(sessionID)\r\n" }
        for (key, value) in extraHeaders { req += "\(key): \(value)\r\n" }
        req += "User-Agent: NovaDash/0.1\r\n\r\n"

        let response: String = try await withCheckedThrowingContinuation { continuation in
            responseLock.lock()
            pendingResponse = continuation
            responseLock.unlock()
            connection?.send(
                content: Data(req.utf8),
                completion: .contentProcessed { _ in }
            )
            pendingTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard let self, !Task.isCancelled else { return }
                self.responseLock.lock()
                let cont = self.pendingResponse
                self.pendingResponse = nil
                self.responseLock.unlock()
                cont?.resume(throwing: RTSPError.timeout)
            }
        }
        pendingTimer?.cancel()
        pendingTimer = nil

        guard response.contains(" 200 ") || response.contains(" 454 ") || response.contains(" 461 ") else {
            throw RTSPError.connectionClosed
        }
        return response
    }

    private func startKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard let self, !Task.isCancelled else { return }
                _ = try? await self.request("OPTIONS", uri: self.urlString)
            }
        }
    }

    // MARK: - 接收循环与解帧

    private func receiveLoop() {
        connection?.receive(
            minimumIncompleteLength: 1, maximumLength: 256 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.ingest(data) }
            if error != nil || isComplete {
                self.shutdown(message: error.map { "连接中断: \($0.localizedDescription)" } ?? "连接中断")
                return
            }
            self.receiveLoop()
        }
    }

    private enum Frame {
        case rtspMessage(String)
        case rtp(channel: UInt8, payload: [UInt8], marker: Bool)
    }

    private func ingest(_ data: Data) {
        bufferLock.lock()
        buffer.append(data)
        var frames: [Frame] = []
        while let frame = parseOneFrame() { frames.append(frame) }
        bufferLock.unlock()
        for frame in frames { route(frame) }
    }

    /// 交织流: '$' + 通道(1B) + 长度(2B) + 载荷; 否则是 RTSP 文本 (头 + Content-Length 体)
    private func parseOneFrame() -> Frame? {
        guard let first = buffer.first else { return nil }
        let start = buffer.startIndex
        if first == 0x24 {
            guard buffer.count >= 4 else { return nil }
            let channel = buffer[start + 1]
            let length = Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
            guard buffer.count >= 4 + length else { return nil }
            let payload = [UInt8](buffer[(start + 4)..<(start + 4 + length)])
            buffer.removeFirst(4 + length)
            return .rtp(channel: channel, payload: payload, marker: false)
        }
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerText = String(decoding: buffer[start..<headerEnd.lowerBound], as: UTF8.self)
        let contentLength = Int(header(of: headerText, "Content-Length") ?? "0") ?? 0
        let total = headerEnd.upperBound - start + contentLength
        guard buffer.count >= total else { return nil }
        let message = String(
            decoding: buffer[(headerEnd.upperBound)..<start + total], as: UTF8.self
        )
        buffer.removeFirst(total)
        return .rtspMessage(message)
    }

    private func route(_ frame: Frame) {
        switch frame {
        case .rtspMessage(let text):
            if text.hasPrefix("RTSP/") {
                deliverResponse(text)
            }
        case let .rtp(channel, payload, _):
            guard channel == 0 else { return }   // 通道 1 为 RTCP, 忽略
            handleRTP(payload)
        }
    }

    private func handleRTP(_ bytes: [UInt8]) {
        guard bytes.count >= 12, (bytes[0] & 0xC0) == 0x80 else { return }   // RTP v2
        let marker = bytes[1] & 0x80 != 0
        let packetPT = bytes[1] & 0x7F
        guard packetPT == payloadType else { return }
        let cc = Int(bytes[0] & 0x0F)
        var headerLength = 12 + cc * 4
        if bytes[0] & 0x10 != 0 {   // 扩展头
            guard bytes.count >= headerLength + 4 else { return }
            let extWords = Int(bytes[headerLength + 2]) << 8 | Int(bytes[headerLength + 3])
            headerLength += 4 + extWords * 4
        }
        guard bytes.count > headerLength else { return }

        assembler.feed(Array(bytes[headerLength...]))
        if marker {
            let unit = assembler.frameDone()
            if !unit.isEmpty {
                if !reportedPlaying {
                    reportedPlaying = true
                    emit(.playing)
                }
                onEvent(.accessUnit(unit))
            }
        }
    }

    private func deliverResponse(_ text: String) {
        responseLock.lock()
        let continuation = pendingResponse
        pendingResponse = nil
        responseLock.unlock()
        pendingTimer?.cancel()
        pendingTimer = nil
        continuation?.resume(returning: text)
    }

    // MARK: - 工具

    private func emit(_ event: Event) {
        onEvent(event)
    }

    private func shutdown(message: String?) {
        keepaliveTask?.cancel()
        keepaliveTask = nil
        connection?.stateUpdateHandler = nil
        if let connection, connection.state == .ready {
            // 尽力而为的 TEARDOWN, 不等待响应
            cseq += 1
            let req = "TEARDOWN \(urlString) RTSP/1.0\r\nCSeq: \(cseq)\r\n"
                + (sessionID.map { "Session: \($0)\r\n" } ?? "")
                + "User-Agent: NovaDash/0.1\r\n\r\n"
            connection.send(content: Data(req.utf8), completion: .contentProcessed { _ in })
        }
        connection?.cancel()
        connection = nil
        bufferLock.lock(); buffer.removeAll(); bufferLock.unlock()

        responseLock.lock()
        let continuation = pendingResponse
        pendingResponse = nil
        responseLock.unlock()
        pendingTimer?.cancel()
        continuation?.resume(throwing: RTSPError.connectionClosed)

        if let message {
            emit(.failed(message))
        }
    }

    private func header(of text: String, _ name: String) -> String? {
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}

/// RTP H.264 载荷解包: 单 NAL / STAP-A / FU-A → 完整 NAL; 按 marker 位聚合出访问单元 (帧)
final class H264Assembler {
    private var fuBuffer = Data()
    private var accessUnit: [Data] = []

    /// SDP sprop-parameter-sets 兜底: 有些流参数集只在 SDP 里出现一次
    private var seededSPS: Data?
    private var seededPPS: Data?

    func seed(sps: Data, pps: Data) {
        seededSPS = sps
        seededPPS = pps
    }

    func feed(_ payload: [UInt8]) {
        guard let first = payload.first else { return }
        let type = first & 0x1F
        switch type {
        case 1...23:
            accessUnit.append(Data(payload))
        case 24:   // STAP-A
            var index = 1
            while index + 2 <= payload.count {
                let size = Int(payload[index]) << 8 | Int(payload[index + 1])
                index += 2
                guard size > 0, index + size <= payload.count else { break }
                accessUnit.append(Data(payload[index..<(index + size)]))
                index += size
            }
        case 28:   // FU-A
            let start = payload[1] & 0x80 != 0
            let end = payload[1] & 0x40 != 0
            if start {
                fuBuffer = Data([first & 0xE0 | payload[2] & 0x1F])
            }
            guard payload.count > 2, !fuBuffer.isEmpty || start else { return }
            if start { fuBuffer.append(contentsOf: payload[3...]) }
            else { fuBuffer.append(contentsOf: payload[2...]) }
            if end {
                accessUnit.append(fuBuffer)
                fuBuffer.removeAll()
            }
        default:
            break   // MTAP/FU-B 等记录仪基本不用
        }
    }

    /// 帧结束 (RTP marker): 返回整帧 NAL 列表; 无参数集时补 SDP 里的 SPS/PPS
    func frameDone() -> [Data] {
        guard !accessUnit.isEmpty else { return [] }
        var out = accessUnit
        accessUnit.removeAll()
        let hasSPS = out.contains { $0.first.map { $0 & 0x1F } == 7 }
        let hasPPS = out.contains { $0.first.map { $0 & 0x1F } == 8 }
        if !out.isEmpty, !hasSPS, let sps = seededSPS { out.insert(sps, at: 0) }
        if !out.isEmpty, !hasPPS, let pps = seededPPS {
            let insertAt = out.contains { $0.first.map { $0 & 0x1F } == 7 } ? 1 : 0
            out.insert(pps, at: min(insertAt, out.count))
        }
        return out
    }
}
