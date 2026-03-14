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
    func configure(lens: AVCaptureDevice.Position = .back, resolution: AVCaptureSession.Preset = .hd1920x1080) {
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
            photoOutput.isHighResolutionCaptureEnabled = true
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

    // MARK: - Capture Photo

    /// 高分辨率拍照（使用 AVCapturePhotoOutput，与 Android CameraX takePicture 对等）
    func capturePhoto(flashMode: AVCaptureDevice.FlashMode, completion: @escaping (Data?) -> Void) {
        guard let photoOutput = photoOutput else {
            completion(nil)
            return
        }
        self.photoCaptureCallback = completion

        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            settings.isHighResolutionPhotoEnabled = true
            if photoOutput.supportedFlashModes.contains(flashMode) {
                settings.flashMode = flashMode
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
