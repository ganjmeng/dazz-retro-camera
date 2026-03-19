import AVFoundation
import UIKit

/// 管理 AVCaptureSession 的生命周期和配置
class CameraSessionManager: NSObject {

    // MARK: - Properties
    private let session = AVCaptureSession()
    private var currentVideoInput: AVCaptureDeviceInput?
    private var videoDataOutput: AVCaptureVideoDataOutput?
    private var photoOutput: AVCapturePhotoOutput?

    private let sessionQueue = DispatchQueue(label: "com.retrocam.session_queue")

    weak var sampleBufferDelegate: AVCaptureVideoDataOutputSampleBufferDelegate?

    // 拍照回调
    private var photoCaptureCallback: ((Data?) -> Void)?

    // MARK: - Setup

    /// 配置并启动相机会话
    /// 默认使用 .photo preset，保证 photoOutput 能输出设备全像素分辨率。
    /// initCamera 完成后 Flutter 端会立即调用 setSharpen 切换到用户选择的档位。
    func configure(lens: AVCaptureDevice.Position = .back, resolution: AVCaptureSession.Preset = .photo) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            self.session.beginConfiguration()
            self.session.sessionPreset = resolution

            // 配置视频输入
            if let device = self.captureDevice(for: lens),
               let input = try? AVCaptureDeviceInput(device: device) {
                if self.session.canAddInput(input) {
                    self.session.addInput(input)
                    self.currentVideoInput = input
                }
            }

            // 配置视频数据输出（用于实时预览渲染）
            let videoOutput = AVCaptureVideoDataOutput()
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self.sampleBufferDelegate, queue: self.sessionQueue)

            if self.session.canAddOutput(videoOutput) {
                self.session.addOutput(videoOutput)
                self.videoDataOutput = videoOutput
            }

            // 配置照片输出（用于高分辨率拍照）
            let photoOutput = AVCapturePhotoOutput()
            // isHighResolutionCaptureEnabled is deprecated in iOS 16+.
            // On iOS 16+ we set maxPhotoDimensions in capturePhoto() instead.
            // Keep this for iOS 15 compatibility.
            if #available(iOS 16.0, *) {
                // iOS 16+: maxPhotoDimensions is set per-capture in capturePhoto()
            } else {
                photoOutput.isHighResolutionCaptureEnabled = true
            }
            if self.session.canAddOutput(photoOutput) {
                self.session.addOutput(photoOutput)
                self.photoOutput = photoOutput
            }

            self.session.commitConfiguration()
        }
    }

    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self = self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self = self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    /// 切换前后置摄像头
    func switchCamera(to position: AVCaptureDevice.Position) {
        sessionQueue.async { [weak self] in
            guard let self = self,
                  let device = self.captureDevice(for: position),
                  let newInput = try? AVCaptureDeviceInput(device: device) else { return }

            self.session.beginConfiguration()
            if let currentInput = self.currentVideoInput {
                self.session.removeInput(currentInput)
            }
            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
                self.currentVideoInput = newInput
            }
            self.session.commitConfiguration()
        }
    }

    // MARK: - Zoom

    /// 设置缩放倍率（与 Android CameraX setZoomRatio 对等）
    func setZoom(factor: CGFloat) {
        guard let device = currentVideoInput?.device else { return }
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                let minZoom = device.minAvailableVideoZoomFactor
                let maxZoom = min(device.maxAvailableVideoZoomFactor, 10.0)
                device.videoZoomFactor = max(minZoom, min(maxZoom, factor))
                device.unlockForConfiguration()
            } catch {
                print("[CameraSessionManager] setZoom error: \(error)")
            }
        }
    }

    // MARK: - Exposure

    /// 设置曝光补偿（EV），范围通常 -2.0 ~ +2.0
    /// 与 Android CameraX setExposureCompensationIndex 对等
    func setExposure(bias: Float) {
        guard let device = currentVideoInput?.device else { return }
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                let minBias = device.minExposureTargetBias
                let maxBias = device.maxExposureTargetBias
                let clampedBias = max(minBias, min(maxBias, bias))
                device.setExposureTargetBias(clampedBias, completionHandler: nil)
                device.unlockForConfiguration()
            } catch {
                print("[CameraSessionManager] setExposure error: \(error)")
            }
        }
    }

    // MARK: - Focus & Exposure Point

    /// 点击对焦 + 对焦点曝光（与 Android CameraX FocusMeteringAction 对等）
    /// x, y: 归一化坐标 [0, 1]，原点在左上角
    func setFocusAndExposure(x: CGFloat, y: CGFloat) {
        guard let device = currentVideoInput?.device else { return }
        // AVCaptureDevice 的 focusPointOfInterest 坐标系与屏幕一致：(0,0)=左上, (1,1)=右下
        let point = CGPoint(x: x, y: y)
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                // 对焦
                if device.isFocusPointOfInterestSupported &&
                   device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = point
                    device.focusMode = .autoFocus
                }
                // 曝光
                if device.isExposurePointOfInterestSupported &&
                   device.isExposureModeSupported(.autoExpose) {
                    device.exposurePointOfInterest = point
                    device.exposureMode = .autoExpose
                }
                device.unlockForConfiguration()
            } catch {
                print("[CameraSessionManager] setFocusAndExposure error: \(error)")
            }
        }
    }

    // MARK: - White Balance

    /// 手动夹紧白平衡增益值到设备支持的范围 [1.0, maxWhiteBalanceGain]
    /// 替代 Objective-C 的 clampedWhiteBalanceGains()，兼容 Xcode 16 / iOS 18 SDK
    private func clampGains(_ gains: AVCaptureDevice.WhiteBalanceGains,
                            for device: AVCaptureDevice) -> AVCaptureDevice.WhiteBalanceGains {
        var g = gains
        let maxGain = device.maxWhiteBalanceGain
        g.redGain   = max(1.0, min(maxGain, g.redGain))
        g.greenGain = max(1.0, min(maxGain, g.greenGain))
        g.blueGain  = max(1.0, min(maxGain, g.blueGain))
        return g
    }

    /// 设置白平衡模式（与 Android CameraX AWB 对等）
    /// mode: "auto" | "daylight" | "incandescent" | "fluorescent" | "cloudy" | "manual"
    /// tempK: 手动模式下的色温开尔文度（1800..8000）
    func setWhiteBalance(mode: String, tempK: Int) {
        guard let device = currentVideoInput?.device else { return }
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                try device.lockForConfiguration()
                switch mode {
                case "auto":
                    if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                        device.whiteBalanceMode = .continuousAutoWhiteBalance
                    }
                case "daylight", "cloudy":
                    // 日光 ≈ 5500K，多云 ≈ 6500K
                    let targetK: Float = (mode == "cloudy") ? 6500 : 5500
                    if device.isWhiteBalanceModeSupported(.locked) {
                        let gains = device.deviceWhiteBalanceGains(for:
                            AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                                temperature: targetK, tint: 0))
                        let clamped = self.clampGains(gains, for: device)
                        device.setWhiteBalanceModeLocked(with: clamped, completionHandler: nil)
                    }
                case "incandescent":
                    // 白炽灯 ≈ 2700K
                    if device.isWhiteBalanceModeSupported(.locked) {
                        let gains = device.deviceWhiteBalanceGains(for:
                            AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                                temperature: 2700, tint: 0))
                        let clamped = self.clampGains(gains, for: device)
                        device.setWhiteBalanceModeLocked(with: clamped, completionHandler: nil)
                    }
                case "fluorescent":
                    // 荧光灯 ≈ 4000K
                    if device.isWhiteBalanceModeSupported(.locked) {
                        let gains = device.deviceWhiteBalanceGains(for:
                            AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                                temperature: 4000, tint: 0))
                        let clamped = self.clampGains(gains, for: device)
                        device.setWhiteBalanceModeLocked(with: clamped, completionHandler: nil)
                    }
                case "manual":
                    // 手动模式：使用 tempK 将开尔文度转换为增益
                    let clampedK = Float(max(1800, min(8000, tempK)))
                    if device.isWhiteBalanceModeSupported(.locked) {
                        let gains = device.deviceWhiteBalanceGains(for:
                            AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                                temperature: clampedK, tint: 0))
                        let clamped = self.clampGains(gains, for: device)
                        device.setWhiteBalanceModeLocked(with: clamped, completionHandler: nil)
                    }
                default:
                    if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                        device.whiteBalanceMode = .continuousAutoWhiteBalance
                    }
                }
                device.unlockForConfiguration()
            } catch {
                print("[CameraSessionManager] setWhiteBalance error: \(error)")
            }
        }
    }

    // MARK: - Resolution / Sharpness

    /// 根据清晰度级别动态切换 sessionPreset（影响拍摄分辨率）
    /// level: 0.0=低(.hd1280x720), 0.5=中(.hd1920x1080), 1.0=高(.photo 全像素)
    /// 与 Android buildImageCapture(level) 对等
    func setResolution(level: Float, completion: (() -> Void)? = nil) {
        let newPreset: AVCaptureSession.Preset
        switch level {
        case ..<0.2:
            // 低清晰度：720p
            newPreset = .hd1280x720
        case 0.2..<0.7:
            // 中清晰度：1080p（isHighResolutionCaptureEnabled 会在此 preset 下
            // 选择设备支持的最高分辨率，通常 8-12MP）
            newPreset = .hd1920x1080
        default:
            // 高清晰度：.photo 使用设备全像素（最高分辨率）
            newPreset = .photo
        }
        // CRITICAL FIX: invoke completion AFTER sessionPreset is committed, not before.
        // Previously the caller returned result(nil) immediately, causing Flutter's
        // takePhoto to run before the new sessionPreset was applied.
        sessionQueue.async { [weak self] in
            guard let self = self else {
                completion?()
                return
            }
            if self.session.sessionPreset != newPreset {
                if self.session.canSetSessionPreset(newPreset) {
                    self.session.beginConfiguration()
                    self.session.sessionPreset = newPreset
                    self.session.commitConfiguration()
                    print("[CameraSessionManager] setResolution: level=\(level), preset=\(newPreset.rawValue)")
                } else {
                    print("[CameraSessionManager] setResolution: preset \(newPreset.rawValue) not supported")
                }
            }
            completion?()
        }
    }

    // MARK: - Capture Photo

    /// 高分辨率拍照（使用 AVCapturePhotoOutput，与 Android CameraX takePicture 对等）
    /// deviceQuarter: 0=竖屏, 1=左横屏, 2=倒竖, 3=右横屏
    func capturePhoto(
        flashMode: AVCaptureDevice.FlashMode,
        deviceQuarter: Int = 0,
        completion: @escaping (Data?) -> Void
    ) {
        guard let photoOutput = photoOutput else {
            completion(nil)
            return
        }
        self.photoCaptureCallback = completion

        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            // iOS 16+: use maxPhotoDimensions to request full-sensor resolution.
            // iOS 15 and below: fall back to isHighResolutionPhotoEnabled.
            if #available(iOS 16.0, *) {
                // Request the maximum supported photo dimensions (full sensor resolution).
                // photoOutput.maxPhotoDimensions reflects the current sessionPreset:
                //   .photo  → full sensor (e.g. 4032x3024 on iPhone 12)
                //   .hd1920x1080 → up to sensor max via high-res capture
                //   .hd1280x720  → 720p
                settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
            } else {
                settings.isHighResolutionPhotoEnabled = true
            }
            if photoOutput.supportedFlashModes.contains(flashMode) {
                settings.flashMode = flashMode
            }
            if let connection = photoOutput.connection(with: .video),
               connection.isVideoOrientationSupported {
                connection.videoOrientation = Self.videoOrientation(from: deviceQuarter)
            }
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    // MARK: - Private Helpers

    private func captureDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        // 优先使用广角镜头
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) {
            return device
        }
        return AVCaptureDevice.default(for: .video)
    }

    private static func videoOrientation(from quarter: Int) -> AVCaptureVideoOrientation {
        switch quarter {
        case 1:
            return .landscapeLeft
        case 2:
            return .portraitUpsideDown
        case 3:
            return .landscapeRight
        default:
            return .portrait
        }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraSessionManager: AVCapturePhotoCaptureDelegate {

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error = error {
            print("[CameraSessionManager] capturePhoto error: \(error)")
            photoCaptureCallback?(nil)
        } else {
            let data = photo.fileDataRepresentation()
            photoCaptureCallback?(data)
        }
        photoCaptureCallback = nil
    }
}
