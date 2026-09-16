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
        guard thumbs[file.id] == nil else { return }
        // 视频优先找设备端同名 .THM 缩略图
        let thm = files.first {
            $0.kind == .other
                && $0.name.lowercased().hasSuffix(".thm")
                && $0.baseName == file.baseName
        }
        if let image = await ThumbnailStore.shared.thumbnail(for: file, thm: thm) {
            thumbs[file.id] = image
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
            .fullScreenCover(item: $viewerGroup) { group in
                PhotoViewer(model: model, photos: group.files)
            }
            .sheet(item: $streamingFile) { file in
                VideoStreamSheet(file: file)
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

    /// 16:9 封面图, 未加载完成时显示占位
    private func cover(_ file: DashcamFile) -> some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let image = model.thumbs[file.id] {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        if file.kind == .video {
                            Image(systemName: "video")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                        }
                    }
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

// MARK: - 照片全屏查看器 (同一天内翻页)

private struct PhotoViewer: View {
    let model: AlbumModel
    let photos: [DashcamFile]

    @State private var index = 0
    @State private var images: [String: UIImage] = [:]
    @State private var urls: [String: URL] = [:]
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

// MARK: - 视频在线播放 (KSPlayer/FFmpeg 直接拉设备 TS 流)

private struct VideoStreamSheet: View {
    let file: DashcamFile

    @StateObject private var coordinator = KSVideoPlayer.Coordinator()
    @State private var errorText: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                KSVideoPlayer(
                    coordinator: coordinator,
                    url: NovatekClient.shared.streamURL(for: file),
                    options: makeOptions()
                )
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(Color.black)

                if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                } else {
                    Text("FFmpeg 实时拉流播放; 需要离线保存时用卡片上的 ↓ 按钮下载")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
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
            .onAppear { bindCallbacks() }
            .onDisappear { coordinator.resetPlayer() }
        }
    }

    private func makeOptions() -> KSOptions {
        let options = KSOptions()
        options.isLoopPlay = false
        return options
    }

    private func bindCallbacks() {
        coordinator.onFinish = { _, error in
            Task { @MainActor in
                if let error {
                    errorText = "播放失败: \(error.localizedDescription)"
                }
            }
        }
        coordinator.onStateChanged = { _, state in
            Task { @MainActor in
                if state == .bufferFinished || state == .readyToPlay {
                    errorText = nil
                }
            }
        }
    }
}
