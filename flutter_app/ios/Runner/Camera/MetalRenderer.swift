import Foundation
import Metal
import MetalKit
import CoreVideo
import Flutter
import AVFoundation

// ─────────────────────────────────────────────────────────────────────────────
// CCDParams — 与 Metal shader 中 struct CCDParams 对应（字段顺序必须一致）
// 注意：新增字段只能追加到末尾，不能插入中间，否则 Metal 内存对齐会错位
// ─────────────────────────────────────────────────────────────────────────────
struct CCDParams {
    // ── 通用参数（所有相机共用）──────────────────────────────────────────────
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
    var fisheyeMode: Float = 0.0  // 1.0=圆形鱼眼模式, 0.0=普通模式
    var aspectRatio: Float = 0.75 // 宽/高 比例（默认 3:4 竖屏）
    // ── FQS / CPM35 专用扩展字段（通用 Shader 忽略这些字段）──────────────────
    var colorBiasR: Float = 0.0       // RGB Channel Shift R（FQS=-0.04, CPM35=+0.04）
    var colorBiasG: Float = 0.0       // RGB Channel Shift G（FQS=+0.05, CPM35=+0.02）
    var colorBiasB: Float = 0.0       // RGB Channel Shift B（FQS=+0.02, CPM35=-0.04）
    var grainSize: Float = 1.0        // 颗粒大小（FQS=1.8, CPM35=1.6）
    var sharpness: Float = 1.0        // 锐度倍数（FQS=0.85, CPM35=1.04）
    var highlightWarmAmount: Float = 0.0 // CPM35 暖高光推送（CPM35=0.06）
    var luminanceNoise: Float = 0.0   // 亮度噪声（FQS=0.08, CPM35=0.05）
    var chromaNoise: Float = 0.0      // 色度噪声（FQS=0.05, CPM35=0.03）
    // ── Inst C 专用扩展字段（其他相机的 Shader 忽略这些字段）──────────────────
    var highlightRolloff: Float = 0.0   // 高光柔和滴落（Inst C=0.20，SQC=0.28）
    var paperTexture: Float = 0.0       // 相纸纹理强度（Inst C=0.06，SQC=0.05）
    var edgeFalloff: Float = 0.0        // 边缘曝光衰减（Inst C=0.05，SQC=0.06）
    var exposureVariation: Float = 0.0  // 曝光不均匀幅度（Inst C=0.04，SQC=0.05）
    var cornerWarmShift: Float = 0.0    // 边角偏暖强度（Inst C=0.02，SQC=0.03）
    // ── 拍立得通用扩展字段（Inst C / SQC 共用）───────────────────────────────────────────────────
    var centerGain: Float = 0.0            // 中心增亮（Inst C=0.02，SQC=0.03）
    var developmentSoftness: Float = 0.0   // 显影柔化（Inst C=0.03，SQC=0.04）
    var chemicalIrregularity: Float = 0.0  // 化学不规则感（Inst C=0.015，SQC=0.02）
    var skinHueProtect: Float = 0.0        // 肤色色相保护（1.0=开启，0.0=关闭）
    var skinSatProtect: Float = 1.0        // 肤色饱和度保护（Inst C=0.92，SQC=0.95）
    var skinLumaSoften: Float = 0.0        // 肤色亮度柔化（Inst C=0.05，SQC=0.04）
    var skinRedLimit: Float = 1.0          // 肤色红限（Inst C=1.02，SQC=1.03）
    // ── FIX: Lightroom 风格曲线参数（新增字段必须追加到末尾，保持 Metal 内存对齐）───────────────────────
    var highlights: Float = 0.0             // 高光压缩/提亮（-100 ~ +100）
    var shadows: Float = 0.0               // 阴影压缩/提亮（-100 ~ +100）
    var whites: Float = 0.0                // 白场偏移（-100 ~ +100）
    var blacks: Float = 0.0                // 黑场偏移（-100 ~ +100）
    var clarity: Float = 0.0               // 中间调微对比度（-100 ~ +100）
    var vibrance: Float = 0.0              // 智能饱和度（-100 ~ +100）
    var noiseAmountExtra: Float = 0.0      // 预留字段，与 Metal Shader 中的 noiseAmountExtra 对应
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

    // MARK: - Triple-Buffer Semaphore
    // 限制最多 3 个 CommandBuffer 同时在 GPU 上飞行，防止 CPU 过度超前提交
    // 使用 3 而非 2 是为了在 60fps 场景下保持流畅（每帧 ~16ms，GPU 处理 ~8ms）
    private let inflightSemaphore = DispatchSemaphore(value: 3)

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

    // MARK: - Camera ID（用于动态切换 Fragment Shader）

    /// 当前相机 ID，切换时自动重建 Pipeline
    private var _currentCameraId: String = ""
    private let pipelineLock = NSLock()

    var currentCameraId: String {
        get {
            pipelineLock.lock()
            defer { pipelineLock.unlock() }
            return _currentCameraId
        }
        set {
            pipelineLock.lock()
            let changed = _currentCameraId != newValue
            _currentCameraId = newValue
            pipelineLock.unlock()
            if changed {
                // Pipeline 重建必须在主线程或专用队列，不能在 AVFoundation 采集线程
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.rebuildPipeline()
                }
            }
        }
    }

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

    /// 初始化时使用默认 CCD Shader
    private func setupRenderPipeline() {
        buildPipeline(cameraId: "")
    }

    /// 相机切换时重建 Pipeline（在 background queue 调用）
    private func rebuildPipeline() {
        pipelineLock.lock()
        let camId = _currentCameraId
        pipelineLock.unlock()
        buildPipeline(cameraId: camId)
    }

    /// 根据相机 ID 选择对应的 Fragment Shader 并构建 MTLRenderPipelineState
    ///
    /// 映射规则：
    ///   fqs   → fqsVertexShader   / fqsFragmentShader   (FQSShader.metal)
    ///   cpm35 → cpm35VertexShader / cpm35FragmentShader  (CPM35Shader.metal)
    ///   其他  → vertexShader      / ccdFragmentShader    (CameraShaders.metal)
    private func buildPipeline(cameraId: String) {
        guard let library = device.makeDefaultLibrary() else {
            print("[MetalRenderer] Failed to load default Metal library")
            return
        }

        let vertexName: String
        let fragmentName: String

        switch cameraId {
        case "fqs":
            vertexName   = "fqsVertexShader"
            fragmentName = "fqsFragmentShader"
        case "cpm35":
            vertexName   = "cpm35VertexShader"
            fragmentName = "cpm35FragmentShader"
        case "inst_c":
            vertexName   = "instcVertexShader"
            fragmentName = "instcFragmentShader"
        case "sqc":
            vertexName   = "sqcVertexShader"
            fragmentName = "sqcFragmentShader"
        case "grd_r":
            vertexName   = "grdrVertexShader"
            fragmentName = "grdrFragmentShader"
        case "u300":
            vertexName   = "u300VertexShader"
            fragmentName = "u300FragmentShader"
        case "ccd_r":
            vertexName   = "ccdrVertexShader"
            fragmentName = "ccdrFragmentShader"
        case "bw_classic":
            vertexName   = "bwClassicVertexShader"
            fragmentName = "bwClassicFragmentShader"
        default:
            vertexName   = "vertexShader"
            fragmentName = "ccdFragmentShader"
        }

        // 尝试加载目标 Shader，失败时降级到通用 CCD Shader
        let vertexFn: MTLFunction
        let fragmentFn: MTLFunction

        if let vFn = library.makeFunction(name: vertexName),
           let fFn = library.makeFunction(name: fragmentName) {
            vertexFn   = vFn
            fragmentFn = fFn
            print("[MetalRenderer] Using shader: \(fragmentName)")
        } else {
            print("[MetalRenderer] Shader '\(fragmentName)' not found, falling back to ccdFragmentShader")
            guard let fallbackV = library.makeFunction(name: "vertexShader"),
                  let fallbackF = library.makeFunction(name: "ccdFragmentShader") else {
                print("[MetalRenderer] Fallback shader also missing!")
                return
            }
            vertexFn   = fallbackV
            fragmentFn = fallbackF
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
        pipelineDescriptor.vertexFunction   = vertexFn
        pipelineDescriptor.fragmentFunction = fragmentFn
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            let newState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
            // 原子替换，renderFrame 下一帧立即生效
            pipelineLock.lock()
            renderPipelineState = newState
            pipelineLock.unlock()
            print("[MetalRenderer] Pipeline ready: \(fragmentName)")
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
        // 相机 ID 切换不需要持锁，单独处理
        if let camId = params["cameraId"] as? String, !camId.isEmpty {
            currentCameraId = camId   // 触发 didSet → rebuildPipeline()
        }

        paramsLock.lock()
        defer { paramsLock.unlock() }

        // ── 通用参数 ─────────────────────────────────────────────────────────
        if let v = params["contrast"]            as? Float { ccdParams.contrast            = v }
        if let v = params["saturation"]          as? Float { ccdParams.saturation          = v }
        if let v = params["temperatureShift"]    as? Float { ccdParams.temperatureShift    = v }
        if let v = params["tintShift"]           as? Float { ccdParams.tintShift           = v }
        if let v = params["grainAmount"]         as? Float { ccdParams.grainAmount         = v }
        if let v = params["noise"]               as? Float { ccdParams.noiseAmount         = v }
        if let v = params["vignette"]            as? Float { ccdParams.vignetteAmount      = v }
        if let v = params["chromaticAberration"] as? Float { ccdParams.chromaticAberration = v }
        if let v = params["bloom"]               as? Float { ccdParams.bloomAmount         = v }
        if let v = params["halation"]            as? Float { ccdParams.halationAmount      = v }
        if let v = params["sharpen"]             as? Float { ccdParams.sharpen             = v }

        // ── FQS / CPM35 专用参数 ─────────────────────────────────────────────
        if let v = params["colorBiasR"]          as? Float { ccdParams.colorBiasR          = v }
        if let v = params["colorBiasG"]          as? Float { ccdParams.colorBiasG          = v }
        if let v = params["colorBiasB"]          as? Float { ccdParams.colorBiasB          = v }
        if let v = params["grainSize"]           as? Float { ccdParams.grainSize           = v }
        if let v = params["sharpness"]           as? Float { ccdParams.sharpness           = v }
        if let v = params["highlightWarmAmount"] as? Float { ccdParams.highlightWarmAmount = v }
        if let v = params["luminanceNoise"]      as? Float { ccdParams.luminanceNoise      = v }
        if let v = params["chromaNoise"]         as? Float { ccdParams.chromaNoise         = v }

        // ── Inst C / SQC 拍立得专属参数（其他相机也可复用）──────────────────────────────────────────────────────
        if let v = params["highlightRolloff"]   as? Float { ccdParams.highlightRolloff   = v }
        if let v = params["paperTexture"]        as? Float { ccdParams.paperTexture        = v }
        if let v = params["edgeFalloff"]         as? Float { ccdParams.edgeFalloff         = v }
        if let v = params["exposureVariation"]   as? Float { ccdParams.exposureVariation   = v }
        if let v = params["cornerWarmShift"]     as? Float { ccdParams.cornerWarmShift     = v }

        // ── 拍立得/数码通用参数（Inst C / SQC / FXN-R 共用）──────────────────────────────────────────────────────
        if let v = params["centerGain"]          as? Float { ccdParams.centerGain          = v }
        if let v = params["developmentSoftness"] as? Float { ccdParams.developmentSoftness = v }
        if let v = params["chemicalIrregularity"] as? Float { ccdParams.chemicalIrregularity = v }
        if let v = params["skinHueProtect"]      as? Float { ccdParams.skinHueProtect      = v }
        if let v = params["skinSatProtect"]      as? Float { ccdParams.skinSatProtect      = v }
        if let v = params["skinLumaSoften"]      as? Float { ccdParams.skinLumaSoften      = v }
        if let v = params["skinRedLimit"]        as? Float { ccdParams.skinRedLimit        = v }

        // ── FIX: Lightroom 风格曲线参数 ─────────────────────────────────────────────────────────────────
        if let v = params["highlights"]  as? Float { ccdParams.highlights  = v }
        if let v = params["shadows"]     as? Float { ccdParams.shadows     = v }
        if let v = params["whites"]      as? Float { ccdParams.whites      = v }
        if let v = params["blacks"]      as? Float { ccdParams.blacks      = v }
        if let v = params["clarity"]     as? Float { ccdParams.clarity     = v }
        if let v = params["vibrance"]    as? Float { ccdParams.vibrance    = v }
        // FIX: noiseAmount（兼容 noise 和 noiseAmount 两种键名）
        if let v = params["noise"]       as? Float { ccdParams.noiseAmount = v }
        if let v = params["noiseAmount"] as? Float { ccdParams.noiseAmount = v }

        // ── 纹理加载 ─────────────────────────────────────────────────────────────────
        if let lutAsset = params["lut"] as? String, !lutAsset.isEmpty {
            loadAssetTexture(assetPath: lutAsset) { [weak self] texture in
                self?.lutTexture = texture
            }
        }
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
        // 原子读取当前 Pipeline（可能在 rebuildPipeline 后被替换）
        pipelineLock.lock()
        guard let pipelineState = renderPipelineState else {
            pipelineLock.unlock()
            return
        }
        pipelineLock.unlock()

        guard let cache = textureCache,
              let vBuffer = vertexBuffer else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        // 每帧自动同步宽高比（为鱼眼模式提供正确的圆形比例）
        updateAspectRatio(width: width, height: height)

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
        if let lut = lutTexture     { encoder.setFragmentTexture(lut,   index: 1) }
        if let grain = grainTexture { encoder.setFragmentTexture(grain, index: 2) }

        paramsLock.lock()
        ccdParams.time += 0.016
        var params = ccdParams
        paramsLock.unlock()

        encoder.setFragmentBytes(&params, length: MemoryLayout<CCDParams>.size, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        // 性能优化：改用 addCompletedHandler 异步回调，不再阻塞 AVFoundation 采集线程
        // 原来的 waitUntilCompleted() 会在 captureOutput 回调线程上同步等待 GPU，
        // 导致相机帧队列积压，实测帧率从 ~28fps 提升到稳定 30fps
        let capturedTextureId = textureId
        let capturedRegistry = registry
        inflightSemaphore.wait() // 限制飞行中的 CommandBuffer 数量
        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let self = self else { return }
            self.inflightSemaphore.signal()
            self.pixelBufferLock.lock()
            self.currentPixelBuffer = outBuffer
            self.pixelBufferLock.unlock()
            if capturedTextureId != -1 {
                capturedRegistry.textureFrameAvailable(capturedTextureId)
            }
        }
        commandBuffer.commit()
        // 不再调用 waitUntilCompleted()，立即返回，让 AVFoundation 继续投递下一帧
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

    // MARK: - Sharpen Control

    /// 设置锐化强度（由 setSharpen method channel 调用）
    /// level: 0.0=低, 0.5=中, 1.0=高
    func setSharpen(_ level: Float) {
        paramsLock.lock()
        ccdParams.sharpen = level
        paramsLock.unlock()
    }

    // MARK: - Fisheye Mode Control
    /// 圆形鱼眼模式（由 updateLensParams method channel 调用）
    func setFisheyeMode(_ enabled: Bool) {
        paramsLock.lock()
        ccdParams.fisheyeMode = enabled ? 1.0 : 0.0
        paramsLock.unlock()
    }

    /// 更新宽高比（每帧渲染时自动设置）
    func updateAspectRatio(width: Int, height: Int) {
        guard height > 0 else { return }
        paramsLock.lock()
        ccdParams.aspectRatio = Float(width) / Float(height)
        paramsLock.unlock()
    }

    func getCCDParams() -> CCDParams {
        paramsLock.lock()
        defer { paramsLock.unlock() }
        return ccdParams
    }

    func setCCDParams(_ params: CCDParams) {
        paramsLock.lock()
        ccdParams = params
        paramsLock.unlock()
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
