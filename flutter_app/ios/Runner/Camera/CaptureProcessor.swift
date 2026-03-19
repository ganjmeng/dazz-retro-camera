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
    var exposureOffset: Float = 0     // 用户曝光补偿（-2.0~+2.0）
    // LUT 参数（成片 GPU 管线）
    var lutEnabled: Float = 0          // 1.0 = 启用 LUT
    var lutStrength: Float = 1.0       // LUT 混合强度（0.0~1.0）
    var lutSize: Float = 33.0          // LUT 边长（通常 33）
    var lensDistortion: Float = 0      // 轻量桶形畸变（非圆形鱼眼）
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
    // #7 LUT 纹理缓存：同一路径的 LUT 只加载一次，每次拍照节省 50~200ms
    private var lutCache: [String: MTLTexture] = [:]

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
              var cgImage = image.cgImage else {
            print("[CaptureProcessor] Failed to load image: \(filePath)")
            return nil
        }

        // 0. 按 maxDimension 缩放（避免 GPU 处理全像素原图）
        let maxDim = params["maxDimension"] as? Int ?? 4096
        let srcMax = max(cgImage.width, cgImage.height)
        if srcMax > maxDim {
            let scale = CGFloat(maxDim) / CGFloat(srcMax)
            let newW = Int((CGFloat(cgImage.width) * scale).rounded())
            let newH = Int((CGFloat(cgImage.height) * scale).rounded())
            let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            if let ctx = CGContext(data: nil, width: newW, height: newH,
                                   bitsPerComponent: 8, bytesPerRow: 0,
                                   space: colorSpace, bitmapInfo: bitmapInfo.rawValue) {
                ctx.interpolationQuality = .high
                ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: newW, height: newH))
                if let scaled = ctx.makeImage() {
                    cgImage = scaled
                    print("[CaptureProcessor] Scaled \(srcMax)px → \(maxDim)px (\(newW)x\(newH))")
                }
            }
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

        // 4. 加载 LUT 纹理（#7 缓存：相同路径只加载一次）
        var lutTexture: MTLTexture? = nil
        if let baseLutPath = params["baseLut"] as? String, !baseLutPath.isEmpty {
            if let cached = lutCache[baseLutPath] {
                lutTexture = cached
            } else {
                lutTexture = loadLutTexture(assetPath: baseLutPath)
                if let tex = lutTexture { lutCache[baseLutPath] = tex }
            }
            if lutTexture != nil {
                captureParams.lutEnabled = 1.0
                captureParams.lutStrength = getFloat(params, "lutStrength", 1.0)
                captureParams.lutSize = 33.0
            } else {
                print("[CaptureProcessor] LUT not found: \(baseLutPath), skipping LUT pass")
            }
        }

        // 5. 编码 Compute 命令
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(inTexture, index: 0)
        encoder.setTexture(outTexture, index: 1)
        encoder.setBytes(&captureParams, length: MemoryLayout<MetalCaptureParams>.size, index: 0)
        // LUT 纹理绑定到 index 2（无 LUT 时不传， shader 通过 lutEnabled 判断）
        if let lut = lutTexture {
            encoder.setTexture(lut, index: 2)
        }

        // 6. 计算线程组大小（16×16 是 Metal 的最优线程组大小）
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
        p.exposureOffset     = getFloat(params, "exposureOffset", 0)
        p.fisheyeMode        = getFloat(params, "fisheyeMode", 0)
        p.lensDistortion     = getFloat(params, "distortion", 0)

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

    // ── 加载 .cube LUT 文件为 Metal 2D 纹理（与预览 MetalRenderer 的 loadAssetTexture 逻辑一致）──
    private func loadLutTexture(assetPath: String) -> MTLTexture? {
        // assetPath 格式如 "assets/lut/cameras/inst_c.cube"
        // 在 Flutter app bundle 中对应 Frameworks/App.framework/flutter_assets/
        let bundlePath = Bundle.main.bundlePath
        let flutterAssetsPath = bundlePath + "/Frameworks/App.framework/flutter_assets/" + assetPath
        guard FileManager.default.fileExists(atPath: flutterAssetsPath) else {
            print("[CaptureProcessor] LUT file not found at: \(flutterAssetsPath)")
            return nil
        }
        guard let content = try? String(contentsOfFile: flutterAssetsPath, encoding: .utf8) else {
            return nil
        }
        // 解析 .cube 文件
        var lutSize = 33
        var dataValues: [Float] = []
        dataValues.reserveCapacity(33 * 33 * 33 * 3)
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || trimmed.isEmpty { continue }
            if trimmed.hasPrefix("LUT_3D_SIZE") {
                if let sizeStr = trimmed.components(separatedBy: .whitespaces).last,
                   let size = Int(sizeStr) {
                    lutSize = size
                }
                continue
            }
            if trimmed.hasPrefix("TITLE") || trimmed.hasPrefix("DOMAIN") { continue }
            let parts = trimmed.components(separatedBy: .whitespaces)
            if parts.count == 3,
               let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]) {
                dataValues.append(r)
                dataValues.append(g)
                dataValues.append(b)
            }
        }
        let expectedCount = lutSize * lutSize * lutSize
        guard dataValues.count == expectedCount * 3 else {
            print("[CaptureProcessor] LUT data count mismatch: \(dataValues.count/3) vs \(expectedCount)")
            return nil
        }
        // 将 3D LUT 转换为 2D 纹理（宽 = N*N，高 = N）
        let texW = lutSize * lutSize
        let texH = lutSize
        var rgba: [UInt8] = [UInt8](repeating: 255, count: texW * texH * 4)
        for i in 0..<(lutSize * lutSize * lutSize) {
            let r = UInt8(min(max(dataValues[i * 3 + 0] * 255.0, 0), 255))
            let g = UInt8(min(max(dataValues[i * 3 + 1] * 255.0, 0), 255))
            let b = UInt8(min(max(dataValues[i * 3 + 2] * 255.0, 0), 255))
            rgba[i * 4 + 0] = r
            rgba[i * 4 + 1] = g
            rgba[i * 4 + 2] = b
            rgba[i * 4 + 3] = 255
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: texW,
            height: texH,
            mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, texW, texH),
                        mipmapLevel: 0,
                        withBytes: &rgba,
                        bytesPerRow: texW * 4)
        print("[CaptureProcessor] LUT loaded: \(assetPath) (\(lutSize)^3)")
        return texture
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
