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
            if self.session.canAddOutput(photoOutput) {
                self.session.addOutput(photoOutput)
                self.photoOutput = photoOutput
            }
            
            self.session.commitConfiguration()
        }
    }
    
    func startSession() {
        sessionQueue.async { [weak self] in
            self?.session.startRunning()
        }
    }
    
    func stopSession() {
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
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
    
    // MARK: - Private Helpers
    
    private func captureDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }
}
