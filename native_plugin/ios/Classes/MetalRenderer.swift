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
    
    init(registry: FlutterTextureRegistry) {
        self.registry = registry
        self.device = MTLCreateSystemDefaultDevice()
        self.commandQueue = device?.makeCommandQueue()
        self.textureId = -1
        
        if let device = device {
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        }
        
        super.init()
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
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        // TODO: Apply Metal Shader here
        // For MVP, we just pass through the raw camera frame
        
        self.currentPixelBuffer = pixelBuffer
        
        // Notify Flutter that a new frame is ready
        if textureId != -1 {
            registry.textureFrameAvailable(textureId)
        }
    }
}
