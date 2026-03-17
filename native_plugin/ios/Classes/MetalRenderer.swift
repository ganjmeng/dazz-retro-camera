import Foundation
import Metal
import CoreVideo
import Flutter
import AVFoundation

class MetalRenderer: NSObject, FlutterTexture, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    private(set) var textureId: Int64
    private let registry: FlutterTextureRegistry
    private var currentPixelBuffer: CVPixelBuffer?
    
    // Metal properties
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var textureCache: CVMetalTextureCache?
    
    // Rendering pipeline
    private var renderPipelineState: MTLRenderPipelineState?
    private var renderPassDescriptor: MTLRenderPassDescriptor?
    private var outputPixelBufferPool: CVPixelBufferPool?
    
    // Current parameters
    private var ccdParams = CCDParams()
    
    // External textures
    private var lutTexture: MTLTexture?
    private var grainTexture: MTLTexture?
    private var frameTexture: MTLTexture?
    
    init(registry: FlutterTextureRegistry) {
        self.registry = registry
        self.device = MTLCreateSystemDefaultDevice()
        self.commandQueue = device?.makeCommandQueue()
        self.textureId = -1
        
        if let device = device {
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
            setupMetalPipeline(device: device)
        }
        
        super.init()
    }
    
    private func setupMetalPipeline(device: MTLDevice) {
        guard let library = device.makeDefaultLibrary() else { return }
        
        let vertexFunction = library.makeFunction(name: "vertexShader")
        let fragmentFunction = library.makeFunction(name: "ccdFragmentShader")
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        
        do {
            renderPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print("Failed to create pipeline state: \(error)")
        }
        
        // Initialize default parameters
        // ── 基础色彩
        ccdParams.contrast          = 1.0
        ccdParams.saturation        = 1.0
        ccdParams.temperatureShift  = 0.0
        ccdParams.tintShift         = 0.0
        ccdParams.exposureOffset    = 0.0
        // ── Lightroom 风格曲线
        ccdParams.highlights        = 0.0
        ccdParams.shadows           = 0.0
        ccdParams.whites            = 0.0
        ccdParams.blacks            = 0.0
        ccdParams.clarity           = 0.0
        ccdParams.vibrance          = 0.0
        // ── RGB 通道偏移
        ccdParams.colorBiasR        = 0.0
        ccdParams.colorBiasG        = 0.0
        ccdParams.colorBiasB        = 0.0
        // ── 胶片效果
        ccdParams.grainAmount       = 0.0
        ccdParams.noiseAmount       = 0.0
        ccdParams.vignetteAmount    = 0.0
        ccdParams.chromaticAberration = 0.0
        ccdParams.bloomAmount       = 0.0
        ccdParams.halationAmount    = 0.0
        ccdParams.sharen            = 0.0
        ccdParams.blurRadius        = 0.0
        ccdParams.jpegArtifacts     = 0.0
        ccdParams.time              = 0.0
        ccdParams.distortion        = 0.0  // 镜头畸变默认无畸变
    }
    
    func updateParams(_ params: [String: Any]) {
        // Flutter MethodChannel 传来的 Dart double 在 iOS 侧是 NSNumber(Double)
        // 必须用 (as? NSNumber)?.floatValue 而不是 as? Float，否则类型转换静默失败
        func f(_ key: String) -> Float? { (params[key] as? NSNumber)?.floatValue }

        // ── 基础色彩 ─────────────────────────────────────────────
        if let v = f("contrast")         { ccdParams.contrast         = v }
        if let v = f("saturation")       { ccdParams.saturation       = v }
        if let v = f("temperatureShift") { ccdParams.temperatureShift = v }
        if let v = f("exposureOffset")   { ccdParams.exposureOffset   = v }
        if let v = f("tintShift")        { ccdParams.tintShift        = v }
        // ── Lightroom 风格曲线 ──────────────────────────────────────
        if let v = f("highlights")  { ccdParams.highlights  = v }
        if let v = f("shadows")     { ccdParams.shadows     = v }
        if let v = f("whites")      { ccdParams.whites      = v }
        if let v = f("blacks")      { ccdParams.blacks      = v }
        if let v = f("clarity")     { ccdParams.clarity     = v }
        if let v = f("vibrance")    { ccdParams.vibrance    = v }
        // ── RGB 通道偏移（toJson 输出平铺键 colorBiasR/G/B）────────
        if let v = f("colorBiasR")  { ccdParams.colorBiasR = v }
        if let v = f("colorBiasG")  { ccdParams.colorBiasG = v }
        if let v = f("colorBiasB")  { ccdParams.colorBiasB = v }
        // 兼容旧版嵌套字典格式 colorBias: {r, g, b}
        if let cb = params["colorBias"] as? [String: Any] {
            if let r = (cb["r"] as? NSNumber)?.floatValue { ccdParams.colorBiasR = r }
            if let g = (cb["g"] as? NSNumber)?.floatValue { ccdParams.colorBiasG = g }
            if let b = (cb["b"] as? NSNumber)?.floatValue { ccdParams.colorBiasB = b }
        }
        // ── 胶片效果 ──────────────────────────────────────────────────
        if let v = f("chromaticAberration") { ccdParams.chromaticAberration = v }
        if let v = f("noiseAmount")         { ccdParams.noiseAmount         = v }
        if let v = f("noise")               { ccdParams.noiseAmount         = v }  // 兼容旧键名
        if let v = f("vignetteAmount")      { ccdParams.vignetteAmount      = v }
        if let v = f("vignette")            { ccdParams.vignetteAmount      = v }  // 兼容旧键名
        if let v = f("bloomAmount")         { ccdParams.bloomAmount         = v }
        if let v = f("bloom")               { ccdParams.bloomAmount         = v }  // 兼容旧键名
        if let v = f("grainAmount")         { ccdParams.grainAmount         = v }
        if let v = f("grain")               { ccdParams.grainAmount         = v }  // 兼容旧键名
        if let v = f("halationAmount")      { ccdParams.halationAmount      = v }
        if let v = f("lensVignette")        { ccdParams.lensVignette        = v }
        if let v = f("softFocus")           { ccdParams.blurRadius          = v }
        // 镜头畸变：Brown-Conrady k1 系数，负值=桶形(鱼眼), 正值=枕形
        if let v = f("distortion")          { ccdParams.distortion          = v }
        
        // In a real implementation, we would load the textures from Flutter assets here
        // using FlutterPluginRegistrar.lookupKey(forAsset:) and MTKTextureLoader
        if let lutPath = params["lut"] as? String {
            print("Metal: Should load LUT from \(lutPath)")
            // loadTexture(assetPath: lutPath, target: &lutTexture)
        }
        if let grainPath = params["grain"] as? String {
            print("Metal: Should load Grain from \(grainPath)")
            // loadTexture(assetPath: grainPath, target: &grainTexture)
        }
        if let framePath = params["frame"] as? String {
            print("Metal: Should load Frame from \(framePath)")
            // loadTexture(assetPath: framePath, target: &frameTexture)
        } else {
            frameTexture = nil
        }
    }
    
    func setTextureId(_ id: Int64) {
        self.textureId = id
    }
    
    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        guard let pixelBuffer = currentPixelBuffer else { return nil }
        return Unmanaged.passRetained(pixelBuffer)
    }
    
    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let device = device,
              let commandQueue = commandQueue,
              let textureCache = textureCache,
              let pipelineState = renderPipelineState else { return }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        // Create output pixel buffer pool if needed
        if outputPixelBufferPool == nil {
            let poolAttributes: [String: Any] = [
                kCVPixelBufferPoolMinimumBufferCountKey as String: 3
            ]
            let pixelBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as CFDictionary, pixelBufferAttributes as CFDictionary, &outputPixelBufferPool)
        }
        
        guard let pool = outputPixelBufferPool else { return }
        var outputPixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outputPixelBuffer)
        guard let outBuffer = outputPixelBuffer else { return }
        
        // Create Metal textures from pixel buffers
        var cvTextureIn: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTextureIn)
        guard let textureIn = CVMetalTextureGetTexture(cvTextureIn!) else { return }
        
        var cvTextureOut: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, outBuffer, nil, .bgra8Unorm, width, height, 0, &cvTextureOut)
        guard let textureOut = CVMetalTextureGetTexture(cvTextureOut!) else { return }
        
        // Render pass
        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = textureOut
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        passDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }
        
        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setFragmentTexture(textureIn, index: 0)
        
        // Bind external textures if available
        if let lut = lutTexture { renderEncoder.setFragmentTexture(lut, index: 1) }
        if let grain = grainTexture { renderEncoder.setFragmentTexture(grain, index: 2) }
        if let frame = frameTexture { renderEncoder.setFragmentTexture(frame, index: 3) }
        
        // Update time for dynamic noise
        ccdParams.time += 0.016 // roughly 60fps
        renderEncoder.setFragmentBytes(&ccdParams, length: MemoryLayout<CCDParams>.size, index: 0)
        
        // Draw full screen quad
        // In a real implementation we would bind a vertex buffer.
        // For simplicity in this skeleton, we assume the vertex shader generates the quad.
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        self.currentPixelBuffer = outBuffer
        
        // Notify Flutter that a new frame is ready
        if textureId != -1 {
            registry.textureFrameAvailable(textureId)
        }
    }
}
