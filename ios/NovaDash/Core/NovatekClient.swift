import Foundation

/// 联咏行车记录仪客户端 (860N72-SF20200714 实测协议).
///
/// 架构红线(来自 script.py 五轮实测, 详见仓库 readme "坑位说明"):
/// - HTTP 服务器单线程 → 一切请求经 AsyncSemaphore 串行, 心跳忙时让路;
/// - 读超时不重发状态命令(可能重复执行, 实测曾引发请求风暴);
/// - 连接保活由 ConnectionModel 驱动: 手动连接后按 3s 节奏 ping,
///   连续失败判定断开并回到待连接页面;
/// - 重命令(录像/切模式)用长超时; "超时 ≠ 命令失败", 由 UI 提示稍后确认;
/// - 2001 状态机敏感: 重复开始/停止返回 -22;
/// - 下载 URL 规则: 去掉路径的 "A:" 盘符前缀 (hfs 服务器实测).
actor NovatekClient {
    static let shared = NovatekClient()

    let baseURL = URL(string: "http://192.168.1.254")!
    private let session: URLSession
    private let gate = AsyncSemaphore(value: 1)

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

    // MARK: - 连接探测

    /// 单次存活探测 (cmd 3016). 有命令占用串行通道时直接视为存活, 不打扰设备。
    /// 是否断开、何时停止请求, 由 ConnectionModel 决策。
    func ping() async -> Bool {
        guard gate.tryWait() else { return true }
        defer { gate.signal() }
        do {
            var request = try makeRequest(cmd: 3016)
            request.timeoutInterval = 3
            _ = try await session.data(for: request)
            return true
        } catch {
            return false
        }
    }

    // MARK: - 设备状态

    /// 单查 2016 当前录像片段秒数: nil=查询失败, 0=未录像, >0=录像中
    /// (心跳跟随查询/控制命令后即时复核用, 比 fetchDeviceStatus 轻量)
    func fetchRecordingSeconds() async -> Int? {
        guard let reply = try? await request(cmd: 2016) else { return nil }
        return reply.response.value.flatMap { Int($0) }
    }

    /// 五个只读查询(3012/3024/3017/3019/2016), 单项失败不影响其余
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
        if let reply = try? await request(cmd: 2016) {
            status.recordingSeconds = reply.response.value.flatMap { Int($0) }
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
            try? await send(3001, par: 1, timeout: 12)   // 切回录像模式 (2026-09 实测: par=1=录像)
            return files
        }
    }

    private func fetchFilesDirect() async throws -> [DashcamFile] {
        let reply = try await request(cmd: 3015, timeout: 12)
        return reply.filePaths.map { DashcamFile(rawPath: $0, kind: DashcamFile.kind(of: $0)) }
    }

    // MARK: - 拍照

    /// 远程拍照 (2026-09-19 扫描台定稿: 本机录像中直接 1001 无效果, 只认"照片模式直拍"):
    /// ① 3001&par=0 切照片模式 (设备 3037 回报 4) → ② 1001 拍照 →
    /// ③ 3001&par=1 切回录像模式 → ④ 2001&par=1 恢复录像 (最后一步必须做);
    /// 中途出错仍尽力切回+恢复录像; 读超时 ≠ 失败 (可能已拍, 不可重发), 返回 nil 引导到相册确认。
    func capturePhoto() async throws -> String? {
        do {
            try await send(3001, par: 0, timeout: 12)    // 切照片模式 (3037=4)
            try? await Task.sleep(for: .seconds(2))
            let reply = try await request(cmd: 1001, timeout: 8)
            let path = reply.filePaths.first
            // 拍完无论成败都恢复行车状态 (切回录像模式 + 恢复循环录像)
            try? await send(3001, par: 1, timeout: 12)   // 切回录像模式 (3037=1)
            try? await Task.sleep(for: .seconds(1.5))
            _ = try? await send(2001, par: 1, timeout: 15)   // 恢复录像 (本机只认 par=)
            guard reply.response.status == 0 else {
                throw NovatekError.deviceStatus(reply.response.status ?? -1)
            }
            return path
        } catch NovatekError.transport {
            // 已进入照片模式后失联: 尽力恢复, 照片可能已拍, 由用户到相册确认
            try? await send(3001, par: 1, timeout: 12)
            try? await Task.sleep(for: .seconds(1.5))
            _ = try? await send(2001, par: 1, timeout: 15)
            return nil
        }
    }

    // MARK: - 原生视频封面

    /// 设备原生缩略图 (2026-09-19 探测定稿): 下载 URL 追加 `?custom=1&cmd=4001`,
    /// 固件直接返回内嵌 JPEG (实测约 28KB)。`?4001` 短形式与 CGI 4001/4002 本机均不支持。
    /// 命中后写入预览缓存并返回文件 URL; 非图片/失败返回 nil (调用方回退 FFmpeg 抽帧)。
    /// 低优先级排队, 不挡控制命令; 首字节校验 JPEG 魔数, 上限 512KB (防服务器忽略参数回吐整段视频)。
    func fetchNativeThumbnail(for file: DashcamFile) async -> URL? {
        let destination = previewDirectory.appendingPathComponent("native_" + file.name + ".jpg")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path),
           let size = attrs[.size] as? Int64, size > 0 {
            return destination
        }
        guard var components = URLComponents(url: remoteURL(of: file), resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "custom", value: "1"),
            URLQueryItem(name: "cmd", value: "4001"),
        ]
        guard let thumbURL = components.url else { return nil }

        await gate.wait(priority: .low)
        defer { gate.signal() }
        // bytes 流式读取: 首字节非 JPEG 魔数立即断开 (防服务器忽略参数回吐整段视频);
        // 超时沿用 session 配置的 8s request timeout
        guard let (bytes, response) = try? await session.bytes(from: thumbURL),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }
        var data = Data()
        data.reserveCapacity(64 * 1024)
        do {
            for try await byte in bytes {
                if data.isEmpty && byte != 0xFF { return nil }   // 非 JPEG 开头 (如 TS 的 0x47) → 不支持
                data.append(byte)
                if data.count >= 512 * 1024 { break }
            }
        } catch {
            return nil
        }
        guard data.prefix(3) == Data([0xFF, 0xD8, 0xFF]) else { return nil }
        try? data.write(to: destination)
        return destination
    }

    // MARK: - 录像控制

    enum RecordOutcome: Equatable {
        case started, stopped
        /// -22: 与当前状态重复, 语义化为"已处于目标状态", 不是错误
        case alreadyStarted, alreadyStopped
        /// 读超时: 指令可能已生效但设备忙无法回执 (本机 2001 无参查询 -21, 无法远程确认)
        case sentUnconfirmed
    }

    /// 录像控制 (2001&par=1/0, 2026-09-18 扫描台实测定稿: 本机只认 par=, str= 无效果).
    /// 读超时不重发, 轮询心跳等设备恢复后返回 sentUnconfirmed.
    func setRecording(_ on: Bool) async throws -> RecordOutcome {
        do {
            let reply = try await request(cmd: 2001, par: on ? 1 : 0, timeout: 15)
            switch reply.response.status {
            case 0:
                return on ? .started : .stopped
            case -22:
                return on ? .alreadyStarted : .alreadyStopped
            default:
                throw NovatekError.deviceStatus(reply.response.status ?? -1)
            }
        } catch NovatekError.transport {
            // 超时 ≠ 失败: 只等设备恢复 (心跳), 绝不重发 2001, 防止请求风暴
            var waited: TimeInterval = 0
            while waited < 30 {
                try? await Task.sleep(for: .seconds(2))
                waited += 2
                if await ping() { return .sentUnconfirmed }
            }
            return .sentUnconfirmed
        }
    }

    // MARK: - 下载

    /// 下载文件到 App 文档目录 (导出用), 返回本地 URL. progress 在后台线程回调 (0...1).
    /// 下载期间持有串行通道, 心跳自动让路.
    func download(
        _ file: DashcamFile,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destination = directory.appendingPathComponent(file.name)
        try await streamToFile(file, to: destination, progress: progress)
        return destination
    }

    /// 预览缓存目录 (预览播放/生成封面共用; 系统可自动清理)
    private var previewDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("NovaDashPreview", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 完整下载到缓存目录 (点击卡片预览用); 已缓存则直接复用.
    func fetchPreviewFile(
        _ file: DashcamFile,
        progress: @Sendable @escaping (Double) -> Void = { _ in }
    ) async throws -> URL {
        let destination = previewDirectory.appendingPathComponent(file.name)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path),
           let size = attrs[.size] as? Int64, size > 0 {
            progress(1)
            return destination
        }
        try await streamToFile(file, to: destination, progress: progress)
        return destination
    }

    /// 已缓存的完整预览文件 (有则返回地址, 不触发下载); 供封面兜底抽帧用
    func cachedPreviewURL(for file: DashcamFile) -> URL? {
        let destination = previewDirectory.appendingPathComponent(file.name)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path),
           let size = attrs[.size] as? Int64, size > 0 {
            return destination
        }
        return nil
    }

    /// 只取文件头部 maxBytes 字节后提前断开 (视频封面用, 无论服务器是否支持 Range).
    func fetchHead(_ file: DashcamFile, maxBytes: Int) async throws -> URL {
        let destination = previewDirectory.appendingPathComponent("head_" + file.name)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path),
           let size = attrs[.size] as? Int64, size > 0 {
            return destination
        }
        // 低优先级排队: 不挡住状态页/控制命令, 但仍与它们互斥串行
        await gate.wait(priority: .low)
        defer { gate.signal() }
        let (bytes, response) = try await session.bytes(from: remoteURL(of: file))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NovatekError.badResponse("下载失败 HTTP \(code)")
        }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var received = 0
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            buffer.append(byte)
            received += 1
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
            if received >= maxBytes { break }   // 提前断开, 剩余数据由连接关闭丢弃
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
        return destination
    }

    /// 设备上文件的 HTTP 地址 (hfs 文件服务器)
    private func remoteURL(of file: DashcamFile) -> URL {
        var url = baseURL
        for segment in file.downloadPath.split(separator: "/") {
            url.appendPathComponent(String(segment))
        }
        return url
    }

    /// 相册在线播放用的流媒体地址 (FFmpeg 直接拉 HTTP-TS, 无需先下载)
    func streamURL(for file: DashcamFile) -> URL {
        remoteURL(of: file)
    }

    /// HEAD 请求获取文件大小; 服务器不支持或失败返回 nil
    func fetchFileSize(for file: DashcamFile) async -> Int64? {
        await gate.wait()
        defer { gate.signal() }
        var request = URLRequest(url: remoteURL(of: file))
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200, http.expectedContentLength >= 0 else {
            return nil
        }
        return http.expectedContentLength
    }

    /// 逐段落盘 (hfs 服务器 Connection: close, 不复用连接), 期间持有串行通道.
    /// 低优先级: 批量下载不挡住高优先级的状态查询与控制命令.
    private func streamToFile(
        _ file: DashcamFile,
        to destination: URL,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        await gate.wait(priority: .low)
        defer { gate.signal() }
        let (bytes, response) = try await session.bytes(from: remoteURL(of: file))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NovatekError.badResponse("下载失败 HTTP \(code)")
        }

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
    }
}
