import Foundation
import os

/// 轻量异步信号量 (带优先级).
/// 联咏固件的 HTTP 服务器是单线程的: 并发请求会导致连接被重置/服务长时间无响应,
/// 因此一切请求(含心跳)必须经它串行 —— 对应 Python 版 script.py 的 CMD_LOCK 设计.
/// 命令/状态查询用高优先级 (插队在大文件下载前), 封面/预览下载用低优先级,
/// 避免状态页被相册的批量下载长时间卡住.
final class AsyncSemaphore: @unchecked Sendable {
    enum Priority: Comparable {
        case high   // 命令与状态查询
        case low    // 封面/预览等批量下载
    }

    private struct State {
        var permits: Int
        var waiters: [(priority: Priority, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State(permits: 1))

    init(value: Int) {
        precondition(value >= 1)
        // 本项目固定单许可(串行); 如需多许可可改为构造时传入
        precondition(value == 1, "当前实现按单许可优化")
    }

    /// 阻塞等待一个许可 (高优先级等待者先被唤醒)
    func wait(priority: Priority = .high) async {
        let acquired = state.withLock { s -> Bool in
            if s.permits > 0 {
                s.permits -= 1
                return true
            }
            return false
        }
        if acquired { return }
        await withCheckedContinuation { continuation in
            state.withLock { s in
                if s.permits > 0 {
                    s.permits -= 1
                    continuation.resume()
                } else {
                    s.waiters.append((priority, continuation))
                }
            }
        }
    }

    /// 非阻塞获取; 心跳在忙时用它"让路", 不与业务命令抢串行通道
    func tryWait() -> Bool {
        state.withLock { s in
            guard s.permits > 0 else { return false }
            s.permits -= 1
            return true
        }
    }

    /// 限时等待; 超时返回 false (用于状态页不被下载无限期卡死)
    func tryWait(timeout: TimeInterval, priority: Priority = .high) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !tryWait() {
            if Date() >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    func signal() {
        state.withLock { s in
            if s.waiters.isEmpty {
                s.permits += 1
            } else {
                // 高优先级先出队
                if let idx = s.waiters.firstIndex(where: { $0.priority == .high }) {
                    s.waiters.remove(at: idx).continuation.resume()
                } else {
                    s.waiters.removeFirst().continuation.resume()
                }
            }
        }
    }
}
