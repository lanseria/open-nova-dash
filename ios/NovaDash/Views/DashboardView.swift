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
        status = await NovatekClient.shared.fetchDeviceStatus()
        // 四项查询全部拿不到数据 → 设备可能正忙或已断开
        if status.firmware == "未知", status.battery == nil,
           status.sdCard == nil, status.freeBytes == nil {
            errorText = "设备无响应: 可能正忙, 请稍后下拉刷新; 若心跳已断开将自动返回待连接页面"
        }
        isLoading = false
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
