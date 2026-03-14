import Foundation
import Metal
import MetalKit
import CoreVideo
import Flutter
import AVFoundation

// ─────────────────────────────────────────────────────────────────────────────
// CCDParams — 与 Metal shader 中 struct CCDParams 对应（字段顺序必须一致）
// ─────────────────────────────────────────────────────────────────────────────
struct CCDParams {
    var contrast: Float = 1.0
    var saturation: Float = 1.0
    var temperatureShift: Float = 0.0
    var tintShift: Float = 0.0
    var grainAmount: Float = 0.0
    var noiseAmount: Float = 0.0
    var vignetteAmount: Float = 0.0
    var chromaticAberration: Float = 0.0
    var bloomAmount: Float = 0.0
    var halationAmount: Float = 0.0
    var sharpen: Float = 0.0
    var blurRadius: Float = 0.0
    var jpegArtifacts: Float = 0.0
    var time: Float = 0.0
}

// ─────────────────────────────────────────────────────────────────────────────
// MetalRenderer
// ─────────────────────────────────────────────────────────────────────────────
class MetalRenderer: NSObject, FlutterTexture, AVCaptureVideoDataOutputSampleBufferDelegate {

    // MARK: - Flutter Texture

    private(set) var textureId: Int64 = -1
    private let registry: FlutterTextureRegistry
    private var currentPixelBuffer: CVPixelBuffer?
    private let pixelBufferLock = NSLock()

    // MARK: - Metal

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache?
    private var renderPipelineState: MTLRenderPipelineState?
    private var vertexBuffer: MTLBuffer?
    private var outputPixelBufferPool: CVPixelBufferPool?

    // MARK: - Shader Params

    private var ccdParams = CCDParams()
    private let paramsLock = NSLock()

    // MARK: - External Textures

    private var lutTexture: MTLTexture?
    private var grainTexture: MTLTexture?
    private var textureLoader: MTKTextureLoader?

    // MARK: - Asset Bundle

    /// 由 CameraPlugin 注入，用于查找 Flutter asset 路径
    var assetBundle: Bundle?
    var assetLookup: ((String) -> String?)?

    // MARK: - Init

    init(registry: FlutterTextureRegistry) {
        guard let mtlDevice = MTLCreateSystemDefaultDevice(),
              let queue = mtlDevice.makeCommandQueue() else {
            fatalError("[MetalRenderer] Metal is not supported on this device")
        }
        self.device = mtlDevice
        self.commandQueue = queue
        self.registry = registry
        super.init()

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        textureLoader = MTKTextureLoader(device: device)
        setupVertexBuffer()
        setupRenderPipeline()
    }

    // MARK: - Setup

    private func setupVertexBuffer() {
        // Full-screen quad: position (x,y,z,w) + texCoord (u,v)
        // Triangle strip: TL, BL, TR, BR
        let vertices: [Float] = [
            -1.0,  1.0, 0.0, 1.0,   0.0, 0.0,  // top-left
            -1.0, -1.0, 0.0, 1.0,   0.0, 1.0,  // bottom-left
             1.0,  1.0, 0.0, 1.0,   1.0, 0.0,  // top-right
             1.0, -1.0, 0.0, 1.0,   1.0, 1.0,  // bottom-right
        ]
        vertexBuffer = device.makeBuffer(bytes: vertices,
                                         length: vertices.count * MemoryLayout<Float>.size,
                                         options: .storageModeShared)
    }

    private func setupRenderPipeline() {
        guard let library = device.makeDefaultLibrary() else {
            print("[MetalRenderer] Failed to load default Metal library")
            return
        }

        guard let vertexFn = library.makeFunction(name: "vertexShader"),
              let fragmentFn = library.makeFunction(name: "ccdFragmentShader") else {
            print("[MetalRenderer] Failed to find shader functions")
            return
        }

        // Vertex descriptor matching VertexIn in shader
        let vertexDescriptor = MTLVertexDescriptor()
        // attribute(0): position float4
        vertexDescriptor.attributes[0].format = .float4
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        // attribute(1): texCoord float2
        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].offset = MemoryLayout<Float>.size * 4
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<Float>.size * 6

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFn
        pipelineDescriptor.fragmentFunction = fragmentFn
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            renderPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print("[MetalRenderer] Pipeline creation failed: \(error)")
        }
    }

    // MARK: - Texture ID

    func setTextureId(_ id: Int64) {
        self.textureId = id
    }

    // MARK: - Params Update

    func updateParams(_ params: [String: Any]) {
        paramsLock.lock()
        defer { paramsLock.unlock() }

        if let v = params["contrast"] as? Float { ccdParams.contrast = v }
        if let v = params["saturation"] as? Float { ccdParams.saturation = v }
        if let v = params["temperatureShift"] as? Float { ccdParams.temperatureShift = v }
        if let v = params["tintShift"] as? Float { ccdParams.tintShift = v }
        if let v = params["grainAmount"] as? Float { ccdParams.grainAmount = v }
        if let v = params["noise"] as? Float { ccdParams.noiseAmount = v }
        if let v = params["vignette"] as? Float { ccdParams.vignetteAmount = v }
        if let v = params["chromaticAberration"] as? Float { ccdParams.chromaticAberration = v }
        if let v = params["bloom"] as? Float { ccdParams.bloomAmount = v }
        if let v = params["halation"] as? Float { ccdParams.halationAmount = v }

        // 加载 LUT 纹理
        if let lutAsset = params["lut"] as? String, !lutAsset.isEmpty {
            loadAssetTexture(assetPath: lutAsset) { [weak self] texture in
                self?.lutTexture = texture
            }
        }

        // 加载 Grain 纹理
        if let grainAsset = params["grain"] as? String, !grainAsset.isEmpty {
            loadAssetTexture(assetPath: grainAsset) { [weak self] texture in
                self?.grainTexture = texture
            }
        }
    }

    // MARK: - Texture Loading

    private func loadAssetTexture(assetPath: String, completion: @escaping (MTLTexture?) -> Void) {
        guard let loader = textureLoader else {
            completion(nil)
            return
        }

        // 尝试从 Flutter asset 路径查找文件
        var fileURL: URL?

        // 1. 通过 assetLookup 闭包（由 CameraPlugin 注入）查找
        if let lookup = assetLookup, let key = lookup(assetPath) {
            fileURL = Bundle.main.url(forResource: key, withExtension: nil)
                ?? URL(fileURLWithPath: key)
        }

        // 2. 直接在 Bundle.main 中查找
        if fileURL == nil {
            let lastComponent = (assetPath as NSString).lastPathComponent
            let nameWithoutExt = (lastComponent as NSString).deletingPathExtension
            let ext = (lastComponent as NSString).pathExtension
            fileURL = Bundle.main.url(forResource: nameWithoutExt, withExtension: ext)
        }

        // 3. 在 Flutter assets 目录下查找
        if fileURL == nil {
            let flutterAssetPath = "Frameworks/App.framework/flutter_assets/" + assetPath
            fileURL = Bundle.main.url(forResource: flutterAssetPath, withExtension: nil)
        }

        guard let url = fileURL else {
            print("[MetalRenderer] Asset not found: \(assetPath)")
            completion(nil)
            return
        }

        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: false,
            .generateMipmaps: false
        ]

        loader.newTexture(URL: url, options: options) { texture, error in
            if let error = error {
                print("[MetalRenderer] Texture load error for \(assetPath): \(error)")
            }
            completion(texture)
        }
    }

    // MARK: - FlutterTexture

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        pixelBufferLock.lock()
        defer { pixelBufferLock.unlock() }
        guard let buffer = currentPixelBuffer else { return nil }
        return Unmanaged.passRetained(buffer)
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        renderFrame(from: pixelBuffer)
    }

    // MARK: - Render

    private func renderFrame(from pixelBuffer: CVPixelBuffer) {
        guard let cache = textureCache,
              let pipelineState = renderPipelineState,
              let vBuffer = vertexBuffer else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // 确保输出 PixelBuffer Pool 已创建
        ensureOutputPool(width: width, height: height)
        guard let pool = outputPixelBufferPool else { return }

        var outputPixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outputPixelBuffer) == kCVReturnSuccess,
              let outBuffer = outputPixelBuffer else { return }

        // 创建输入 Metal 纹理
        var cvTextureIn: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTextureIn)
        guard let cvIn = cvTextureIn,
              let textureIn = CVMetalTextureGetTexture(cvIn) else { return }

        // 创建输出 Metal 纹理
        var cvTextureOut: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, outBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTextureOut)
        guard let cvOut = cvTextureOut,
              let textureOut = CVMetalTextureGetTexture(cvOut) else { return }

        // 构建渲染通道
        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = textureOut
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        passDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vBuffer, offset: 0, index: 0)
        encoder.setFragmentTexture(textureIn, index: 0)
        if let lut = lutTexture   { encoder.setFragmentTexture(lut,   index: 1) }
        if let grain = grainTexture { encoder.setFragmentTexture(grain, index: 2) }

        paramsLock.lock()
        ccdParams.time += 0.016
        var params = ccdParams
        paramsLock.unlock()

        encoder.setFragmentBytes(&params, length: MemoryLayout<CCDParams>.size, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        pixelBufferLock.lock()
        currentPixelBuffer = outBuffer
        pixelBufferLock.unlock()

        if textureId != -1 {
            registry.textureFrameAvailable(textureId)
        }
    }

    private func ensureOutputPool(width: Int, height: Int) {
        guard outputPixelBufferPool == nil else { return }
        let poolAttrs: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 3]
        let bufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                poolAttrs as CFDictionary,
                                bufferAttrs as CFDictionary,
                                &outputPixelBufferPool)
    }

    // MARK: - Capture Current Frame (for photo composition)

    /// 将当前帧渲染为 UIImage，供拍照后合成使用
    func captureCurrentFrame() -> UIImage? {
        pixelBufferLock.lock()
        guard let buffer = currentPixelBuffer else {
            pixelBufferLock.unlock()
            return nil
        }
        // retain 一份，避免锁内做耗时操作
        let retained = buffer
        pixelBufferLock.unlock()

        let ciImage = CIImage(cvPixelBuffer: retained)
        let context = CIContext()
        let width = CVPixelBufferGetWidth(retained)
        let height = CVPixelBufferGetHeight(retained)
        guard let cgImage = context.createCGImage(ciImage, from: CGRect(x: 0, y: 0, width: width, height: height)) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
