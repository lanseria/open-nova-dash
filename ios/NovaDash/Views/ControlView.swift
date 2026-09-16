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
    @State private var stream = RTSPStreamModel()
    @AppStorage("rtspURL") private var rtspURL = "rtsp://192.168.1.254/stream0"

    var body: some View {
        NavigationStack {
            List {
                liveSection

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
            .onDisappear { stream.stop() }
        }
    }

    // MARK: - RTSP 实时流

    @ViewBuilder
    private var liveSection: some View {
        Section {
            switch stream.phase {
            case .streaming:
                RTSPSurface(model: stream)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets())
                    .background(Color.black)
                LabeledContent("帧数", value: "\(stream.frameCount)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button(role: .destructive) {
                    stream.stop()
                } label: {
                    Label("停止直播", systemImage: "stop.fill")
                }

            case .connecting:
                HStack {
                    ProgressView()
                    Text("正在连接 \(rtspURL) …")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button(role: .destructive) {
                    stream.stop()
                } label: {
                    Label("取消", systemImage: "xmark.circle")
                }

            case .failed(let message):
                TextField("RTSP 地址", text: $rtspURL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.footnote)
                Menu {
                    ForEach(Self.presets, id: \.self) { preset in
                        Button(preset) { rtspURL = preset }
                    }
                } label: {
                    Label("常用地址", systemImage: "list.bullet")
                }
                Button {
                    stream.start(urlString: rtspURL)
                } label: {
                    Label("重新连接", systemImage: "play.rectangle.fill")
                }
                .disabled(rtspURL.isEmpty)

            case .idle:
                TextField("RTSP 地址", text: $rtspURL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Menu {
                    ForEach(Self.presets, id: \.self) { preset in
                        Button(preset) { rtspURL = preset }
                    }
                } label: {
                    Label("常用地址", systemImage: "list.bullet")
                }
                Button {
                    stream.start(urlString: rtspURL)
                } label: {
                    Label("开始直播", systemImage: "play.rectangle.fill")
                }
                .disabled(rtspURL.isEmpty)
            }
        } header: {
            Text("实时视频流 (RTSP)")
        } footer: {
            Text("通过 RTSP/TCP 拉流并在本机硬解 (H.264)。不同固件的流地址不同, 可在「常用地址」里切换; 直播时设备较忙, 文件下载请稍后再试。离开本页自动断开。")
        }
    }

    private static let presets = [
        "rtsp://192.168.1.254/stream0",
        "rtsp://192.168.1.254/ch00_0.h264",
        "rtsp://192.168.1.254/live/ch00_0",
        "rtsp://192.168.1.254/h264",
    ]
}
