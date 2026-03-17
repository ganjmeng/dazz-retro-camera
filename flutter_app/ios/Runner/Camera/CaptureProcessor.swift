import Foundation
import Metal
import MetalKit
import CoreGraphics
import UIKit

// ── Metal 侧的参数结构体，必须与 CapturePipeline.metal 中的 CaptureParams 完全一致 ──
struct MetalCaptureParams {
    var cameraId: Int32 = 0
    var time: Float = 0
    var aspectRatio: Float = 1.0

    // 基础色彩参数
    var contrast: Float = 1.0
    var saturation: Float = 1.0
    var temperatureShift: Float = 0
    var tintShift: Float = 0

    // Lightroom 风格曲线参数
    var highlights: Float = 0
    var shadows: Float = 0
    var whites: Float = 0
    var blacks: Float = 0
    var clarity: Float = 0
    var vibrance: Float = 0

    // RGB 通道偏移
    var colorBiasR: Float = 0
    var colorBiasG: Float = 0
    var colorBiasB: Float = 0

    // 胶片效果参数
    var grainAmount: Float = 0
    var noiseAmount: Float = 0
    var vignetteAmount: Float = 0
    var chromaticAberration: Float = 0
    var bloomAmount: Float = 0
    var halationAmount: Float = 0
    var sharpen: Float = 0
    var blurRadius: Float = 0
    var jpegArtifacts: Float = 0
    var fisheyeMode: Float = 0
    var grainSize: Float = 1.0
    var sharpness: Float = 1.0
    var highlightWarmAmount: Float = 0
    var luminanceNoise: Float = 0
    var chromaNoise: Float = 0

    // 成片专属参数（预览中被 SIMPLIFIED 的效果）
    var highlightRolloff: Float = 0
    var highlightRolloff2: Float = 0   // 高光柔和滚落 2（FXN-R 专属）
    var toneCurveStrength: Float = 0   // Tone Curve 强度（FXN-R 专属）
    var paperTexture: Float = 0
    var edgeFalloff: Float = 0
    var exposureVariation: Float = 0
    var cornerWarmShift: Float = 0
    var centerGain: Float = 0
    var developmentSoftness: Float = 0
    var chemicalIrregularity: Float = 0
    var skinHueProtect: Float = 0
    var skinSatProtect: Float = 1.0
    var skinLumaSoften: Float = 0
    var skinRedLimit: Float = 1.0
}

/**
 * iOS 成片 GPU 处理器
 *
 * 使用 Metal Compute Shader 在 GPU 上执行完整的成片管线，对应 Android 的 CaptureProcessor.kt。
 * 在 Dart 层的 capture_pipeline.dart 调用 processWithGpu 时触发。
 */
class CaptureProcessor {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLComputePipelineState
    private let textureLoader: MTKTextureLoader

    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("[CaptureProcessor] Metal not available on this device")
            return nil
        }
        guard let commandQueue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = commandQueue
        self.textureLoader = MTKTextureLoader(device: device)

        // 加载 CapturePipeline.metal 中的 capturePipeline 内核函数
        guard let library = device.makeDefaultLibrary(),
              let kernel = library.makeFunction(name: "capturePipeline") else {
            print("[CaptureProcessor] Failed to find 'capturePipeline' kernel in Metal library")
            return nil
        }
        guard let pipelineState = try? device.makeComputePipelineState(function: kernel) else {
            return nil
        }
        self.pipelineState = pipelineState
        print("[CaptureProcessor] Metal Compute Pipeline initialized successfully")
    }

    /**
     * 处理图像文件，返回处理后的临时文件路径
     *
     * @param filePath 原始 JPEG 文件路径
     * @param params   来自 Dart 层的参数字典（PreviewRenderParams.toJson()）
     * @return 处理后的 JPEG 文件路径，失败时返回 nil
     */
    func processImage(filePath: String, params: [String: Any]) -> String? {
        guard let image = UIImage(contentsOfFile: filePath),
              let cgImage = image.cgImage else {
            print("[CaptureProcessor] Failed to load image: \(filePath)")
            return nil
        }

        // 1. 将图像加载为 Metal 纹理
        let textureOptions: [MTKTextureLoader.Option: Any] = [
            .textureUsage: MTLTextureUsage([.shaderRead, .shaderWrite]).rawValue,
            .textureStorageMode: MTLStorageMode.shared.rawValue,
            .SRGB: false
        ]
        guard let inTexture = try? textureLoader.newTexture(cgImage: cgImage, options: textureOptions) else {
            print("[CaptureProcessor] Failed to create input texture")
            return nil
        }

        // 2. 创建输出纹理
        let outDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: inTexture.width,
            height: inTexture.height,
            mipmapped: false)
        outDescriptor.usage = [.shaderRead, .shaderWrite]
        outDescriptor.storageMode = .shared
        guard let outTexture = device.makeTexture(descriptor: outDescriptor) else {
            print("[CaptureProcessor] Failed to create output texture")
            return nil
        }

        // 3. 构建参数结构体
        var captureParams = buildCaptureParams(params: params,
                                               width: inTexture.width,
                                               height: inTexture.height)

        // 4. 编码 Compute 命令
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(inTexture, index: 0)
        encoder.setTexture(outTexture, index: 1)
        encoder.setBytes(&captureParams, length: MemoryLayout<MetalCaptureParams>.size, index: 0)

        // 5. 计算线程组大小（16×16 是 Metal 的最优线程组大小）
        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroupCount = MTLSize(
            width: (inTexture.width  + threadgroupSize.width  - 1) / threadgroupSize.width,
            height: (inTexture.height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1)
        encoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()

        // 6. 提交并等待完成
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            print("[CaptureProcessor] Metal command buffer error: \(error)")
            return nil
        }

        // 7. 从输出纹理读取像素并编码为 JPEG
        guard let resultImage = imageFromTexture(texture: outTexture) else { return nil }

        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gpu_\(UUID().uuidString).jpg")

        guard let jpegData = resultImage.jpegData(compressionQuality: 0.92) else { return nil }
        do {
            try jpegData.write(to: outputURL)
        } catch {
            print("[CaptureProcessor] Failed to write output JPEG: \(error)")
            return nil
        }

        print("[CaptureProcessor] GPU processing complete: \(outputURL.path)")
        return outputURL.path
    }

    // ── 参数映射 ────────────────────────────────────────────────────────────

    private func buildCaptureParams(params: [String: Any], width: Int, height: Int) -> MetalCaptureParams {
        var p = MetalCaptureParams()

        p.time = Float(Date().timeIntervalSince1970)
        p.aspectRatio = Float(width) / Float(height)

        // 相机 ID 映射
        let cameraId = params["cameraId"] as? String ?? ""
        p.cameraId = mapCameraId(cameraId)

        // 基础色彩参数
        p.contrast           = getFloat(params, "contrast", 1.0)
        p.saturation         = getFloat(params, "saturation", 1.0)
        p.temperatureShift   = getFloat(params, "temperatureShift", 0)
        p.tintShift          = getFloat(params, "tintShift", 0)

        // Lightroom 风格曲线参数
        p.highlights         = getFloat(params, "highlights", 0)
        p.shadows            = getFloat(params, "shadows", 0)
        p.whites             = getFloat(params, "whites", 0)
        p.blacks             = getFloat(params, "blacks", 0)
        p.clarity            = getFloat(params, "clarity", 0)
        p.vibrance           = getFloat(params, "vibrance", 0)

        // RGB 通道偏移
        p.colorBiasR         = getFloat(params, "colorBiasR", 0)
        p.colorBiasG         = getFloat(params, "colorBiasG", 0)
        p.colorBiasB         = getFloat(params, "colorBiasB", 0)

        // 胶片效果参数
        p.grainAmount        = getFloat(params, "grainAmount", 0)
        p.noiseAmount        = getFloat(params, "noiseAmount", 0)
        p.vignetteAmount     = getFloat(params, "vignetteAmount", 0)
        p.chromaticAberration = getFloat(params, "chromaticAberration", 0)
        p.bloomAmount        = getFloat(params, "bloomAmount", 0)
        p.halationAmount     = getFloat(params, "halationAmount", 0)
        p.grainSize          = getFloat(params, "grainSize", 1.0)
        p.sharpness          = getFloat(params, "sharpness", 1.0)

        // 成片专属参数
        p.highlightRolloff   = getFloat(params, "highlightRolloff", 0)
        p.highlightRolloff2  = getFloat(params, "highlightRolloff2", 0)
        p.toneCurveStrength  = getFloat(params, "toneCurveStrength", 0)
        p.paperTexture       = getFloat(params, "paperTexture", 0)
        p.edgeFalloff        = getFloat(params, "edgeFalloff", 0)
        p.exposureVariation  = getFloat(params, "exposureVariation", 0)
        p.cornerWarmShift    = getFloat(params, "cornerWarmShift", 0)
        p.centerGain         = getFloat(params, "centerGain", 0)
        p.developmentSoftness = getFloat(params, "developmentSoftness", 0)
        p.chemicalIrregularity = getFloat(params, "chemicalIrregularity", 0)
        p.skinHueProtect     = getFloat(params, "skinHueProtect", 0)
        p.skinSatProtect     = getFloat(params, "skinSatProtect", 1.0)
        p.skinLumaSoften     = getFloat(params, "skinLumaSoften", 0)
        p.skinRedLimit       = getFloat(params, "skinRedLimit", 1.0)

        return p
    }

    private func mapCameraId(_ id: String) -> Int32 {
        switch id {
        case "inst_c", "inst_s": return 0
        case "sqc", "inst_sq":   return 1
        case "fqs":              return 2
        case "cpm35":            return 3
        case "grd_r":            return 4
        case "bw_classic":       return 5
        case "u300":             return 6
        case "ccd_r", "ccd_m":  return 7
        case "fxn_r":            return 8
        case "d_classic":        return 9
        default:                 return 0
        }
    }

    private func getFloat(_ params: [String: Any], _ key: String, _ defaultVal: Float) -> Float {
        if let v = params[key] as? Double { return Float(v) }
        if let v = params[key] as? Float  { return v }
        if let v = params[key] as? Int    { return Float(v) }
        return defaultVal
    }

    // ── 从 Metal 纹理读取像素并转换为 UIImage ──────────────────────────────

    private func imageFromTexture(texture: MTLTexture) -> UIImage? {
        let width = texture.width
        let height = texture.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let byteCount = bytesPerRow * height

        var bytes = [UInt8](repeating: 0, count: byteCount)
        texture.getBytes(&bytes,
                         bytesPerRow: bytesPerRow,
                         from: MTLRegionMake2D(0, 0, width, height),
                         mipmapLevel: 0)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context = CGContext(data: &bytes,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: bitmapInfo.rawValue),
              let cgImage = context.makeImage() else { return nil }

        return UIImage(cgImage: cgImage)
    }
}
