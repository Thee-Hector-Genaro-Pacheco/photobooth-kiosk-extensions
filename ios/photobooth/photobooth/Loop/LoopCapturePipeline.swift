//
//  LoopCapturePipeline.swift
//  photobooth
//
//  Accumulates a bounded, downscaled sequence of frames from the existing
//  camera pipeline during a short recording window, then builds a seamless
//  forward/reverse looping video from them. Deliberately does not append to
//  an AVAssetWriter live: reversing the clip requires the whole sequence
//  in hand anyway, so buffering a small, capped, downscaled frame set and
//  encoding once at the end is both simpler and easier to bound in memory
//  than a live-writer + separate reverse pass.
//
//  Frames are plain CGImages (already downscaled), not raw full-resolution
//  pixel buffers, and per-frame AR compositing could be inserted between
//  capture and `buildLoopVideo` later without redesigning this type — see
//  CameraView's capture-path comment for why that isn't wired up yet.
//
//  All mutable state is confined to `stateQueue`, so `ingest` (called from
//  the camera's own frame-delivery queue) and the record/build lifecycle
//  (called from the UI layer) never race.
//

import CoreImage
import CoreVideo
import QuartzCore

final class LoopCapturePipeline {
    /// ~2s at 15fps, plus headroom for timing jitter — a hard ceiling so
    /// recording can never accumulate unbounded frames regardless of timing.
    private static let maxFrames = 40
    private static let targetFrameInterval: CFTimeInterval = 1.0 / 15.0
    private static let downscaleMaxDimension: CGFloat = 720

    private let stateQueue = DispatchQueue(label: "org.firmecoding.photobooth.loop-capture")
    private let ciContext = CIContext()
    private var frames: [CGImage] = []
    private var lastCaptureTime: CFTimeInterval = 0
    private var isRecording = false

    func startRecording() {
        stateQueue.async { [weak self] in
            self?.frames.removeAll()
            self?.lastCaptureTime = 0
            self?.isRecording = true
        }
    }

    func stopRecording() {
        stateQueue.async { [weak self] in
            self?.isRecording = false
        }
    }

    /// Called from the camera's frame-delivery queue (never the main actor).
    /// Silently drops the frame once the cap is reached or recording is off.
    func ingest(_ pixelBuffer: CVPixelBuffer) {
        stateQueue.async { [weak self] in
            guard let self, self.isRecording, self.frames.count < Self.maxFrames else { return }
            let now = CACurrentMediaTime()
            guard now - self.lastCaptureTime >= Self.targetFrameInterval else { return }
            self.lastCaptureTime = now

            let source = CIImage(cvPixelBuffer: pixelBuffer)
            let longestSide = max(source.extent.width, source.extent.height)
            let scale = longestSide > Self.downscaleMaxDimension ? Self.downscaleMaxDimension / longestSide : 1
            let scaled = scale < 1 ? source.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : source
            guard let cgImage = self.ciContext.createCGImage(scaled, from: scaled.extent) else { return }
            self.frames.append(cgImage)
        }
    }

    /// Builds the forward+reverse loop video off the calling thread's
    /// expectations — always hops to a background queue and calls back on
    /// the main actor. Never blocks the caller.
    func buildLoopVideo(fps: Int32 = 15, completion: @escaping (Result<URL, Error>) -> Void) {
        stateQueue.async { [weak self] in
            let sequence = Self.forwardReverseSequence(self?.frames ?? [])
            LoopVideoWriter.write(images: sequence, fps: fps, completion: completion)
        }
    }

    /// A B C D E -> A B C D E D C B — endpoints aren't duplicated so the loop
    /// doesn't visibly pause at either end when it repeats.
    static func forwardReverseSequence(_ frames: [CGImage]) -> [CGImage] {
        guard frames.count > 2 else { return frames }
        let reversedMiddle = Array(frames.dropLast().dropFirst().reversed())
        return frames + reversedMiddle
    }
}

enum LoopCaptureError: LocalizedError {
    case notEnoughFrames
    case writerUnavailable

    var errorDescription: String? {
        switch self {
        case .notEnoughFrames: "Not enough frames were captured to build a loop."
        case .writerUnavailable: "The loop video could not be encoded."
        }
    }
}
