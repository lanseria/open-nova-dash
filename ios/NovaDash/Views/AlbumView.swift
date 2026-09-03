import SwiftUI
import Photos

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

    var filtered: [DashcamFile] {
        switch filter {
        case .all: files
        case .photo: files.filter { $0.kind == .photo }
        case .video: files.filter { $0.kind == .video }
        }
    }

    func load() async {
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
}

struct AlbumView: View {
    @State private var model = AlbumModel()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("类型", selection: $model.filter) {
                        ForEach(AlbumModel.Filter.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    ForEach(model.filtered) { file in
                        row(file)
                    }
                } footer: {
                    Text("视频为 TS 格式, 暂以文件分享导出; 直接存系统相册需后续加 FFmpeg 重封装。")
                }

                if let error = model.errorText {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("相册 (\(model.filtered.count))")
            .refreshable { await model.load() }
            .task { await model.load() }
            .overlay {
                if model.isLoading {
                    ProgressView("正在拉取文件列表…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .overlay(alignment: .bottom) {
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

    private func row(_ file: DashcamFile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: file.kind == .photo ? "photo" : "video")
                .font(.title3)
                .foregroundStyle(file.kind == .photo ? .yellow : .blue)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(file.kind == .photo ? "照片" : "循环录像")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            downloadControl(file)
        }
    }

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
                .frame(width: 96)

        case .done(let url):
            HStack(spacing: 14) {
                if file.kind == .photo {
                    Button {
                        Task { await model.saveToPhotos(url) }
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderless)
                }
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                }
            }

        case .failed(let message):
            VStack(alignment: .trailing, spacing: 2) {
                Button("重试") { Task { await model.download(file) } }
                    .font(.footnote)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
    }
}
