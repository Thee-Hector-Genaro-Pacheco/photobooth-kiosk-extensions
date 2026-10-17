//
//  CameraSession.swift
//  photobooth
//
//  Owns the AVCaptureSession. All configuration and start/stop calls run on a
//  private serial queue so the main thread never blocks on capture hardware.
//
//  In addition to the live preview input, this configures a video data
//  output (face analysis) and a photo output (still capture). Both share the
//  same front-camera input as the working preview and do not alter it.
//

import AVFoundation
import UIKit

enum CameraSessionError: LocalizedError {
    case noFrontCamera
    case cannotAddInput
    case notConfigured
    case captureFailed

    var errorDescription: String? {
        switch self {
        case .noFrontCamera: "No front camera was found on this device."
        case .cannotAddInput: "The front camera could not be connected."
        case .notConfigured: "The camera session has not started yet."
        case .captureFailed: "The photo could not be captured."
        }
    }
}

nonisolated final class CameraSession: @unchecked Sendable {
    let captureSession = AVCaptureSession()

    private let queue = DispatchQueue(label: "org.firmecoding.photobooth.camera-session")
    // Only touched on `queue`.
    private var configuredDevice: AVCaptureDevice?
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let frameRelay = FrameRelay()
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var pendingPhotoDelegate: PhotoCaptureDelegate?

    /// Called off the main thread, at most ~15 times a second, with the most
    /// recently analyzed frame's face (or `nil` when none is found).
    var onFaceUpdate: ((NormalizedFaceState?) -> Void)? {
        get { frameRelay.onFace }
        set { frameRelay.onFace = newValue }
    }

    /// Configures the front camera on first use, then starts the session.
    func start() async throws -> AVCaptureDevice {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let device = try self.configureIfNeeded()
                    if !self.captureSession.isRunning {
                        self.captureSession.startRunning()
                    }
                    continuation.resume(returning: device)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        queue.async {
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
        }
    }

    /// Captures a single still photo from the live front-camera feed,
    /// mirrored to match what the guest saw in the (mirrored) preview.
    func capturePhoto() async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.configuredDevice != nil else {
                    continuation.resume(throwing: CameraSessionError.notConfigured)
                    return
                }
                guard let connection = self.photoOutput.connection(with: .video) else {
                    continuation.resume(throwing: CameraSessionError.captureFailed)
                    return
                }

                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
                if let coordinator = self.rotationCoordinator {
                    let angle = coordinator.videoRotationAngleForHorizonLevelCapture
                    if connection.isVideoRotationAngleSupported(angle) {
                        connection.videoRotationAngle = angle
                    }
                }

                let delegate = PhotoCaptureDelegate { [weak self] result in
                    self?.queue.async { self?.pendingPhotoDelegate = nil }
                    continuation.resume(with: result)
                }
                self.pendingPhotoDelegate = delegate
                self.photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: delegate)
            }
        }
    }

    private func configureIfNeeded() throws -> AVCaptureDevice {
        if let configuredDevice { return configuredDevice }

        // iPads expose the front camera as wide-angle, ultra-wide (Center Stage)
        // or TrueDepth depending on model. Take whichever exists.
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTrueDepthCamera],
            mediaType: .video,
            position: .front
        )
        guard let device = discovery.devices.first else {
            throw CameraSessionError.noFrontCamera
        }
        let input = try AVCaptureDeviceInput(device: device)

        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        if captureSession.canSetSessionPreset(.high) {
            captureSession.sessionPreset = .high
        }
        guard captureSession.canAddInput(input) else {
            throw CameraSessionError.cannotAddInput
        }
        captureSession.addInput(input)

        if captureSession.canAddOutput(videoOutput) {
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(frameRelay, queue: queue)
            captureSession.addOutput(videoOutput)
        }

        if captureSession.canAddOutput(photoOutput) {
            captureSession.addOutput(photoOutput)
        }

        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotationCoordinator = coordinator
        applyRotationAngle(coordinator.videoRotationAngleForHorizonLevelCapture)
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] coordinator, _ in
            self?.queue.async {
                self?.applyRotationAngle(coordinator.videoRotationAngleForHorizonLevelCapture)
            }
        }

        if let connection = videoOutput.connection(with: .video) {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }

        configuredDevice = device
        return device
    }

    /// Applies the current horizon-level rotation angle to the data output
    /// connection so frames handed to Vision arrive already upright.
    private func applyRotationAngle(_ angle: CGFloat) {
        guard let connection = videoOutput.connection(with: .video),
              connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }
}

/// Bridges AVCaptureVideoDataOutput frames to FaceTrackingProvider off the
/// main thread, throttled and backlog-free: at most one Vision request is
/// ever in flight, and frames arriving faster than the analysis rate are
/// simply dropped rather than queued.
private final class FrameRelay: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onFace: ((NormalizedFaceState?) -> Void)?

    private let provider = FaceTrackingProvider()
    private let minAnalysisInterval: CFTimeInterval = 1.0 / 15.0
    private var lastAnalysisTime: CFTimeInterval = 0
    private var isAnalyzing = false

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !isAnalyzing else { return }
        let now = CACurrentMediaTime()
        guard now - lastAnalysisTime >= minAnalysisInterval else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        lastAnalysisTime = now
        isAnalyzing = true

        // Rotation is already applied by the connection (videoRotationAngle),
        // and any mirroring is intentional (matches the mirrored preview), so
        // Vision should analyze the buffer exactly as delivered.
        let face = provider.analyze(pixelBuffer: pixelBuffer, orientation: .up)
        isAnalyzing = false
        onFace?(face)
    }
}

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (Result<UIImage, Error>) -> Void

    init(completion: @escaping (Result<UIImage, Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            completion(.failure(error))
            return
        }
        guard let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else {
            completion(.failure(CameraSessionError.captureFailed))
            return
        }
        completion(.success(image))
    }
}
