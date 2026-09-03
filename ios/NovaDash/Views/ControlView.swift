import SwiftUI

@MainActor
@Observable
final class ControlModel {
    var busyText: String?
    var resultText: String?
    var errorText: String?

    private func run(_ text: String, _ work: () async throws -> String) async {
        busyText = text
        resultText = nil
        errorText = nil
        do {
            resultText = try await work()
        } catch {
            errorText = NovatekError.describe(error)
        }
        busyText = nil
    }

    func capture() async {
        await run("正在拍照…") {
            let path = try await NovatekClient.shared.capturePhoto()
            if let path {
                let name = DashcamFile(rawPath: path, kind: .other).name
                return "已拍照: \(name)"
            }
            return "拍照指令已接受 (未返回路径, 请到相册确认)"
        }
    }

    func record(_ on: Bool) async {
        await run(on ? "正在开始录像… (设备可能忙十几秒)" : "正在停止录像…") {
            let outcome = try await NovatekClient.shared.setRecording(on)
            switch outcome {
            case .started: return "已开始录像"
            case .stopped: return "已停止录像"
            case .alreadyStarted: return "设备本就在录像中"
            case .alreadyStopped: return "设备本就已停止"
            }
        }
    }
}

struct ControlView: View {
    @State private var model = ControlModel()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Task { await model.capture() }
                    } label: {
                        Label("立即拍照", systemImage: "camera.fill")
                    }
                    .disabled(model.busyText != nil)
                } header: {
                    Text("远程拍照")
                } footer: {
                    Text("优先直接拍照; 状态不允许时自动切换照片模式拍完再切回(约 5 秒)。若提示存储写入失败, 请备份后在设备上格式化 SD 卡。")
                }

                Section {
                    Button {
                        Task { await model.record(true) }
                    } label: {
                        Label("开始录像", systemImage: "record.circle")
                    }
                    .disabled(model.busyText != nil)
                    Button(role: .destructive) {
                        Task { await model.record(false) }
                    } label: {
                        Label("停止录像", systemImage: "stop.circle")
                    }
                    .disabled(model.busyText != nil)
                } header: {
                    Text("录像控制")
                } footer: {
                    Text("实测提示: 命令后设备可能忙十几秒, 期间其他操作请稍候; 超时不代表命令失败。行车记录仪开机自动循环录像, 此开关为手动补充控制。")
                }

                if let busy = model.busyText {
                    Section {
                        HStack {
                            ProgressView()
                            Text(busy)
                        }
                    }
                }
                if let result = model.resultText {
                    Section {
                        Label(result, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                if let error = model.errorText {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("控制")
        }
    }
}
