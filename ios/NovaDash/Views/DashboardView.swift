import SwiftUI

@MainActor
@Observable
final class DashboardModel {
    var status = DeviceStatus()
    var isLoading = false
    var errorText: String?

    func refresh() async {
        // 防重入: 切换标签页会重复触发 .task, 不再叠加排队
        guard !isLoading else { return }
        isLoading = true
        errorText = nil
        // 总超时兜底: 设备被大文件下载占住时, 查询可能长时间排队, 不让"正在查询"永远挂着
        if let status = await withTimeout(seconds: 20, operation: {
            await NovatekClient.shared.fetchDeviceStatus()
        }) {
            self.status = status
            // 四项查询全部拿不到数据 → 设备可能正忙或已断开
            if status.firmware == "未知", status.battery == nil,
               status.sdCard == nil, status.freeBytes == nil {
                errorText = "设备无响应: 可能正忙, 请稍后下拉刷新; 若心跳已断开将自动返回待连接页面"
            }
        } else {
            errorText = "查询超时: 设备正忙 (可能在大文件下载/录像), 请稍后下拉刷新"
        }
        isLoading = false
    }
}

/// 给不可取消的串行队列查询加超时; 超时返回 nil (原任务会在后台自然结束)
@MainActor
private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async -> T
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

struct DashboardView: View {
    @Environment(ConnectionModel.self) private var connection
    @State private var model = DashboardModel()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("固件版本", value: model.status.firmware, icon: "cpu")
                    row("电池", value: model.status.battery?.label ?? "未知", icon: "battery.100")
                    row("SD 卡", value: model.status.sdCard?.label ?? "未知", icon: "sdcard")
                    row("剩余空间", value: model.status.freeSpaceText, icon: "externaldrive")
                        .foregroundStyle(
                            model.status.freeBytes.map { $0 < 500 * 1024 * 1024 } == true
                                ? .red : .primary
                        )
                } header: {
                    Text("设备状态")
                } footer: {
                    if (model.status.freeBytes ?? Int64.max) < 500 * 1024 * 1024 {
                        Text("⚠️ 卡快满: 拍照/录像会失败(错误码 -5/-22), 请备份后在设备上格式化")
                    }
                }

                Section {
                    HStack {
                        Image(systemName: "wifi")
                        Text("心跳")
                        Spacer()
                        if let heartbeatAt = connection.lastHeartbeatAt {
                            Label("正常", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(heartbeatAt.formatted(date: .omitted, time: .standard))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("等待响应").foregroundStyle(.secondary)
                        }
                    }
                    Button(role: .destructive) {
                        connection.disconnect()
                    } label: {
                        Label("断开连接", systemImage: "wifi.slash")
                    }
                    .disabled(model.isLoading)
                } header: {
                    Text("连接")
                } footer: {
                    Text("每 3 秒心跳一次保持连接; 连续失败将自动返回待连接页面。设备忙时心跳自动让路。")
                }

                if let error = model.errorText {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("NovaDash")
            .refreshable { await model.refresh() }
            .task { await model.refresh() }
            .overlay {
                if model.isLoading {
                    ProgressView("正在查询…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func row(_ title: String, value: String, icon: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}
