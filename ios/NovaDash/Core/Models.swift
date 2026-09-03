import Foundation

/// 联咏 CGI 标准响应: <Function><Cmd>3001</Cmd><Status>0</Status><Value>..</Value><String>..</String></Function>
/// Status=0 成功; 负数即 Linux errno(-5 写卡失败/-22 状态不允许等, 详见 NovatekError)
struct CGIResponse: Sendable {
    let cmd: Int?
    let status: Int?
    let value: String?
    let string: String?
}

/// 一次请求的完整解析结果 (3015 文件树无 Status 包裹, 文件路径单独放)
struct RawReply: Sendable {
    let response: CGIResponse
    let filePaths: [String]
}

enum BatteryState: Int, Sendable {
    case full = 0, medium = 1, low = 2, empty = 3, exhausted = 4, charging = 5

    var label: String {
        switch self {
        case .full: return "满电"
        case .medium: return "中等"
        case .low: return "低电量"
        case .empty: return "即将耗尽"
        case .exhausted: return "已耗尽"
        case .charging: return "充电中"
        }
    }
}

enum SDCardState: Int, Sendable {
    case removed = 0, inserted = 1, locked = 2

    var label: String {
        switch self {
        case .removed: return "未插卡"
        case .inserted: return "正常"
        case .locked: return "已锁定"
        }
    }
}

struct DeviceStatus: Sendable {
    var firmware = "未知"
    var battery: BatteryState?
    var sdCard: SDCardState?
    var freeBytes: Int64?

    var freeSpaceText: String {
        guard let freeBytes else { return "未知" }
        return ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
    }
}

/// SD 卡上的一个文件 (来自 3015 文件树)
struct DashcamFile: Identifiable, Sendable {
    enum Kind: Sendable { case photo, video, other }

    /// 3015 返回的原始 Windows 风格路径, 如 A:\CARDV\PHOTO\20260901_000002.JPG
    let rawPath: String
    let kind: Kind

    var id: String { rawPath }

    var name: String {
        let parts = rawPath.split { $0 == "\\" || $0 == "/" }
        return String(parts.last ?? Substring(rawPath))
    }

    /// 下载用相对路径: 去掉 "A:" 盘符前缀, 反斜杠转正斜杠 (实测规则, hfs 服务器 200 验证通过)
    var downloadPath: String {
        var path = rawPath
        if path.hasPrefix("A:") { path.removeFirst(2) }
        return path.replacingOccurrences(of: "\\", with: "/")
    }

    static func kind(of path: String) -> Kind {
        let upper = path.uppercased()
        if upper.hasSuffix(".JPG") || upper.hasSuffix(".JPEG") { return .photo }
        if upper.hasSuffix(".TS") || upper.hasSuffix(".MP4") || upper.hasSuffix(".MOV") { return .video }
        return .other
    }
}
