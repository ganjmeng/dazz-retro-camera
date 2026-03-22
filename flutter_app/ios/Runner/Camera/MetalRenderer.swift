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
    // ── LUT + ToneCurve 参数（新增字段，追加到末尾）─────────────────────────────────
    var lutEnabled: Float = 0.0        // 1.0=启用 LUT，0.0=跳过
    var lutSize: Float = 33.0          // LUT 尺寸（通常 33 或 64）
    var lutStrength: Float = 1.0       // LUT 混合强度（0.0~1.0）
    var toneCurveStrength: Float = 0.0 // Tone Curve 强度（0.0~1.0）
    var exposureOffset: Float = 0.0    // 用户曝光补偿（-2.0~+2.0）
    var lensDistortion: Float = 0.0    // 轻量桶形畸变（非圆形鱼眼）
    // ── Device Calibration（V3：设备级线性校准）─────────────────────────────────
    var deviceGamma: Float = 1.0
    var deviceWhiteScaleR: Float = 1.0
    var deviceWhiteScaleG: Float = 1.0
    var deviceWhiteScaleB: Float = 1.0
    var deviceCcm00: Float = 1.0
    var deviceCcm01: Float = 0.0
    var deviceCcm02: Float = 0.0
    var deviceCcm10: Float = 0.0
    var deviceCcm11: Float = 1.0
    var deviceCcm12: Float = 0.0
    var deviceCcm20: Float = 0.0
    var deviceCcm21: Float = 0.0
    var deviceCcm22: Float = 1.0
    var circularFisheye: Float = 0.0
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
    // #2 路径缓存：路径不变时跳过重新加载，消除 EV 滑动时的重复 I/O 和预览闪烁
    private var cachedLutPath: String = ""
    private var cachedGrainPath: String = ""

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

    /// 构建通用 MTLRenderPipelineState
    /// Phase 1 统一重构：所有相机使用通用 CameraShaders.metal
    /// 相机差异完全由 JSON defaultLook 参数驱动
    private func buildPipeline(cameraId: String) {
        guard let library = device.makeDefaultLibrary() else {
            print("[MetalRenderer] Failed to load default Metal library")
            return
        }

        // Phase 1 统一重构：所有相机统一使用通用 CameraShaders.metal
        // 相机差异完全由 JSON defaultLook 参数驱动，不再按相机 ID 选择不同 Shader
        let vertexName   = "vertexShader"
        let fragmentName = "ccdFragmentShader"

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
        func num(_ key: String) -> Float? {
            if let v = params[key] as? Float { return v }
            if let v = params[key] as? Double { return Float(v) }
            if let v = params[key] as? Int { return Float(v) }
            if let v = params[key] as? NSNumber { return v.floatValue }
            if let v = params[key] as? String { return Float(v) }
            return nil
        }
        func boolVal(_ key: String) -> Bool {
            if let v = params[key] as? Bool { return v }
            if let v = params[key] as? NSNumber { return v.intValue != 0 }
            if let v = params[key] as? String { return v == "1" || v.lowercased() == "true" }
            return false
        }
        // 相机 ID 切换不需要持锁，单独处理
        if let camId = params["cameraId"] as? String, !camId.isEmpty {
            currentCameraId = camId   // 触发 didSet → rebuildPipeline()
        }

        paramsLock.lock()
        defer { paramsLock.unlock() }

        // ── 通用参数 ─────────────────────────────────────────────────────────
        if let v = num("contrast") { ccdParams.contrast = v }
        if let v = num("saturation") { ccdParams.saturation = v }
        if let v = num("temperatureShift") { ccdParams.temperatureShift = v }
        if let v = num("tintShift") { ccdParams.tintShift = v }
        if let v = num("grainAmount") { ccdParams.grainAmount = v }
        if let v = num("noise") { ccdParams.noiseAmount = v }
        if let v = num("vignette") { ccdParams.vignetteAmount = v }
        if let v = num("chromaticAberration") { ccdParams.chromaticAberration = v }
        if let v = num("bloom") { ccdParams.bloomAmount = v }
        if let v = num("halation") { ccdParams.halationAmount = v }
        if let v = num("sharpen") { ccdParams.sharpen = v }

        // ── FQS / CPM35 专用参数 ─────────────────────────────────────────────
        if let v = num("colorBiasR") { ccdParams.colorBiasR = v }
        if let v = num("colorBiasG") { ccdParams.colorBiasG = v }
        if let v = num("colorBiasB") { ccdParams.colorBiasB = v }
        if let v = num("grainSize") { ccdParams.grainSize = v }
        if let v = num("sharpness") { ccdParams.sharpness = v }
        if let v = num("highlightWarmAmount") { ccdParams.highlightWarmAmount = v }
        if let v = num("luminanceNoise") { ccdParams.luminanceNoise = v }
        if let v = num("chromaNoise") { ccdParams.chromaNoise = v }

        // ── Inst C / SQC 拍立得专属参数（其他相机也可复用）──────────────────────────────────────────────────────
        if let v = num("highlightRolloff") { ccdParams.highlightRolloff = v }
        if let v = num("paperTexture") { ccdParams.paperTexture = v }
        if let v = num("edgeFalloff") { ccdParams.edgeFalloff = v }
        if let v = num("exposureVariation") { ccdParams.exposureVariation = v }
        if let v = num("cornerWarmShift") { ccdParams.cornerWarmShift = v }

        // ── 拍立得/数码通用参数（Inst C / SQC / FXN-R 共用）──────────────────────────────────────────────────────
        if let v = num("centerGain") { ccdParams.centerGain = v }
        if let v = num("developmentSoftness") { ccdParams.developmentSoftness = v }
        if let v = num("chemicalIrregularity") { ccdParams.chemicalIrregularity = v }
        if let v = num("skinHueProtect") { ccdParams.skinHueProtect = v }
        if let v = num("skinSatProtect") { ccdParams.skinSatProtect = v }
        if let v = num("skinLumaSoften") { ccdParams.skinLumaSoften = v }
        if let v = num("skinRedLimit") { ccdParams.skinRedLimit = v }
        if let v = num("toneCurveStrength") { ccdParams.toneCurveStrength = v }

        // ── FIX: Lightroom 风格曲线参数 ─────────────────────────────────────────────────────────────────
        if let v = num("highlights") { ccdParams.highlights = v }
        if let v = num("shadows") { ccdParams.shadows = v }
        if let v = num("whites") { ccdParams.whites = v }
        if let v = num("blacks") { ccdParams.blacks = v }
        if let v = num("clarity") { ccdParams.clarity = v }
        if let v = num("vibrance") { ccdParams.vibrance = v }
        // FIX: noiseAmount（兼容 noise 和 noiseAmount 两种键名）
        if let v = num("noise") { ccdParams.noiseAmount = v }
        if let v = num("noiseAmount") { ccdParams.noiseAmount = v }
        // 曝光补偿
        if let v = num("exposureOffset") { ccdParams.exposureOffset = v }
        if let v = num("distortion") { ccdParams.lensDistortion = v }
        if let v = num("deviceGamma") { ccdParams.deviceGamma = v }
        if let v = num("deviceWhiteScaleR") { ccdParams.deviceWhiteScaleR = v }
        if let v = num("deviceWhiteScaleG") { ccdParams.deviceWhiteScaleG = v }
        if let v = num("deviceWhiteScaleB") { ccdParams.deviceWhiteScaleB = v }
        if let v = num("deviceCcm00") { ccdParams.deviceCcm00 = v }
        if let v = num("deviceCcm01") { ccdParams.deviceCcm01 = v }
        if let v = num("deviceCcm02") { ccdParams.deviceCcm02 = v }
        if let v = num("deviceCcm10") { ccdParams.deviceCcm10 = v }
        if let v = num("deviceCcm11") { ccdParams.deviceCcm11 = v }
        if let v = num("deviceCcm12") { ccdParams.deviceCcm12 = v }
        if let v = num("deviceCcm20") { ccdParams.deviceCcm20 = v }
        if let v = num("deviceCcm21") { ccdParams.deviceCcm21 = v }
        if let v = num("deviceCcm22") { ccdParams.deviceCcm22 = v }
        if boolVal("previewWhitelist") {
            // 预览白名单：仅保留 LUT + 色温/色调 + 曝光 + 美颜相关参数。
            ccdParams.contrast = 1.0
            ccdParams.saturation = 1.0
            ccdParams.highlights = 0.0
            ccdParams.shadows = 0.0
            ccdParams.whites = 0.0
            ccdParams.blacks = 0.0
            ccdParams.clarity = 0.0
            ccdParams.vibrance = 0.0
            ccdParams.colorBiasR = 0.0
            ccdParams.colorBiasG = 0.0
            ccdParams.colorBiasB = 0.0
            ccdParams.grainAmount = 0.0
            ccdParams.noiseAmount = 0.0
            ccdParams.grainSize = 1.0
            ccdParams.luminanceNoise = 0.0
            ccdParams.chromaNoise = 0.0
            ccdParams.vignetteAmount = 0.0
            ccdParams.chromaticAberration = 0.0
            ccdParams.bloomAmount = 0.0
            ccdParams.halationAmount = 0.0
            ccdParams.highlightRolloff = 0.0
            ccdParams.toneCurveStrength = 0.0
            ccdParams.paperTexture = 0.0
            ccdParams.edgeFalloff = 0.0
            ccdParams.exposureVariation = 0.0
            ccdParams.cornerWarmShift = 0.0
            ccdParams.centerGain = 0.0
            ccdParams.developmentSoftness = 0.0
            ccdParams.chemicalIrregularity = 0.0
        }

        // ── LUT 加载：路径相同但纹理为空时也要重试，避免启动早期加载失败后一直无特效 ──
        if let lutAsset = (params["baseLut"] as? String) ?? (params["lut"] as? String) {
            if !lutAsset.isEmpty {
                let shouldReload = (lutAsset != cachedLutPath) || (lutTexture == nil)
                if shouldReload {
                    loadAssetTexture(assetPath: lutAsset) { [weak self] texture in
                        guard let self else { return }
                        if let texture {
                            self.lutTexture = texture
                            self.cachedLutPath = lutAsset
                        } else {
                            // 保持可重试状态
                            self.lutTexture = nil
                            self.cachedLutPath = ""
                        }
                    }
                }
            } else {
                // lut 键存在但为空字符串：清除 LUT
                cachedLutPath = ""
                lutTexture = nil
            }
        }
        if let grainAsset = params["grain"] as? String, !grainAsset.isEmpty {
            if grainAsset != cachedGrainPath {
                cachedGrainPath = grainAsset
                loadAssetTexture(assetPath: grainAsset) { [weak self] texture in
                    self?.grainTexture = texture
                }
            }
        }

        ccdParams.lutEnabled = lutTexture != nil ? 1.0 : 0.0
        if let v = num("lutStrength") {
            ccdParams.lutStrength = max(0.0, min(1.0, v))
        }
        if let v = num("lutSize") {
            ccdParams.lutSize = max(8.0, min(128.0, v))
        } else {
            ccdParams.lutSize = 33.0
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

    func setCircularFisheye(_ enabled: Bool) {
        paramsLock.lock()
        ccdParams.circularFisheye = enabled ? 1.0 : 0.0
        paramsLock.unlock()
    }

    /// 更新宽高比（每帧渲染时自动设置）
    /// fisheyeUV 中 p.x *= aspect 用于将 UV 空间的横轴压缩到与纵轴等长，从而得到物理像素意义上的正圆。
    /// iOS 相机传感器输出的帧是横向的（如 1920x1080），显示时是竖向的。
    /// 正确的 aspect = min(w,h)/max(w,h)（短边/长边），始终 <= 1.0，压缩横轴使圆形不变形。
    func updateAspectRatio(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        paramsLock.lock()
        let w = Float(width)
        let h = Float(height)
        // FIX: use min/max so aspect is always <= 1.0 regardless of frame orientation.
        // iOS camera frames are landscape (w > h), but displayed portrait.
        // Using w/h directly gives aspect > 1.0 which stretches the circle horizontally.
        ccdParams.aspectRatio = min(w, h) / max(w, h)
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
