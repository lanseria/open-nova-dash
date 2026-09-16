import Foundation
import CoreMedia
import VideoToolbox

/// H.264 VideoToolbox 硬解码: 输入一帧的 NAL 列表 (可含 SPS/PPS),
/// 输出解码后的 CVPixelBuffer (BGRA, Metal 兼容)。
/// 流内/SDP 参数集变化时自动重建解压会话。
final class H264Decoder: @unchecked Sendable {
    /// 解码回调 (VT 内部线程), 由持有方保证线程安全
    var onFrame: (@Sendable (CVPixelBuffer) -> Void)?

    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?
    private var currentSPS: Data?
    private var currentPPS: Data?
    private var frameIndex: Int64 = 0

    var isConfigured: Bool { session != nil }

    func decode(frame: [Data]) {
        var sps: Data?
        var pps: Data?
        var slices: [Data] = []
        for nal in frame {
            guard let type = nal.first.map({ $0 & 0x1F }) else { continue }
            switch type {
            case 7: sps = nal
            case 8: pps = nal
            case 1, 5, 6: slices.append(nal)   // 非IDR/IDR/SEI
            default: break                     // AUD(9) 等直接丢弃
            }
        }

        if let sps, let pps, sps != currentSPS || pps != currentPPS {
            if let newFormat = Self.makeFormat(sps: sps, pps: pps) {
                if let old = session { VTDecompressionSessionInvalidate(old) }
                session = Self.makeSession(format: newFormat) { [weak self] pixelBuffer in
                    self?.onFrame?(pixelBuffer)
                }
                format = newFormat
                currentSPS = sps
                currentPPS = pps
            }
        }
        // 只在拿到切片且已配置时送解 (第一个 IDR 前的孤立 NAL 丢弃)
        guard let session, format != nil, !slices.isEmpty else { return }

        frameIndex += 1
        let sample = Self.makeSampleBuffer(nals: slices, format: format!, index: frameIndex)
        guard let sample else { return }
        VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [], frameRefcon: nil, infoFlagsOut: nil
        )
        // 输出经回调异步到达; 码流乱序/丢包由 VT 自行容错
    }

    func stop() {
        if let old = session { VTDecompressionSessionInvalidate(old) }
        session = nil
        format = nil
        currentSPS = nil
        currentPPS = nil
    }

    // MARK: - 格式与会话

    /// SPS/PPS → avcC 扩展原子 → CMVideoFormatDescription
    private static func makeFormat(sps: Data, pps: Data) -> CMFormatDescription? {
        let spsBytes = [UInt8](sps)
        let ppsBytes = [UInt8](pps)
        guard spsBytes.count > 4, !ppsBytes.isEmpty else { return nil }

        var avcC = Data()
        avcC.append(0x01)                                   // configurationVersion
        avcC.append(contentsOf: spsBytes[1...3])            // profile / compat / level
        avcC.append(0xFF)                                   // 4 字节 NALU 长度前缀
        avcC.append(0xE1)                                   // 1 个 SPS
        avcC.append(UInt8(spsBytes.count >> 8))
        avcC.append(UInt8(spsBytes.count & 0xFF))
        avcC.append(sps)
        avcC.append(0x01)                                   // 1 个 PPS
        avcC.append(UInt8(ppsBytes.count >> 8))
        avcC.append(UInt8(ppsBytes.count & 0xFF))
        avcC.append(pps)

        var format: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_H264,
            width: 0, height: 0,
            extensions: [
                kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: [avcC]
            ] as CFDictionary,
            formatDescriptionOut: &format
        )
        return status == noErr ? format : nil
    }

    private static func makeSession(
        format: CMFormatDescription,
        onFrame: @escaping @Sendable (CVPixelBuffer) -> Void
    ) -> VTDecompressionSession? {
        let context = Unmanaged.passRetained(H264BridgeSink(onFrame: onFrame)).toOpaque()
        var record = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: h264DecodeOutputCallback,
            decompressionOutputRefCon: context
        )
        var session: VTDecompressionSession?
        let attributes: CFDictionary = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ] as CFDictionary
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: attributes,
            outputCallback: &record,
            decompressionSessionOut: &session
        )
        if status != noErr {
            Unmanaged<H264BridgeSink>.fromOpaque(context).release()
            return nil
        }
        return session
    }

    private static func makeSampleBuffer(
        nals: [Data], format: CMFormatDescription, index: Int64
    ) -> CMSampleBuffer? {
        var avcc = Data()
        for nal in nals {
            let count = UInt32(nal.count)
            avcc.append(UInt8(count >> 24))
            avcc.append(UInt8((count >> 16) & 0xFF))
            avcc.append(UInt8((count >> 8) & 0xFF))
            avcc.append(UInt8(count & 0xFF))
            avcc.append(nal)
        }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else { return nil }
        status = avcc.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avcc.count
            )
        }
        guard status == noErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        let size = avcc.count
        let timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 30),
            decodeTimeStamp: .invalid
        )
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: [timing],
            sampleSizeEntryCount: 1,
            sampleSizeArray: [size],
            sampleBufferOut: &sampleBuffer
        )
        return status == noErr ? sampleBuffer : nil
    }
}

/// 桥接 VT C 回调 → Swift 闭包 (回调记录只持有指针, 需要 Objective-C 桥对象保活)
private final class H264BridgeSink: @unchecked Sendable {
    let onFrame: @Sendable (CVPixelBuffer) -> Void
    init(onFrame: @escaping @Sendable (CVPixelBuffer) -> Void) {
        self.onFrame = onFrame
    }
}

private func h264DecodeOutputCallback(
    decompressionOutputRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTDecodeInfoFlags,
    pixelBuffer: CVPixelBuffer?,
    presentationTimeStamp: CMTime,
    presentationDuration: CMTime
) {
    guard status == noErr, let pixelBuffer, let refCon = decompressionOutputRefCon else { return }
    let sink = Unmanaged<H264BridgeSink>.fromOpaque(refCon).takeUnretainedValue()
    sink.onFrame(pixelBuffer)
    _ = sourceFrameRefCon
}
