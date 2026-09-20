import Foundation
import Observation

/// 控制台里的一条请求记录
struct ConsoleEntry: Identifiable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case command = "命令"
        case heartbeat = "心跳"
        case download = "下载"
        case event = "事件"

        var tint: String {
            switch self {
            case .command: return "blue"
            case .heartbeat: return "green"
            case .download: return "orange"
            case .event: return "purple"
            }
        }
    }

    let id: Int
    let time: Date
    let kind: Kind
    /// 主标题, 如 "cmd=2016" / "下载 xxx.TS" / "开始直播"
    let title: String
    /// 请求参数或完整 URL
    let detail: String?
    /// 耗时 (秒); 事件类无耗时为 0
    let duration: TimeInterval
    let ok: Bool
    /// 回执摘要或错误说明
    let result: String

    var durationText: String {
        duration > 0 ? String(format: "%.0f ms", duration * 1000) : "—"
    }

    var timeText: String {
        Self.timeFormatter.string(from: time)
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

/// 请求控制台: 汇聚 App 发往设备的每一次请求 (CGI 命令/心跳/文件下载)
/// 以及关键播放事件, 供排查"控制无效果/超时/重播失败"这类问题。
///
/// 记录侧: NovatekClient (actor) 与各视图直接调用 nonisolated log(),
/// 经 MainActor Task 落账 —— 设备请求本身经串行信号量按序完成, 到账顺序即请求顺序。
@MainActor
@Observable
final class RequestConsole {
    /// nonisolated(unsafe): 引用本身不可变, 实例状态全部 @MainActor 保护;
    /// 供任意线程/actor 调用 nonisolated 的 log() 落账到主线程
    nonisolated(unsafe) static let shared = RequestConsole()

    /// 新记录在前; 超出容量丢弃最旧的 (心跳 3s 两条, 300条约够回溯 10~15 分钟)
    private(set) var entries: [ConsoleEntry] = []
    var paused = false

    private var nextID = 0
    private let capacity = 300

    /// 仅初始化存储属性默认值, 不触碰隔离状态, 供任意线程首次访问 shared 时安全构造
    nonisolated init() {}

    nonisolated func log(
        kind: ConsoleEntry.Kind,
        title: String,
        detail: String? = nil,
        duration: TimeInterval = 0,
        ok: Bool,
        result: String
    ) {
        Task { @MainActor in
            self.append(
                kind: kind, title: title, detail: detail,
                duration: duration, ok: ok, result: result
            )
        }
    }

    func clear() {
        entries = []
    }

    /// 全部记录拼接成文本 (复制/分享排查用)
    var exportText: String {
        let lines = entries.reversed().map { entry in
            var line = "[\(entry.timeText)] \(entry.kind.rawValue) \(entry.title)"
            if let detail = entry.detail {
                line += " | \(detail)"
            }
            line += " | \(entry.durationText) | \(entry.ok ? "OK" : "失败") | \(entry.result)"
            return line
        }
        return lines.joined(separator: "\n")
    }

    private func append(
        kind: ConsoleEntry.Kind,
        title: String,
        detail: String?,
        duration: TimeInterval,
        ok: Bool,
        result: String
    ) {
        guard !paused else { return }
        nextID += 1
        let entry = ConsoleEntry(
            id: nextID,
            time: Date(),
            kind: kind,
            title: title,
            detail: detail,
            duration: duration,
            ok: ok,
            result: result
        )
        entries.insert(entry, at: 0)
        if entries.count > capacity {
            entries.removeLast(entries.count - capacity)
        }
    }
}
