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
        ccdParams.contrast = 1.0
        ccdParams.saturation = 1.0
        ccdParams.temperatureShift = 0.0
        ccdParams.tintShift = 0.0
        ccdParams.grainAmount = 0.0
        ccdParams.noiseAmount = 0.0
        ccdParams.vignetteAmount = 0.0
        ccdParams.chromaticAberration = 0.0
        ccdParams.bloomAmount = 0.0
        ccdParams.halationAmount = 0.0
        ccdParams.sharen = 0.0
        ccdParams.blurRadius = 0.0
        ccdParams.jpegArtifacts = 0.0
        ccdParams.time = 0.0
    }
    
    func updateParams(_ params: [String: Any]) {
        // Parse dictionary and update ccdParams
        if let contrast = params["contrast"] as? Float { ccdParams.contrast = contrast }
        if let saturation = params["saturation"] as? Float { ccdParams.saturation = saturation }
        if let ca = params["chromaticAberration"] as? Float { ccdParams.chromaticAberration = ca }
        if let noise = params["noise"] as? Float { ccdParams.noiseAmount = noise }
        if let vignette = params["vignette"] as? Float { ccdParams.vignetteAmount = vignette }
        if let bloom = params["bloom"] as? Float { ccdParams.bloomAmount = bloom }
        
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
