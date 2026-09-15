import Foundation
import Observation

/// 全局连接状态机: 待连接 → 连接中 → 已连接。
/// 只有手动点击连接才会发起请求; 已连接期间由心跳监控, 连续失败即判定断开,
/// 自动回到待连接页面并停止一切后台请求。
@MainActor
@Observable
final class ConnectionModel {
    enum State: Equatable {
        case disconnected   // 待连接 (初始/手动断开/心跳失败)
        case connecting     // 正在探测设备
        case connected      // 已连接, 心跳监控中
    }

    /// 协议要求 3~5 秒心跳一次, 否则设备主动断开 Wi-Fi
    private let heartbeatInterval: TimeInterval = 3
    /// 连续失败这么多次才判定断开 (约 9~12 秒, 容忍设备瞬时忙碌)
    private let failureThreshold = 3

    private(set) var state: State = .disconnected
    private(set) var lastHeartbeatAt: Date?
    var errorText: String?

    private var monitorTask: Task<Void, Never>?

    var isConnected: Bool { state == .connected }

    /// 手动连接: 探测通过后进入心跳监控
    func connect() async {
        guard state != .connected else { return }
        state = .connecting
        errorText = nil

        var alive = false
        var attempts = 0
        while !alive, attempts < 3 {
            attempts += 1
            alive = await NovatekClient.shared.ping()
        }
        guard alive else {
            state = .disconnected
            errorText = "无法连接记录仪 (192.168.1.254): 请确认 iPhone 已连接记录仪 Wi-Fi, 并在系统弹窗中允许本地网络访问"
            return
        }

        lastHeartbeatAt = Date()
        state = .connected
        startMonitoring()
    }

    /// 手动断开: 停止心跳监控, 回到待连接页面
    func disconnect() {
        stopMonitoring()
        lastHeartbeatAt = nil
        state = .disconnected
    }

    private func startMonitoring() {
        stopMonitoring()
        let interval = heartbeatInterval
        let threshold = failureThreshold
        monitorTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                if await NovatekClient.shared.ping() {
                    failures = 0
                    self.lastHeartbeatAt = Date()
                } else {
                    failures += 1
                    if failures >= threshold {
                        self.handleLostConnection()
                        return
                    }
                }
            }
        }
    }

    private func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    private func handleLostConnection() {
        stopMonitoring()
        lastHeartbeatAt = nil
        state = .disconnected
        errorText = "连接已断开, 请检查记录仪后重新连接"
    }
}
