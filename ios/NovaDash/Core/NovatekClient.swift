import Foundation

/// 联咏行车记录仪客户端 (860N72-SF20200714 实测协议).
///
/// 架构红线(来自 script.py 五轮实测, 详见仓库 readme "坑位说明"):
/// - HTTP 服务器单线程 → 一切请求经 AsyncSemaphore 串行, 心跳忙时让路;
/// - 读超时不重发状态命令(可能重复执行, 实测曾引发请求风暴);
/// - 心跳连续失败后退避(3s → 15s), 恢复后自动回到正常节奏;
/// - 重命令(录像/切模式)用长超时; "超时 ≠ 命令失败", 由 UI 提示稍后确认;
/// - 2001 状态机敏感: 重复开始/停止返回 -22;
/// - 下载 URL 规则: 去掉路径的 "A:" 盘符前缀 (hfs 服务器实测).
actor NovatekClient {
    static let shared = NovatekClient()

    let baseURL = URL(string: "http://192.168.1.254")!
    private let session: URLSession
    private let gate = AsyncSemaphore(value: 1)

    /// 协议要求 3~5 秒心跳一次, 否则设备主动断开 Wi-Fi
    private let heartbeatInterval: TimeInterval = 3
    /// 连续失败后的退避间隔 (设备阻塞时不再以 3s 节奏敲门)
    private let heartbeatBackoff: TimeInterval = 15

    private(set) var lastHeartbeatAt: Date?
    private var heartbeatTask: Task<Void, Never>?

    init() {
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = false        // 记录仪 Wi-Fi 无外网, 禁止回退蜂窝
        config.httpMaximumConnectionsPerHost = 1   // 单线程服务器
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 0      // 0 = 不限总时长(大文件下载)
        session = URLSession(configuration: config)
    }

    // MARK: - 底层请求

    private func makeRequest(cmd: Int, par: Int? = nil, str: String? = nil) throws -> URLRequest {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/"),
            resolvingAgainstBaseURL: false
        ) ?? URLComponents(string: "http://192.168.1.254/")!
        var items = [
            URLQueryItem(name: "custom", value: "1"),
            URLQueryItem(name: "cmd", value: String(cmd)),
        ]
        if let par { items.append(URLQueryItem(name: "par", value: String(par))) }
        if let str { items.append(URLQueryItem(name: "str", value: str)) }
        components.queryItems = items
        guard let url = components.url else {
            throw NovatekError.badResponse("URL 构造失败")
        }
        var request = URLRequest(url: url)
        // 查询类命令 5s 足够(实测局域网 <1s); 重命令由调用方显式传长超时
        request.timeoutInterval = 5
        return request
    }

    /// 发送 CGI 请求并解析 XML (不做 Status 校验); 已串行化
    private func request(
        cmd: Int, par: Int? = nil, str: String? = nil,
        timeout: TimeInterval = 5
    ) async throws -> RawReply {
        await gate.wait()
        defer { gate.signal() }
        var request = try makeRequest(cmd: cmd, par: par, str: str)
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw NovatekError.badResponse("HTTP \(code)")
            }
            return NovatekXMLParser.parse(data)
        } catch let error as NovatekError {
            throw error
        } catch {
            // 读超时不重发: 命令可能已被设备执行, 重复执行有风险
            throw NovatekError.transport(error.localizedDescription)
        }
    }

    /// 发送 CGI 命令, Status 非 0 时抛出 NovatekError
    @discardableResult
    func send(
        _ cmd: Int, par: Int? = nil, str: String? = nil,
        timeout: TimeInterval = 8
    ) async throws -> CGIResponse {
        let reply = try await request(cmd: cmd, par: par, str: str, timeout: timeout)
        guard let status = reply.response.status else {
            throw NovatekError.badResponse("响应缺少 Status 字段")
        }
        if status != 0 {
            throw NovatekError.deviceStatus(status)
        }
        return reply.response
    }

    // MARK: - 心跳

    func startHeartbeat() {
        heartbeatTask?.cancel()
        lastHeartbeatAt = nil
        heartbeatTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                // actor 的 let 属性(Sendable)可同步读取; 连续失败后退避
                let interval = failures >= 2 ? (self?.heartbeatBackoff ?? 15) : (self?.heartbeatInterval ?? 3)
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                if await self.pingOnce() {
                    failures = 0
                } else {
                    failures += 1
                }
            }
        }
    }

    func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func pingOnce() async -> Bool {
        // 有命令正在处理时让路; 设备显然活着, 视为心跳正常
        guard gate.tryWait() else { return true }
        defer { gate.signal() }
        do {
            var request = try makeRequest(cmd: 3016)
            request.timeoutInterval = 3
            _ = try await session.data(for: request)
            lastHeartbeatAt = Date()
            return true
        } catch {
            return false
        }
    }

    // MARK: - 设备状态

    /// 四个只读查询(3012/3024/3017/3019), 单项失败不影响其余
    func fetchDeviceStatus() async -> DeviceStatus {
        var status = DeviceStatus()
        if let reply = try? await request(cmd: 3012) {
            status.firmware = reply.response.string ?? reply.response.value ?? "未知"
        }
        if let reply = try? await request(cmd: 3024) {
            status.sdCard = reply.response.value.flatMap { Int($0) }.flatMap(SDCardState.init)
        }
        if let reply = try? await request(cmd: 3017) {
            status.freeBytes = reply.response.value.flatMap { Int64($0) }
        }
        if let reply = try? await request(cmd: 3019) {
            status.battery = reply.response.value.flatMap { Int($0) }.flatMap(BatteryState.init)
        }
        return status
    }

    // MARK: - 文件列表

    /// 拉取 SD 卡文件列表; 直接查询被拒(-3, 录像中)时走"回放模式"标准流程
    func fetchFiles() async throws -> [DashcamFile] {
        do {
            return try await fetchFilesDirect()
        } catch NovatekError.deviceStatus(-3) {
            try? await send(3001, par: 2, timeout: 12)   // 切回放模式
            try? await Task.sleep(for: .seconds(2))
            let files = try await fetchFilesDirect()
            try? await send(3001, par: 0, timeout: 12)   // 切回视频模式
            return files
        }
    }

    private func fetchFilesDirect() async throws -> [DashcamFile] {
        let reply = try await request(cmd: 3015, timeout: 12)
        return reply.filePaths.map { DashcamFile(rawPath: $0, kind: DashcamFile.kind(of: $0)) }
    }

    // MARK: - 拍照

    /// 远程拍照: 优先直接拍(实测录像中也返回成功); -22(状态不允许)时
    /// 降级为"切照片模式 → 拍照 → 切回视频模式".
    /// 返回照片原始路径(A:\...), 为 nil 表示已接受但未返回路径(到相册确认).
    func capturePhoto() async throws -> String? {
        do {
            let reply = try await request(cmd: 1001, timeout: 8)
            return reply.filePaths.first
        } catch NovatekError.deviceStatus(-22) {
            try await send(3001, par: 1, timeout: 12)    // 切照片模式
            try? await Task.sleep(for: .seconds(1.5))
            let reply = try await request(cmd: 1001, timeout: 8)
            try? await send(3001, par: 0, timeout: 12)   // 切回视频模式
            guard reply.response.status == 0 else {
                throw NovatekError.deviceStatus(reply.response.status ?? -1)
            }
            return reply.filePaths.first
        }
    }

    // MARK: - 录像控制

    enum RecordOutcome: Equatable {
        case started, stopped
        /// -22: 与当前状态重复, 语义化为"已处于目标状态", 不是错误
        case alreadyStarted, alreadyStopped
    }

    /// 录像控制 (2001&str=1/0). 重命令, 超时 ≠ 失败 —— 调用方应捕获异常并提示稍后确认.
    func setRecording(_ on: Bool) async throws -> RecordOutcome {
        let reply = try await request(cmd: 2001, str: on ? "1" : "0", timeout: 15)
        switch reply.response.status {
        case 0:
            return on ? .started : .stopped
        case -22:
            return on ? .alreadyStarted : .alreadyStopped
        default:
            throw NovatekError.deviceStatus(reply.response.status ?? -1)
        }
    }

    // MARK: - 下载

    /// 下载文件到 App 文档目录, 返回本地 URL. progress 在后台线程回调 (0...1).
    /// 下载期间持有串行通道, 心跳自动让路.
    func download(
        _ file: DashcamFile,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        await gate.wait()
        defer { gate.signal() }

        // hfs 文件服务器 (Connection: close, 不复用连接): 逐段编码路径
        var url = baseURL
        for segment in file.downloadPath.split(separator: "/") {
            url.appendPathComponent(String(segment))
        }

        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NovatekError.badResponse("下载失败 HTTP \(code)")
        }

        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destination = directory.appendingPathComponent(file.name)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        let total = Double(http.expectedContentLength)  // <0 表示未知
        var received = 0.0
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            buffer.append(byte)
            received += 1
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                if total > 0 { progress(min(received / total, 1)) }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
        progress(1)
        return destination
    }
}
