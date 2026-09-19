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

    /// 远程拍照 (2026-09-19 实测路径: 切照片模式 → 拍 → 自动切回并恢复录像), 完成后立即复核录像状态
    func capture(connection: ConnectionModel) async {
        await run("正在拍照… (切照片模式 → 拍 → 恢复录像, 约十几秒)") {
            let path = try await NovatekClient.shared.capturePhoto()
            await connection.refreshRecording()
            if let path {
                let name = DashcamFile(rawPath: path, kind: .other).name
                return "已拍照: \(name)"
            }
            return "拍照指令已发出 (设备忙未回执, 请到相册确认)"
        }
    }

    /// 录像开关; 命令回执后立即复核录像状态 (不等下一轮心跳)
    func record(_ on: Bool, connection: ConnectionModel) async {
        await run(on ? "正在开始录像… (设备可能忙十几秒)" : "正在停止录像…") {
            let outcome = try await NovatekClient.shared.setRecording(on)
            await connection.refreshRecording()
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

/// 控制首页 (第一个 tab): 进页自动开播, 录像状态随心跳实时展示,
/// 相册入口只在停止录像后开放 (设备录像中拒绝文件列表)。
struct ControlView: View {
    @Environment(ConnectionModel.self) private var connection
    @State private var model = ControlModel()
    @AppStorage("rtspURL") private var rtspURL = "rtsp://192.168.1.254/novatek/sub"
    @StateObject private var liveCoordinator = KSVideoPlayer.Coordinator()
    @State private var isLiveOn = false
    @State private var liveStatus: String?
    @State private var liveError: String?
    @State private var showAlbum = false

    var body: some View {
        NavigationStack {
            List {
                liveSection
                recordingSection
                captureSection
                albumSection
                feedbackSections
            }
            .navigationTitle("控制")
            .navigationDestination(isPresented: $showAlbum) { AlbumView() }
            .onAppear {
                // 旧版本遗留的错误地址 → 迁移到实测可用的子码流
                if Self.legacyAddresses.contains(rtspURL) {
                    rtspURL = "rtsp://192.168.1.254/novatek/sub"
                }
                // 进页面自动开始直播 (首次进入/切回本页/从相册返回都会触发)
                if !isLiveOn { startLive() }
            }
            .onDisappear { stopLive() }
        }
    }

    // MARK: - 实时画面 (自动开播)

    private var liveSection: some View {
        Section {
            if isLiveOn, let liveURL = URL(string: rtspURL) {
                KSVideoPlayer(coordinator: liveCoordinator, url: liveURL, options: makeLiveOptions())
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets())
                    .background(Color.black)
                    .overlay { liveOverlay }
                liveControlBar
            } else {
                Button { startLive() } label: {
                    Label("开始直播", systemImage: "play.rectangle.fill")
                }
                if let liveError {
                    Label(liveError, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text("实时画面")
        } footer: {
            Text("进入本页自动开始直播 (子码流低延迟)。直播时设备较忙, 其他操作响应会慢一些, 文件下载请回相册页进行。")
        }
    }

    @ViewBuilder
    private var liveOverlay: some View {
        if isLiveLoading {
            ZStack {
                Color.black.opacity(0.45)
                VStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text(liveStatus ?? "连接中…")
                        .font(.footnote)
                        .foregroundStyle(.white)
                }
            }
        } else if let liveError {
            ZStack {
                Color.black.opacity(0.5)
                Label(liveError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding()
            }
        }
    }

    private var liveControlBar: some View {
        HStack(spacing: 14) {
            if let liveStatus {
                Label(liveStatus, systemImage: liveStatus == "直播中" ? "dot.radiowave.left" : "hourglass")
                    .font(.footnote)
                    .foregroundStyle(liveStatus == "直播中" ? .green : .secondary)
            }
            Spacer()
            Menu {
                Button("主码流 (高清)") { switchStream("rtsp://192.168.1.254/novatek/main") }
                Button("子码流 (低延迟, 推荐)") { switchStream("rtsp://192.168.1.254/novatek/sub") }
            } label: {
                Label("切换码流", systemImage: "arrow.triangle.2.circlepath")
            }
            Button(role: .destructive) { stopLive() } label: {
                Label("停止", systemImage: "stop.fill")
            }
        }
        .font(.footnote)
    }

    // MARK: - 录像控制 (状态随心跳)

    private var recordingSection: some View {
        Section {
            HStack {
                Label {
                    Text(connection.isRecording == true ? "录像中" : "已停止")
                } icon: {
                    Image(systemName: connection.isRecording == true ? "record.circle" : "stop.circle")
                        .foregroundStyle(connection.isRecording == true ? .red : .green)
                }
                Spacer()
                if let seconds = connection.recordingSeconds, seconds > 0 {
                    Text("当前片段 \(seconds)s")
                        .font(.monospacedDigit(.footnote)())
                        .foregroundStyle(.secondary)
                } else if connection.isRecording == nil {
                    Text("获取中…").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Button {
                Task { await model.record(true, connection: connection) }
            } label: {
                Label("开始录像", systemImage: "record.circle")
            }
            .disabled(model.busyText != nil || connection.isRecording == true)
            Button(role: .destructive) {
                Task { await model.record(false, connection: connection) }
            } label: {
                Label("停止录像", systemImage: "stop.circle")
            }
            .disabled(model.busyText != nil || connection.isRecording == false)
        } header: {
            Text("录像控制")
        } footer: {
            Text("状态跟随每 3 秒心跳自动刷新, 按钮按状态自动可用/禁用。设备忙时命令可能十几秒才回执, 超时不代表失败。")
        }
    }

    // MARK: - 远程拍照

    private var captureSection: some View {
        Section {
            Button {
                Task { await model.capture(connection: connection) }
            } label: {
                Label("立即拍照", systemImage: "camera.fill")
            }
            .disabled(model.busyText != nil)
        } header: {
            Text("远程拍照")
        } footer: {
            Text("实测可靠路径: 切照片模式 → 拍照 → 自动切回录像模式并恢复循环录像, 全程约十几秒。若提示存储写入失败, 请备份后在设备上格式化 SD 卡。")
        }
    }

    // MARK: - 相册入口 (仅停止录像后开放)

    private var albumSection: some View {
        Section {
            Button {
                showAlbum = true
            } label: {
                HStack {
                    Label("打开相册", systemImage: "photo.on.rectangle.angled")
                    Spacer()
                    if connection.isRecording == true {
                        Text("停止录像后可进入")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .disabled(connection.isRecording != false)
        } header: {
            Text("相册")
        } footer: {
            Text("设备录像中不提供文件列表 (返回 -3), 停止录像后才能浏览; 浏览期间请勿在设备端开始录像。")
        }
    }

    // MARK: - 命令反馈

    @ViewBuilder
    private var feedbackSections: some View {
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

    // MARK: - RTSP 直播管线 (KSPlayer / FFmpeg 软解)

    private var isLiveLoading: Bool {
        liveStatus == "连接中…" || liveStatus == "缓冲中…"
    }

    private func switchStream(_ url: String) {
        guard url != rtspURL else { return }
        rtspURL = url
        stopLive()
        startLive()
    }

    private func startLive() {
        guard let url = URL(string: rtspURL), url.scheme?.lowercased() == "rtsp" else {
            liveError = "暂只支持 rtsp:// 地址"
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
                    liveStatus = nil
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

    private static let legacyAddresses = [
        "rtsp://192.168.1.254/stream0",
        "rtsp://192.168.1.254/ch00_0.h264",
        "rtsp://192.168.1.254/live/ch00_0",
        "rtsp://192.168.1.254/h264",
    ]
}
