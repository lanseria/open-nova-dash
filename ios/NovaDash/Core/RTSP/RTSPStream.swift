import SwiftUI
import MetalKit
import CoreVideo

/// 最新解码帧的线程安全槽位: VT 解码线程写入, Metal 渲染线程读取
final class FrameSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?

    func update(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        buffer = pixelBuffer
        lock.unlock()
    }

    func latest() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

/// RTSP 直播会话: 拉流 → 解包 → 硬解 → 帧槽位
@MainActor
@Observable
final class RTSPStreamModel {
    enum Phase: Equatable {
        case idle
        case connecting
        case streaming
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var frameCount = 0
    let frameSlot = FrameSlot()

    private var client: RTSPClient?
    private let decoder = H264Decoder()

    func start(urlString: String) {
        guard phase != .connecting, phase != .streaming else { return }
        guard let url = URL(string: urlString), url.scheme == "rtsp", url.host != nil else {
            phase = .failed("RTSP 地址无效 (示例: rtsp://192.168.1.254/stream0)")
            return
        }
        phase = .connecting
        frameCount = 0

        decoder.onFrame = { [weak self] pixelBuffer in
            self?.frameSlot.update(pixelBuffer)
            Task { @MainActor in self?.frameCount += 1 }
        }

        let newClient = RTSPClient(url: url) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        client = newClient
        newClient.connectAndPlay()
    }

    func stop() {
        client?.teardown()
        client = nil
        decoder.stop()
        phase = .idle
    }

    private func handle(_ event: RTSPClient.Event) {
        switch event {
        case .connecting, .negotiating:
            if phase != .streaming { phase = .connecting }
        case .playing:
            phase = .streaming
        case .accessUnit(let unit):
            decoder.decode(frame: unit)
        case .failed(let message):
            phase = .failed(message)
        }
    }
}

/// 直播画面 (MTKView + 逐帧拉取帧槽位)
struct RTSPSurface: UIViewRepresentable {
    let model: RTSPStreamModel

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 30
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.delegate = context.coordinator.renderer
        context.coordinator.renderer.frameProvider = { [weak slot = model.frameSlot] in
            slot?.latest()
        }
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {}

    final class Coordinator {
        let renderer: MetalRenderer
        init() {
            renderer = MetalRenderer()
        }
    }
}

/// 用 Metal 绘制 CVPixelBuffer (BGRA), 按画面比例 letterbox
final class MetalRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    var frameProvider: (@Sendable () -> CVPixelBuffer?)?

    override init() {
        let device = MTLCreateSystemDefaultDevice()!
        self.device = device
        commandQueue = device.makeCommandQueue()!

        let library = device.makeDefaultLibrary()
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library?.makeFunction(name: "streamVertex")
        descriptor.fragmentFunction = library?.makeFunction(name: "streamFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try! device.makeRenderPipelineState(descriptor: descriptor)
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pixelBuffer = frameProvider?(),
              let texture = texture(of: pixelBuffer),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else {
            return
        }

        // letterbox: 画面比例适配视图比例
        let viewAspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
        let frameAspect = Float(CVPixelBufferGetWidth(pixelBuffer)) / Float(max(CVPixelBufferGetHeight(pixelBuffer), 1))
        var scaleX: Float = 1, scaleY: Float = 1
        if frameAspect > viewAspect {
            scaleY = viewAspect / frameAspect
        } else {
            scaleX = frameAspect / viewAspect
        }
        let positions: [SIMD2<Float>] = [
            SIMD2(-scaleX, -scaleY), SIMD2(scaleX, -scaleY),
            SIMD2(-scaleX, scaleY), SIMD2(scaleX, scaleY),
        ]
        let uvs: [SIMD2<Float>] = [
            SIMD2(0, 1), SIMD2(1, 1), SIMD2(0, 0), SIMD2(1, 0),
        ]

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(positions, length: MemoryLayout<SIMD2<Float>>.stride * 4, index: 0)
        encoder.setVertexBytes(uvs, length: MemoryLayout<SIMD2<Float>>.stride * 4, index: 1)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func texture(of pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let textureCache else { return nil }
        var cvTexture: CVMetalTexture?
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture
        )
        guard status == kCVReturnSuccess else { return nil }
        return cvTexture.flatMap { CVMetalTextureGetTexture($0) }
    }
}
