import UIKit
import ImageIO

/// 卡片封面仓库: 照片降采样出缩略图, 视频从文件头部抽首帧做封面。
/// 内存 + 磁盘两级缓存; 磁盘键为 "文件名.thumb", 同名文件内容不会变。
@MainActor
final class ThumbnailStore {
    static let shared = ThumbnailStore()

    private let memory = NSCache<NSString, UIImage>()
    private let thumbDir: URL
    private var inflight: [String: Task<UIImage?, Never>] = [:]

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        thumbDir = caches.appendingPathComponent("NovaDashThumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: thumbDir, withIntermediateDirectories: true)
        memory.countLimit = 400
    }

    /// 取封面 (nil = 暂无法生成, 界面显示占位图); 相同文件的并发请求自动合并。
    /// thm: 设备端生成的 .THM 伴生缩略图 (若有则优先使用)。
    func thumbnail(for file: DashcamFile, thm: DashcamFile? = nil) async -> UIImage? {
        if let hit = memory.object(forKey: file.id as NSString) { return hit }
        if let running = inflight[file.id] { return await running.value }

        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }
            defer { self.inflight[file.id] = nil }
            let image = await Self.generate(file, thm: thm, thumbDir: self.thumbDir)
            if let image {
                self.memory.setObject(image, forKey: file.id as NSString)
            }
            return image
        }
        inflight[file.id] = task
        return await task.value
    }

    // MARK: - 生成 (非主线程)

    private nonisolated static func generate(
        _ file: DashcamFile, thm: DashcamFile?, thumbDir: URL
    ) async -> UIImage? {
        let cached = UIImage(contentsOfFile: thumbURL(for: file, in: thumbDir).path)
        if let cached { return cached }

        let image: UIImage?
        switch file.kind {
        case .photo:
            image = await photoThumb(file)
        case .video:
            image = await videoCover(file, thm: thm)
        case .other:
            // .THM 等伴生文件本身就是小图
            image = await photoThumb(file)
        }
        if let image {
            try? image.jpegData(compressionQuality: 0.75)?
                .write(to: thumbURL(for: file, in: thumbDir))
        }
        return image
    }

    private nonisolated static func thumbURL(for file: DashcamFile, in dir: URL) -> URL {
        dir.appendingPathComponent(file.name + ".thumb")
    }

    /// 照片: 下载原图到缓存 (预览时复用), 再用 ImageIO 降采样, 避免整图解码
    private nonisolated static func photoThumb(_ file: DashcamFile) async -> UIImage? {
        guard let fullURL = try? await NovatekClient.shared.fetchPreviewFile(file) else { return nil }
        return downsample(fullURL)
    }

    /// 视频封面多级兜底:
    /// ① 设备原生缩略图 (下载 URL + ?custom=1&cmd=4001, 2026-09-19 实测: 直接返回约 28KB JPEG, 最快最省流量);
    /// ② 设备端 .THM 伴生缩略图 (部分固件才有);
    /// ③ 文件头部 1.5MB 抽帧 (FFmpeg 对截断文件容错良好);
    /// ④ 已缓存完整文件抽帧 (不专门为封面触发大文件下载);
    /// 都失败 → nil 占位。
    private nonisolated static func videoCover(_ file: DashcamFile, thm: DashcamFile?) async -> UIImage? {
        if let nativeURL = await NovatekClient.shared.fetchNativeThumbnail(for: file),
           let image = downsample(nativeURL) {
            return image
        }
        if let thm, let image = await photoThumb(thm) { return image }

        if let headURL = try? await NovatekClient.shared.fetchHead(file, maxBytes: 1_500_000) {
            if let image = FFmpegThumb.extractFrame(from: headURL) {
                return image
            }
            try? FileManager.default.removeItem(at: headURL)
        }

        if let cachedFull = await NovatekClient.shared.cachedPreviewURL(for: file) {
            if let image = FFmpegThumb.extractFrame(from: cachedFull) {
                return image
            }
        }
        return nil
    }

    /// ImageIO 降采样读图 (封面场景无需整图解码)
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
}
