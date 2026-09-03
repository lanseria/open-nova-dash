import Foundation
import os

/// 轻量异步信号量.
/// 联咏固件的 HTTP 服务器是单线程的: 并发请求会导致连接被重置/服务长时间无响应,
/// 因此一切请求(含心跳)必须经它串行 —— 对应 Python 版 script.py 的 CMD_LOCK 设计.
final class AsyncSemaphore: @unchecked Sendable {
    private struct State {
        var permits: Int
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State(permits: 1))

    init(value: Int) {
        precondition(value >= 1)
        // 本项目固定单许可(串行); 如需多许可可改为构造时传入
        precondition(value == 1, "当前实现按单许可优化")
    }

    /// 阻塞等待一个许可
    func wait() async {
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
                    s.waiters.append(continuation)
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

    func signal() {
        state.withLock { s in
            if s.waiters.isEmpty {
                s.permits += 1
            } else {
                s.waiters.removeFirst().resume()
            }
        }
    }
}
