import SwiftUI
import Photos
import ImageIO
import KSPlayer

/// 本地下载库: 扫描 App 文档目录 (已通过 Info.plist 的 UIFileSharingEnabled
/// 暴露给系统"文件"App), 管理已下载媒体列表与封面缩略图。
@MainActor
@Observable
final class LocalLibraryModel {
    struct Entry: Identifiable {
        let url: URL
        let kind: DashcamFile.Kind   // 只会是 .video / .photo
        let size: Int64
        let modifiedAt: Date

        var id: String { url.absoluteString }
        var name: String { url.lastPathComponent }
        var sizeText: String {
            ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }
    }

    private(set) var entries: [Entry] = []
    /// 封面缓存 (entry.id → 缩略图)
    var thumbs: [String: UIImage] = [:]
    var toast: String?

    private var inflight: [String: Task<UIImage?, Never>] = [:]

    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 重扫文档目录; activeNames = 正在下载/转换中的文件名 (半成品文件不入列表,
    /// 由"下载中"条目代表), 排序按修改时间新的在前
    func rescan(activeNames: Set<String>) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: Self.documentsDirectory, includingPropertiesForKeys: keys
        ) else {
            entries = []
            return
        }
        entries = children.compactMap { url in
            guard !url.hasDirectoryPath, !url.lastPathComponent.hasPrefix(".") else { return nil }
            let kind = DashcamFile.kind(of: url.lastPathComponent)
            guard kind == .video || kind == .photo,
                  !activeNames.contains(url.lastPathComponent) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let size = values?.fileSize.map(Int64.init) ?? 0
            let modified = values?.contentModificationDate ?? .distantPast
            return Entry(url: url, kind: kind, size: size, modifiedAt: modified)
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// 卡片封面: 照片 ImageIO 降采样, 视频 FFmpeg 抽首帧; 相同条目的并发请求自动合并
    func loadThumb(for entry: Entry) async {
        guard thumbs[entry.id] == nil, inflight[entry.id] == nil else { return }
        let task = Task<UIImage?, Never> { [weak self] in
            let image = await Self.generate(entry)
            guard !Task.isCancelled else {
                self?.inflight[entry.id] = nil
                return nil
            }
            self?.thumbs[entry.id] = image
            self?.inflight[entry.id] = nil
            return image
        }

        inflight[entry.id] = task
        _ = await task.value
    }

    /// 解码在全局并发池执行, 不卡主线程 (与 ThumbnailStore 同款模式)
    private nonisolated static func generate(_ entry: Entry) async -> UIImage? {
        if entry.kind == .photo {
            return downsample(entry.url)
        }
        return FFmpegThumb.extractFrame(from: entry.url)
    }

    private nonisolated static func downsample(_ url: URL, maxPixelSize: Int = 640) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cg)
    }

    func saveToPhotos(_ url: URL) async {
        let resource = url.pathExtension.uppercased() == "JPG" || url.pathExtension.uppercased() == "JPEG"
            ? PHAssetResourceType.photo : .video
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset()
                    .addResource(with: resource, fileURL: url, options: nil)
            }
            toast = "已保存到系统相册"
        } catch {
            toast = "保存失败: \(error.localizedDescription)"
        }
    }

    func delete(_ entries: [Entry]) {
        var deletedCount = 0
        var failedCount = 0
        var deletedIDs = Set<String>()

        for entry in entries {
            do {
                if FileManager.default.fileExists(atPath: entry.url.path) {
                    try FileManager.default.removeItem(at: entry.url)
                }
                deletedIDs.insert(entry.id)
                deletedCount += 1
            } catch {
                failedCount += 1
            }
        }

        guard !deletedIDs.isEmpty else {
            toast = failedCount == 1 ? "删除失败" : "\(failedCount) 个文件删除失败"
            return
        }

        self.entries.removeAll { deletedIDs.contains($0.id) }
        for id in deletedIDs {
            inflight[id]?.cancel()
            inflight[id] = nil
            thumbs[id] = nil
        }

        if failedCount == 0 {
            toast = deletedCount == 1 ? "已删除 1 个文件" : "已删除 \(deletedCount) 个文件"
        } else {
            toast = "已删除 \(deletedCount) 个文件, \(failedCount) 个失败"
        }
    }
}

/// 本地相册 tab: 展示文档目录里已下载/下载中的视频与照片。
/// 文件同时暴露在系统"文件"App (我的 iPhone → NovaDash), 可在文件 App 端删除/导出。
struct LocalLibraryView: View {
    private let model = LocalLibraryModel()
    /// 下载进度来自设备相册页发起的下载 (跨 tab 共享)
    private let album = AlbumModel.shared

    @State private var playingEntry: LocalLibraryModel.Entry?
    @State private var photoEntry: LocalLibraryModel.Entry?
    @Environment(\.scenePhase) private var scenePhase
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var entryPendingDeletion: LocalLibraryModel.Entry?
    @State private var isConfirmingBulkDeletion = false

    /// 下载中/转换中的条目 (文件名 + 状态)
    private var activeDownloads: [(name: String, state: AlbumModel.DownloadState)] {
        album.downloads.compactMap { key, state in
            switch state {
            case .running, .converting:
                return (DashcamFile(rawPath: key, kind: .other).name, state)
            default:
                return nil
            }
        }
    }

    private var activeNames: Set<String> { Set(activeDownloads.map(\.name)) }
    private var entryIDs: [String] { model.entries.map(\.id) }
    private var allSelected: Bool {
        !model.entries.isEmpty && selectedIDs.count == model.entries.count
    }

    /// 下载完成数变化时重扫目录 (下载完成 → 新文件落盘; TS 转 MP4 → 文件名变化)
    private var doneCount: Int {
        album.downloads.values.filter {
            if case .done = $0 { return true }
            return false
        }.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16, pinnedViews: .sectionHeaders) {
                    if !activeDownloads.isEmpty {
                        downloadingSection
                    }
                    if !model.entries.isEmpty {
                        gridSection
                    }
                    filesAppHint
                }
                .padding(.vertical, 8)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("本地相册")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !model.entries.isEmpty {
                        if isSelecting {
                            Button("完成") { endSelection() }
                        } else {
                            Button("选择") { startSelection() }
                        }
                    }
                }
            }
            .refreshable { model.rescan(activeNames: activeNames) }
            .onAppear { model.rescan(activeNames: activeNames) }
            .onChange(of: doneCount) { model.rescan(activeNames: activeNames) }
            .onChange(of: entryIDs) { _, _ in pruneSelection() }
            .onChange(of: scenePhase) {
                // 从"文件"App 切回来时可能已在系统端删除过文件
                if $0 == .active { model.rescan(activeNames: activeNames) }
            }
            .overlay {
                if model.entries.isEmpty && activeDownloads.isEmpty {
                    ContentUnavailableView(
                        "暂无下载的文件",
                        systemImage: "arrow.down.circle",
                        description: Text("到设备相册点击卡片右下角的下载按钮, 下载完成的视频与照片会保存在这里。")
                    )
                }
            }
            .sheet(item: $playingEntry) { entry in
                LocalVideoSheet(entry: entry)
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.black)
            }
            .sheet(item: $photoEntry) { entry in
                LocalPhotoSheet(entry: entry) { url in
                    Task { await model.saveToPhotos(url) }
                }
                .presentationDragIndicator(.visible)
                .presentationBackground(.black)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    toast
                    if isSelecting { selectionBar }
                }
            }
            .confirmationDialog(
                "删除 \(entryPendingDeletion?.name ?? "")?",
                isPresented: Binding(
                    get: { entryPendingDeletion != nil },
                    set: { if !$0 { entryPendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    if let entry = entryPendingDeletion { delete(entry) }
                }
                Button("取消", role: .cancel) { entryPendingDeletion = nil }
            } message: {
                Text("文件会从本 App 的文档目录中移除，不会影响系统相册中已保存的内容。")
            }
            .confirmationDialog(
                "删除选中的 \(selectedIDs.count) 个文件？",
                isPresented: $isConfirmingBulkDeletion,
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) { deleteSelected() }
                Button("取消", role: .cancel) { }
            } message: {
                Text("文件会从本 App 的文档目录中移除，不会影响系统相册中已保存的内容。")
            }
        }
    }

    // MARK: - 下载中

    private var downloadingSection: some View {
        Section {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                spacing: 10
            ) {
                ForEach(activeDownloads, id: \.name) { item in
                    downloadingCard(item.name, state: item.state)
                }
            }
            .padding(.horizontal)
        } header: {
            sectionHeader("下载中")
        }
    }

    private func downloadingCard(_ name: String, state: AlbumModel.DownloadState) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: "arrow.down.circle")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
            .aspectRatio(16 / 9, contentMode: .fit)

            HStack(spacing: 6) {
                switch state {
                case .running(let progress):
                    ProgressView(value: progress)
                        .frame(width: 44)
                    Text("下载中 \(Int(progress * 100))%")
                case .converting:
                    ProgressView()
                        .frame(width: 44)
                    Text("正在转为 MP4…")
                default:
                    EmptyView()
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 已下载文件

    private var gridSection: some View {
        Section {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                spacing: 10
            ) {
                ForEach(model.entries) { entry in
                    card(entry)
                }
            }
            .padding(.horizontal)
        } header: {
            sectionHeader("已下载")
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 14) {
            Button {
                selectedIDs = allSelected ? [] : Set(model.entries.map(\.id))
            } label: {
                Label(allSelected ? "取消全选" : "全选", systemImage: allSelected ? "circle" : "checkmark.circle")
            }

            Spacer()

            Text("已选 \(selectedIDs.count)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)

            Button(role: .destructive) {
                isConfirmingBulkDeletion = true
            } label: {
                Label("删除", systemImage: "trash")
            }
            .disabled(selectedIDs.isEmpty)
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private func card(_ entry: LocalLibraryModel.Entry) -> some View {
        VStack(spacing: 0) {
            cover(entry)
                .contentShape(Rectangle())
                .onTapGesture {
                    if isSelecting {
                        toggleSelection(entry)
                    } else {
                        open(entry)
                    }
                }

            HStack(spacing: 6) {
                Image(systemName: entry.kind == .photo ? "photo" : "video")
                    .font(.caption2)
                    .foregroundStyle(entry.kind == .photo ? .yellow : .blue)
                Text(entry.sizeText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            Button(role: .destructive) {
                entryPendingDeletion = entry
            } label: {
                Image(systemName: "trash")
                    .accessibilityLabel("删除 \(entry.name)")
            }
                .foregroundStyle(.red)
                .buttonStyle(.borderless)
                .disabled(isSelecting)
                ShareLink(item: entry.url) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            if isSelecting, selectedIDs.contains(entry.id) {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.blue, lineWidth: 2)
            }
        }
        .task { await model.loadThumb(for: entry) }
    }

    private func toggleSelection(_ entry: LocalLibraryModel.Entry) {
        if selectedIDs.contains(entry.id) {
            selectedIDs.remove(entry.id)
        } else {
            selectedIDs.insert(entry.id)
        }
    }

    /// 16:9 封面: 已生成显示封面, 视频未生成/失败显示类型图标占位
    private func cover(_ entry: LocalLibraryModel.Entry) -> some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let image = model.thumbs[entry.id] {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Image(systemName: entry.kind == .video ? "video" : "photo")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .clipShape(.rect(topLeadingRadius: 12, topTrailingRadius: 12))
            .overlay(alignment: .topTrailing) {
                if isSelecting {
                    Image(systemName: selectedIDs.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white, .blue)
                        .padding(7)
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                }
            }
    }

    private func open(_ entry: LocalLibraryModel.Entry) {
        if entry.kind == .video {
            playingEntry = entry
        } else {
            photoEntry = entry
        }
    }

    private func startSelection() {
        isSelecting = true
    }

    private func endSelection() {
        isSelecting = false
        selectedIDs = []
    }

    private func pruneSelection() {
        guard !model.entries.isEmpty else {
            endSelection()
            return
        }
        let ids = Set(model.entries.map(\.id))
        selectedIDs.formIntersection(ids)
        closeRemovedPreviews(validIDs: ids)
    }

    private func closeRemovedPreviews(validIDs: Set<String>) {
        if let playingEntry, !validIDs.contains(playingEntry.id) {
            self.playingEntry = nil
        }
        if let photoEntry, !validIDs.contains(photoEntry.id) {
            self.photoEntry = nil
        }
    }

    private func delete(_ entry: LocalLibraryModel.Entry) {
        model.delete([entry])
        if model.entries.isEmpty { endSelection() }
    }

    private func deleteSelected() {
        let selected = model.entries.filter { selectedIDs.contains($0.id) }
        model.delete(selected)
        selectedIDs = []
        if model.entries.isEmpty { endSelection() }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Label(title, systemImage: title == "下载中" ? "arrow.down.circle" : "checkmark.circle")
                .font(.subheadline.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var filesAppHint: some View {
        Label("文件同时保存在 文件 App → 我的 iPhone → NovaDash, 可在系统端管理",
              systemImage: "folder")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
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

// MARK: - 本地视频播放 (结构与设备相册的 VideoStreamSheet 同构, 播本地文件)

private struct LocalVideoSheet: View {
    let entry: LocalLibraryModel.Entry

    @StateObject private var coordinator = KSVideoPlayer.Coordinator()
    @State private var isLoading = true
    @State private var isPlaying = true
    @State private var isSeeking = false
    @State private var currentTime: TimeInterval = 0
    @State private var totalTime: TimeInterval = 0
    @State private var errorText: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(spacing: 10) {
                    player
                    controls
                }
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    Label(entry.name, systemImage: "video")
                    Spacer()
                    Label(entry.sizeText, systemImage: "internaldrive")
                }
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear { bindCallbacks() }
            .onDisappear {
                coordinator.playerLayer?.stop()
                coordinator.resetPlayer()
            }
        }
        .preferredColorScheme(.dark)
    }

    private var player: some View {
        Color.black
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                KSVideoPlayer(coordinator: coordinator, url: entry.url, options: makeOptions())
            }
            .overlay {
                if isLoading {
                    ZStack {
                        Color.black.opacity(0.4)
                        ProgressView().tint(.white)
                    }
                }
            }
            .overlay {
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

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                togglePlay()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
            }
            .disabled(isLoading || errorText != nil)

            Text(timeString(currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))

            Slider(
                value: Binding(
                    get: { totalTime > 0 ? min(currentTime / max(totalTime, 1), 1) : 0 },
                    set: { currentTime = $0 * totalTime }
                ),
                onEditingChanged: { editing in
                    guard totalTime > 0 else { return }
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
            .disabled(totalTime <= 0)
            .tint(.white)

            Text(totalTime > 0 ? timeString(totalTime) : "--:--")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
        }
        .tint(.white)
        .padding(.horizontal, 16)
        .frame(height: 36)
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
                    errorText = errorText ?? "播放失败"
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

// MARK: - 本地照片查看 (黑底全屏, 捏合/双击缩放, 支持分享与存系统相册)

private struct LocalPhotoSheet: View {
    let entry: LocalLibraryModel.Entry
    let onSave: (URL) -> Void

    @State private var scale: CGFloat = 1
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image = UIImage(contentsOfFile: entry.url.path) {
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
                    Label("无法读取图片", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 18) {
                        Button {
                            onSave(entry.url)
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                        }
                        ShareLink(item: entry.url) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
