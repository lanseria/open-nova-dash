import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// TS → MP4 容器重封装 (remux, 无转码, 编码参数原样拷贝)。
/// 记录仪循环录像为 MPEG-TS 容器, iOS 相册/分享生态不认 TS;
/// ffmpeg 6.1 的 mp4 复用器会自动完成 H.264/H.265 Annex-B→avcC/hvcC、
/// AAC ADTS→ASC 的码流级转换, 速度接近文件拷贝且画质无损。
/// 同类先例见 FFmpegThumb (该构建的 libav 均为裸 C API)。
enum TSRemux {
    struct RemuxError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 把 source 重封装为 destination (扩展名 .mp4); 失败抛 RemuxError, 不影响源文件。
    /// 同步阻塞 (纯本地读写, 不占设备 HTTP 通道), 调用方自行放到后台执行。
    static func remuxToMP4(from source: URL, to destination: URL) throws {
        var input: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&input, source.path, nil, nil) == 0, let inCtx = input else {
            throw RemuxError(message: "无法打开源文件")
        }
        defer { avformat_close_input(&input) }
        guard avformat_find_stream_info(inCtx, nil) >= 0 else {
            throw RemuxError(message: "无法解析流信息")
        }

        var output: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_alloc_output_context2(&output, nil, "mp4", destination.path) >= 0,
              let outCtx = output else {
            throw RemuxError(message: "无法创建 MP4 输出")
        }
        defer {
            if outCtx.pointee.pb != nil {
                var pb = outCtx.pointee.pb
                avio_closep(&pb)
                outCtx.pointee.pb = nil
            }
            avformat_free_context(outCtx)
        }

        // 只搬运音频/视频流并记录索引映射 (TS 里的数据流 MP4 复用器不支持)
        var streamMap: [Int32: Int32] = [:]
        for index in 0..<Int(inCtx.pointee.nb_streams) {
            guard let inStream = inCtx.pointee.streams?[index] else { continue }
            let mediaType = inStream.pointee.codecpar.pointee.codec_type
            guard mediaType == AVMEDIA_TYPE_VIDEO || mediaType == AVMEDIA_TYPE_AUDIO else {
                continue
            }
            guard let outStream = avformat_new_stream(outCtx, nil) else {
                throw RemuxError(message: "无法创建输出流")
            }
            guard avcodec_parameters_copy(outStream.pointee.codecpar, inStream.pointee.codecpar) >= 0 else {
                throw RemuxError(message: "拷贝编码参数失败")
            }
            // TS demuxer 写入的 stream_type tag (如 H.264 的 0x1B) 与 MP4 不兼容,
            // 清零让 MP4 复用器自选标准 tag — ffmpeg CLI streamcopy 同款处理;
            // HEVC 例外: 复用器默认 hev1 (参数集留在流内), Apple 生态只认 hvc1,
            // 显式指定 (ffmpeg CLI 等价 -tag:v hvc1)
            if inStream.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_HEVC {
                outStream.pointee.codecpar.pointee.codec_tag = 0x3163_7668  // MKTAG('h','v','c','1')
            } else {
                outStream.pointee.codecpar.pointee.codec_tag = 0
            }
            // write_header 前的初始时基, 之后 mp4 复用器会自行调整
            outStream.pointee.time_base = inStream.pointee.time_base
            streamMap[Int32(index)] = outStream.pointee.index
        }
        guard !streamMap.isEmpty else {
            throw RemuxError(message: "源文件没有音视频流")
        }

        // MPEG-TS 常带非零起始时间戳 (典型 1.4s 初始延迟), 原样写入 MP4 会变成
        // 开头空白段; 与 ffmpeg CLI remux 默认行为一致, 把时间轴归零
        let startTimeUS = inCtx.pointee.start_time
        let noPTS = Int64(bitPattern: 0x8000_0000_0000_0000)
        let needsShift = startTimeUS != noPTS && startTimeUS > 0

        var io = outCtx.pointee.pb
        guard avio_open(&io, destination.path, AVIO_FLAG_WRITE) >= 0 else {
            throw RemuxError(message: "无法创建输出文件")
        }
        outCtx.pointee.pb = io
        guard avformat_write_header(outCtx, nil) >= 0 else {
            throw RemuxError(message: "写入 MP4 头失败")
        }

        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        guard packet != nil else { throw RemuxError(message: "内存不足") }

        while av_read_frame(inCtx, packet!) >= 0 {
            defer { av_packet_unref(packet!) }
            guard let outIndex = streamMap[packet!.pointee.stream_index],
                  let inStream = inCtx.pointee.streams?[Int(packet!.pointee.stream_index)],
                  let outStream = outCtx.pointee.streams?[Int(outIndex)] else { continue }
            if needsShift {
                let inTB = inStream.pointee.time_base
                // 微秒 → 输入流时基 (AV_TIME_BASE_Q = 1/1000000 宏, 该构建未导入, 手写)
                let shift = av_rescale_q(startTimeUS, AVRational(num: 1, den: 1_000_000), inTB)
                if packet!.pointee.pts != noPTS { packet!.pointee.pts -= shift }
                if packet!.pointee.dts != noPTS { packet!.pointee.dts -= shift }
            }
            // TS 流时基 (90k) → mp4 复用器选定的新时基
            av_packet_rescale_ts(
                packet!,
                inStream.pointee.time_base,
                outStream.pointee.time_base
            )
            packet!.pointee.pos = -1
            packet!.pointee.stream_index = outIndex
            guard av_interleaved_write_frame(outCtx, packet!) >= 0 else {
                throw RemuxError(message: "写入数据包失败")
            }
        }
        guard av_write_trailer(outCtx) >= 0 else {
            throw RemuxError(message: "收尾写入失败")
        }
    }
}
