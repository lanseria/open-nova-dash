import SwiftUI
import Photos
import ImageIO
import KSPlayer

@MainActor
@Observable
final class AlbumModel {
    enum Filter: String, CaseIterable {
        case all = "全部"
        case photo = "照片"
        case video = "视频"
    }

    enum DownloadState {
        case running(Double)
        case done(URL)
        case failed(String)
    }

    var files: [DashcamFile] = []
    var filter: Filter = .all
    var isLoading = false
    var errorText: String?
    var toast: String?
    var downloads: [String: DownloadState] = [:]
    /// 卡片封面 (id → 缩略图/视频封面)
    var thumbs: [String: UIImage] = [:]
    /// 已尝试但拿不到封面的文件 (显示静态占位, 不再重复请求)
    var failedThumbs: Set<String> = []

    /// 按天分组, 新的在前; 时间无法解析的归入"未知日期"排最后
    var groups: [FileGroup] {
        var byDay: [Date?: [DashcamFile]] = [:]
        for file in files where matches(file) {
            byDay[file.day, default: []].append(file)
        }
        return byDay
            .sorted { lhs, rhs in
                switch (lhs.key, rhs.key) {
                case let (l?, r?): l > r
                case (nil, _): false
                case (_, nil): true
                }
            }
            .map { FileGroup(day: $0.key, files: $0.value.sorted {
                ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast)
            }) }
    }

    private func matches(_ file: DashcamFile) -> Bool {
        // .THM 伴生缩略图只作视频封面素材, 不单独出卡片
        if file.name.lowercased().hasSuffix(".thm") { return false }
        return switch filter {
        case .all: true
        case .photo: file.kind == .photo
        case .video: file.kind == .video
        }
    }

    /// force=false 时使用内存缓存 (切换页面不重复请求); 仅下拉刷新强制拉取
    func load(force: Bool = false) async {
        if !force, !files.isEmpty { return }
        isLoading = true
        errorText = nil
        do {
            files = try await NovatekClient.shared.fetchFiles()
            if files.isEmpty {
                errorText = "卡上没有文件"
            }
        } catch {
            errorText = NovatekError.describe(error)
        }
        isLoading = false
    }

    func download(_ file: DashcamFile) async {
        downloads[file.id] = .running(0)
        do {
            let url = try await NovatekClient.shared.download(file) { [weak self] progress in
                Task { @MainActor in
                    self?.downloads[file.id] = .running(progress)
                }
            }
            downloads[file.id] = .done(url)
        } catch {
            downloads[file.id] = .failed(NovatekError.describe(error))
        }
    }

    func saveToPhotos(_ url: URL) async {
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset()
                    .addResource(with: .photo, fileURL: url, options: nil)
            }
            toast = "已保存到系统相册"
        } catch {
            toast = "保存失败: \(error.localizedDescription)"
        }
    }

    func loadThumb(for file: DashcamFile) async {
        guard thumbs[file.id] == nil, !failedThumbs.contains(file.id) else { return }
        // 视频优先找设备端同名 .THM 缩略图
        let thm = files.first {
            $0.kind == .other
                && $0.name.lowercased().hasSuffix(".thm")
                && $0.baseName == file.baseName
        }
        if let image = await ThumbnailStore.shared.thumbnail(for: file, thm: thm) {
            thumbs[file.id] = image
        } else {
            failedThumbs.insert(file.id)
        }
    }
}

struct AlbumView: View {
    @State private var model = AlbumModel()
    @State private var viewerGroup: FileGroup?
    @State private var streamingFile: DashcamFile?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16, pinnedViews: .sectionHeaders) {
                    filterBar

                    if let error = model.errorText {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                    }

                    ForEach(model.groups) { group in
                        Section {
                            grid(group)
                        } header: {
                            sectionHeader(group)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("相册")
            .refreshable { await model.load(force: true) }
            .task { await model.load() }
            .overlay {
                if model.isLoading && model.files.isEmpty {
                    ProgressView("正在拉取文件列表…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .overlay(alignment: .bottom) {
                toast
            }
            .sheet(item: $viewerGroup) { group in
                PhotoViewer(model: model, photos: group.files)
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.black)
            }
            .sheet(item: $streamingFile) { file in
                VideoStreamSheet(file: file)
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private var filterBar: some View {
        Picker("类型", selection: $model.filter) {
            ForEach(AlbumModel.Filter.allCases, id: \.self) { Text($0.rawValue) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
    }

    private func sectionHeader(_ group: FileGroup) -> some View {
        HStack {
            Label(group.title, systemImage: "calendar")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text("\(group.files.count) 个文件")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func grid(_ group: FileGroup) -> some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
            spacing: 10
        ) {
            ForEach(group.files) { file in
                card(file)
            }
        }
        .padding(.horizontal)
    }

    // MARK: - 卡片

    private func card(_ file: DashcamFile) -> some View {
        VStack(spacing: 0) {
            cover(file)
                .contentShape(Rectangle())
                .onTapGesture { open(file) }

            HStack(spacing: 6) {
                Image(systemName: file.kind == .photo ? "photo" : "video")
                    .font(.caption2)
                    .foregroundStyle(file.kind == .photo ? .yellow : .blue)
                Text(file.timeText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                downloadControl(file)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .task { await model.loadThumb(for: file) }
    }

    /// 16:9 封面图: 加载中流光占位 → 失败静态图标 → 成功显示封面
    private func cover(_ file: DashcamFile) -> some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let image = model.thumbs[file.id] {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if model.failedThumbs.contains(file.id) {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Image(systemName: file.kind == .video ? "video" : "photo")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    ShimmerCover(iconName: file.kind == .video ? "video" : "photo")
                }
            }
            .clipShape(.rect(topLeadingRadius: 12, topTrailingRadius: 12))
    }

    private func open(_ file: DashcamFile) {
        switch file.kind {
        case .photo:
            // 查看器在同一"天"的照片间左右翻页 (剔除视频)
            let group = model.groups.first(where: { $0.files.contains { $0.id == file.id } })
            let photos = (group?.files ?? [file]).filter { $0.kind == .photo }
            viewerGroup = FileGroup(day: file.day, files: photos.isEmpty ? [file] : photos)
        case .video:
            // FFmpeg (KSPlayer) 直接拉设备的 HTTP-TS 流播放, 无需先下载
            streamingFile = file
        case .other:
            break
        }
    }

    // MARK: - 导出控件 (紧凑版)

    @ViewBuilder
    private func downloadControl(_ file: DashcamFile) -> some View {
        switch model.downloads[file.id] {
        case nil:
            Button {
                Task { await model.download(file) }
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(.borderless)

        case .running(let progress):
            ProgressView(value: progress)
                .frame(width: 44)

        case .done(let url):
            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up.fill")
                    .foregroundStyle(.green)
            }

        case .failed:
            Button {
                Task { await model.download(file) }
            } label: {
                Image(systemName: "exclamationmark.arrow.circlepath")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
        }
    }

    private var toast: some View {
        Group {
            if let toast = model.toast {
                Text(toast)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 12)
                    .task {
                        try? await Task.sleep(for: .seconds(2))
                        model.toast = nil
                    }
            }
        }
    }
}

// MARK: - 封面加载占位 (流光扫过动画)

private struct ShimmerCover: View {
    let iconName: String
    @State private var phase: CGFloat = -1

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Image(systemName: iconName)
                .font(.title2)
                .foregroundStyle(.tertiary)
            GeometryReader { geo in
                LinearGradient(
                    colors: [.clear, .white.opacity(0.35), .clear],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: geo.size.width * 0.6)
                .offset(x: phase * geo.size.width * 1.6)
            }
        }
        .clipped()
        .task {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }
}

// MARK: - 文件信息栏 (照片/视频预览共用)

struct FileInfoView: View {
    let file: DashcamFile
    let sizeText: String?
    /// 深色背景 (照片全屏查看) 时用白色文字
    var dark = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(file.name)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
            HStack(spacing: 10) {
                Label(file.timestampText, systemImage: "clock")
                Label(file.kind == .photo ? "照片" : "视频",
                      systemImage: file.kind == .photo ? "photo" : "video")
                if let sizeText {
                    Label(sizeText, systemImage: "internaldrive")
                }
            }
            .font(.caption2)
            Text(file.rawPath)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(dark ? .white.opacity(0.85) : .secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 照片查看器 (同一天内翻页, 下拉收起)

private struct PhotoViewer: View {
    let model: AlbumModel
    let photos: [DashcamFile]

    @State private var index = 0
    @State private var images: [String: UIImage] = [:]
    @State private var urls: [String: URL] = [:]
    @State private var sizes: [String: Int64] = [:]
    @State private var scale: CGFloat = 1
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TabView(selection: $index) {
                ForEach(photos.indices, id: \.self) { i in
                    page(photos[i])
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(Color.black.ignoresSafeArea())
            .overlay(alignment: .bottom) {
                FileInfoView(file: photos[index], sizeText: sizeText, dark: true)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    Text("\(index + 1) / \(photos.count)")
                        .monospacedDigit()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    actions(for: photos[index])
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var sizeText: String? {
        sizes[photos[index].id].map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        }
    }

    private func page(_ file: DashcamFile) -> some View {
        ZStack {
            if let image = images[file.id] {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in scale = max(1, value) }
                            .onEnded { _ in
                                withAnimation { scale = scale < 1.4 ? 1 : scale }
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation { scale = scale > 1 ? 1 : 2.5 }
                    }
            } else {
                ProgressView()
                    .task { await loadFull(file) }
            }
        }
        .onChange(of: index) { scale = 1 }
    }

    private func loadFull(_ file: DashcamFile) async {
        if sizes[file.id] == nil {
            sizes[file.id] = await NovatekClient.shared.fetchFileSize(for: file)
        }
        guard images[file.id] == nil else { return }
        guard let url = try? await NovatekClient.shared.fetchPreviewFile(file),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            model.toast = "照片加载失败"
            return
        }
        urls[file.id] = url
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            images[file.id] = UIImage(cgImage: cg)
        }
    }

    @ViewBuilder
    private func actions(for file: DashcamFile) -> some View {
        HStack(spacing: 18) {
            Button {
                if let url = urls[file.id] {
                    Task { await model.saveToPhotos(url) }
                }
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .disabled(urls[file.id] == nil)

            if let url = urls[file.id] {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                }
            } else {
                Image(systemName: "square.and.arrow.up")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 视频在线播放 (KSPlayer/FFmpeg 直接拉设备 TS 流, 带播控)

private struct VideoStreamSheet: View {
    let file: DashcamFile

    @StateObject private var coordinator = KSVideoPlayer.Coordinator()
    @State private var isLoading = true
    @State private var isPlaying = true
    @State private var isSeeking = false
    @State private var currentTime: TimeInterval = 0
    @State private var totalTime: TimeInterval = 0
    @State private var errorText: String?
    @State private var fileSize: Int64?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                player
                controls
                FileInfoView(
                    file: file,
                    sizeText: fileSize.map {
                        ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                    }
                )
                .padding(.horizontal, 16)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(Color(.systemBackground))
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear {
                bindCallbacks()
                Task {
                    fileSize = await NovatekClient.shared.fetchFileSize(for: file)
                }
            }
            .onDisappear { coordinator.resetPlayer() }
        }
    }

    // MARK: 播放器 + 加载/错误浮层

    private var player: some View {
        ZStack {
            KSVideoPlayer(
                coordinator: coordinator,
                url: NovatekClient.shared.streamURL(for: file),
                options: makeOptions()
            )
            .aspectRatio(16 / 9, contentMode: .fit)
            .background(Color.black)

            if isLoading {
                ZStack {
                    Color.black.opacity(0.4)
                    VStack(spacing: 10) {
                        ProgressView()
                            .tint(.white)
                        Text("正在加载视频流…")
                            .font(.footnote)
                            .foregroundStyle(.white)
                    }
                }
            }
            if let errorText {
                ZStack {
                    Color.black.opacity(0.6)
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding()
                }
            }
        }
    }

    // MARK: 播控条 (播放/暂停 + 进度条 + 静音)

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                togglePlay()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
            }
            .disabled(isLoading || errorText != nil)

            if totalTime > 0 {
                Text(timeString(currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { min(currentTime / max(totalTime, 1), 1) },
                        set: { currentTime = $0 * totalTime }
                    ),
                    onEditingChanged: { editing in
                        isSeeking = editing
                        if !editing {
                            coordinator.seek(time: currentTime)
                            Task {
                                try? await Task.sleep(for: .seconds(0.6))
                                isSeeking = false
                            }
                        }
                    }
                )
                Text(timeString(totalTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("缓冲中, 时长未知…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                coordinator.isMuted.toggle()
            } label: {
                Image(systemName: coordinator.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.title3)
            }
        }
        .padding(.horizontal, 16)
    }

    private func togglePlay() {
        guard let player = coordinator.playerLayer?.player else { return }
        if player.playbackState == .playing {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    private func makeOptions() -> KSOptions {
        let options = KSOptions()
        options.isLoopPlay = false
        return options
    }

    private func bindCallbacks() {
        coordinator.onPlay = { [weak coordinator] current, total in
            Task { @MainActor in
                guard coordinator != nil, !isSeeking else { return }
                currentTime = current
                if total > 0 { totalTime = total }
            }
        }
        coordinator.onStateChanged = { _, state in
            Task { @MainActor in
                switch state {
                case .initialized, .preparing, .buffering:
                    isLoading = true
                case .readyToPlay, .bufferFinished:
                    isLoading = false
                    isPlaying = true
                    errorText = nil
                case .paused:
                    isLoading = false
                    isPlaying = false
                case .playedToTheEnd:
                    isLoading = false
                    isPlaying = false
                case .error:
                    isLoading = false
                    isPlaying = false
                    errorText = errorText ?? "播放失败, 请稍后重试"
                default:
                    break
                }
            }
        }
        coordinator.onFinish = { _, error in
            Task { @MainActor in
                if let error {
                    isLoading = false
                    errorText = "播放失败: \(error.localizedDescription)"
                }
            }
        }
    }

    private func timeString(_ interval: TimeInterval) -> String {
        let total = max(Int(interval), 0)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}
