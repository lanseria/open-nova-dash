import SwiftUI
import KSPlayer

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
            return "拍照指令已发出 (设备忙未回执, 请到相册确认)"
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
            case .sentUnconfirmed: return "指令已发出, 设备忙未回执; 请稍后通过画面或指示灯确认 (超时不代表失败)"
            }
        }
    }
}

struct ControlView: View {
    @State private var model = ControlModel()
    @AppStorage("rtspURL") private var rtspURL = "rtsp://192.168.1.254/novatek/sub"
    @StateObject private var liveCoordinator = KSVideoPlayer.Coordinator()
    @State private var isLiveOn = false
    @State private var liveStatus: String?
    @State private var liveError: String?

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
                    Text("优先直接拍照 (录像中实测可用); 状态不允许时自动切照片模式拍完再切回并恢复录像。若提示存储写入失败, 请备份后在设备上格式化 SD 卡。")
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
            .onAppear {
                // 旧版本遗留的错误地址 → 迁移到实测可用的子码流
                if Self.legacyAddresses.contains(rtspURL) {
                    rtspURL = "rtsp://192.168.1.254/novatek/sub"
                }
            }
            .onDisappear { stopLive() }
        }
    }

    // MARK: - RTSP 实时流 (KSPlayer / FFmpeg 软解)

    @ViewBuilder
    private var liveSection: some View {
        Section {
            if isLiveOn, let liveURL = URL(string: rtspURL) {
                KSVideoPlayer(coordinator: liveCoordinator, url: liveURL, options: makeLiveOptions())
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets())
                    .background(Color.black)
                    .overlay {
                        if isLiveLoading {
                            ZStack {
                                Color.black.opacity(0.4)
                                VStack(spacing: 8) {
                                    ProgressView().tint(.white)
                                    Text(liveStatus ?? "连接中…")
                                        .font(.footnote)
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                        if let liveError {
                            ZStack {
                                Color.black.opacity(0.5)
                                Label(liveError, systemImage: "exclamationmark.triangle.fill")
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                                    .padding()
                            }
                        }
                    }
                if let liveStatus {
                    LabeledContent("状态", value: liveStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button(role: .destructive) {
                    stopLive()
                } label: {
                    Label("停止直播", systemImage: "stop.fill")
                }
            } else {
                TextField("RTSP 地址", text: $rtspURL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                addressMenu
                Button {
                    startLive()
                } label: {
                    Label("开始直播", systemImage: "play.rectangle.fill")
                }
                .disabled(rtspURL.isEmpty)
                if let liveError {
                    Label(liveError, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text("实时视频流 (RTSP)")
        } footer: {
            Text("readme 实测节点: 主码流 novatek/main (高清), 子码流 novatek/sub (低延迟, 预览推荐)。HTTP-FLV (8080/live) 暂未适配。直播时设备较忙, 文件下载请稍后再试。离开本页自动断开。")
        }
    }

    private var isLiveLoading: Bool {
        liveStatus == "连接中…" || liveStatus == "缓冲中…"
    }

    private var addressMenu: some View {
        Menu {
            Button("主码流 (高清 1080P/4K)") { rtspURL = "rtsp://192.168.1.254/novatek/main" }
            Button("子码流 (标清低延迟)") { rtspURL = "rtsp://192.168.1.254/novatek/sub" }
        } label: {
            Label("实测地址", systemImage: "list.bullet")
        }
    }

    private static let legacyAddresses = [
        "rtsp://192.168.1.254/stream0",
        "rtsp://192.168.1.254/ch00_0.h264",
        "rtsp://192.168.1.254/live/ch00_0",
        "rtsp://192.168.1.254/h264",
    ]

    private func startLive() {
        guard let url = URL(string: rtspURL), url.scheme?.lowercased() == "rtsp" else {
            liveError = "暂只支持 rtsp:// 地址 (HTTP-FLV 8080/live 未适配)"
            return
        }
        liveError = nil
        liveStatus = "连接中…"
        bindLiveCallbacks()
        isLiveOn = true
    }

    private func stopLive() {
        isLiveOn = false
        liveStatus = nil
        liveCoordinator.resetPlayer()
    }

    private func bindLiveCallbacks() {
        liveCoordinator.onStateChanged = { _, state in
            Task { @MainActor in
                switch state {
                case .readyToPlay, .bufferFinished:
                    liveStatus = "直播中"
                    liveError = nil
                case .preparing:
                    liveStatus = "缓冲中…"
                default:
                    break
                }
            }
        }
        liveCoordinator.onFinish = { _, error in
            Task { @MainActor in
                if let error {
                    liveError = "直播失败: \(error.localizedDescription)"
                }
            }
        }
    }

    private func makeLiveOptions() -> KSOptions {
        let options = KSOptions()
        options.nobuffer = true                 // 直播低延迟
        options.codecLowDelay = true
        options.isLoopPlay = false
        options.registerRemoteControll = false  // 不占用系统控制中心
        return options
    }
}
