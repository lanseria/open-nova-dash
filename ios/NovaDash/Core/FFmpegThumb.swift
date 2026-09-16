import UIKit
import Libavformat
import Libavcodec
import Libavutil
import Libswscale

/// 基于 FFmpeg (libavformat/libavcodec/libswscale) 的首帧提取器。
/// 能解 iOS AVFoundation 不支持的容器/编码 (记录仪 TS/H.265/MPEG-2),
/// 且对截断文件 (fetchHead 的头部片段) 容错良好。
enum FFmpegThumb {
    /// 打开文件并解码到第一帧, 缩放到 maxPixelSize 内后转 UIImage; 失败返回 nil
    static func extractFrame(from url: URL, maxPixelSize: Int32 = 640) -> UIImage? {
        var context: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&context, url.path, nil, nil) == 0, let formatContext = context else {
            return nil
        }
        defer { avformat_close_input(&context) }
        guard avformat_find_stream_info(formatContext, nil) >= 0 else { return nil }

        // 手动找视频流 (该构建的 av_find_best_stream 参数类型导入有歧义)
        var streamIndex = -1
        for index in 0..<Int(formatContext.pointee.nb_streams) {
            guard let candidate = formatContext.pointee.streams?[index] else { continue }
            if candidate.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
                streamIndex = index
                break
            }
        }
        guard streamIndex >= 0, let stream = formatContext.pointee.streams?[streamIndex] else {
            return nil
        }

        guard let decoder = avcodec_find_decoder(stream.pointee.codecpar.pointee.codec_id) else {
            return nil
        }
        var codecContext = avcodec_alloc_context3(decoder)
        defer { avcodec_free_context(&codecContext) }
        guard let codecContext,
              avcodec_parameters_to_context(codecContext, stream.pointee.codecpar) >= 0,
              avcodec_open2(codecContext, decoder, nil) == 0 else {
            return nil
        }

        var packet = av_packet_alloc()
        var frame = av_frame_alloc()
        defer {
            av_packet_free(&packet)
            av_frame_free(&frame)
        }
        guard packet != nil, frame != nil else { return nil }

        // 逐包喂给解码器, 拿到第一帧就返回 (截断文件的读取错误按 EOF 处理)
        while av_read_frame(formatContext, packet!) >= 0 {
            defer { av_packet_unref(packet!) }
            guard packet!.pointee.stream_index == streamIndex else { continue }
            guard avcodec_send_packet(codecContext, packet!) == 0 else { continue }
            if avcodec_receive_frame(codecContext, frame!) == 0 {
                if let image = render(frame: frame!, maxPixelSize: maxPixelSize) {
                    return image
                }
            }
            av_frame_unref(frame!)
        }
        return nil
    }

    /// YUV/其他像素格式 → RGBA → UIImage
    private static func render(frame: UnsafeMutablePointer<AVFrame>, maxPixelSize: Int32) -> UIImage? {
        let width = frame.pointee.width
        let height = frame.pointee.height
        guard width > 0, height > 0 else { return nil }

        var outWidth = width
        var outHeight = height
        if max(width, height) > maxPixelSize {
            let ratio = Float(maxPixelSize) / Float(max(width, height))
            outWidth = Int32(Float(width) * ratio)
            outHeight = Int32(Float(height) * ratio)
        }

        // 该构建里像素格式枚举按 AVPixelFormat 导入, 可用 Int32 非可失败初始化
        guard let swsContext = sws_getContext(
            width, height, AVPixelFormat(frame.pointee.format),
            outWidth, outHeight, AV_PIX_FMT_RGBA,
            SWS_BILINEAR, nil, nil, nil
        ) else {
            return nil
        }
        defer { sws_freeContext(swsContext) }

        var pixels = [UInt8](repeating: 0, count: Int(outWidth * outHeight) * 4)
        var result: UIImage?
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var dstData: [UnsafeMutablePointer<UInt8>?] = [base, nil, nil, nil]
            var dstLinesize: [Int32] = [outWidth * 4, 0, 0, 0]
            // AVFrame.data/linesize 按 8 元素 C 定长数组导入为 Swift 元组
            let dataTuple = frame.pointee.data
            let strideTuple = frame.pointee.linesize
            var srcData: [UnsafePointer<UInt8>?] = [dataTuple.0, dataTuple.1, dataTuple.2, dataTuple.3, nil, nil, nil, nil]
                .map { (ptr: UnsafeMutablePointer<UInt8>?) -> UnsafePointer<UInt8>? in
                    ptr.map { UnsafePointer($0) }
                }
            var srcLinesize: [Int32] = [strideTuple.0, strideTuple.1, strideTuple.2, strideTuple.3, 0, 0, 0, 0]
            sws_scale(
                swsContext,
                &srcData, &srcLinesize,
                0, height,
                &dstData, &dstLinesize
            )
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
            let bitmap = CGContext(
                data: base, width: Int(outWidth), height: Int(outHeight),
                bitsPerComponent: 8, bytesPerRow: Int(outWidth) * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            if let cgImage = bitmap?.makeImage() {
                result = UIImage(cgImage: cgImage)
            }
        }
        return result
    }
}
