import SwiftUI

@MainActor
@Observable
final class DashboardModel {
    var status = DeviceStatus()
    var isLoading = false
    var errorText: String?

    func refresh() async {
        isLoading = true
        errorText = nil
        let client = NovatekClient.shared
        await client.startHeartbeat()
        status = await client.fetchDeviceStatus()
        // 四项查询全部拿不到数据 → 基本可判定未连上记录仪
        if status.firmware == "未知", status.battery == nil,
           status.sdCard == nil, status.freeBytes == nil {
            errorText = "无法连接记录仪: 请确认 iPhone 已连接记录仪 Wi-Fi (网关 192.168.1.254), 并在系统弹窗中允许本地网络访问"
        }
        isLoading = false
    }
}

struct DashboardView: View {
    @State private var model = DashboardModel()
    @State private var heartbeatAt: Date?

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
                        if let heartbeatAt {
                            Label("正常", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(heartbeatAt.formatted(date: .omitted, time: .standard))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("未启动").foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("连接")
                } footer: {
                    Text("记录仪要求每 3~5 秒心跳一次, 否则主动断开 Wi-Fi; 设备忙时心跳自动让路并退避。")
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
            .task {
                // 心跳指示器每 3 秒刷新一次
                while !Task.isCancelled {
                    heartbeatAt = await NovatekClient.shared.lastHeartbeatAt
                    try? await Task.sleep(for: .seconds(3))
                }
            }
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
