//
//  LoopVideoWriter.swift
//  photobooth
//
//  Encodes a sequence of CGImages into a local .mov file via AVAssetWriter.
//  MOV/H.264 rather than GIF: smaller, better quality, and a sane starting
//  point for later QR/SMS/share delivery work (not implemented here).
//

import AVFoundation
import CoreGraphics
import CoreVideo

enum LoopVideoWriter {
    /// Encodes `images` at `fps` and hands back a file URL in the app's
    /// temporary directory. Always runs off the caller's thread and calls
    /// `completion` back on the main actor.
    static func write(images: [CGImage], fps: Int32, completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let url = try writeSynchronously(images: images, fps: fps)
                DispatchQueue.main.async { completion(.success(url)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// Synchronous by design (blocks the background queue it's called on
    /// until encoding finishes) — never call this from the main actor.
    private static func writeSynchronously(images: [CGImage], fps: Int32) throws -> URL {
        guard let first = images.first else { throw LoopCaptureError.notEnoughFrames }
        let width = first.width
        let height = first.height

        // Unique per-session filename so concurrent/repeated sessions never
        // collide or overwrite a previous guest's temporary output.
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("loop-\(UUID().uuidString)")
            .appendingPathExtension("mov")

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )

        guard writer.canAdd(input) else { throw LoopCaptureError.writerUnavailable }
        writer.add(input)

        guard writer.startWriting() else { throw writer.error ?? LoopCaptureError.writerUnavailable }
        writer.startSession(atSourceTime: .zero)

        let frameDuration = CMTime(value: 1, timescale: fps)

        for (index, cgImage) in images.enumerated() {
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.005)
            }
            guard let pool = adaptor.pixelBufferPool else { throw LoopCaptureError.writerUnavailable }
            var pixelBufferOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOut)
            guard let pixelBuffer = pixelBufferOut else { throw LoopCaptureError.writerUnavailable }

            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let context = CGContext(
                data: CVPixelBufferGetBaseAddress(pixelBuffer),
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
            ) {
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(index))
            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                throw writer.error ?? LoopCaptureError.writerUnavailable
            }
        }

        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()

        if writer.status == .failed {
            throw writer.error ?? LoopCaptureError.writerUnavailable
        }
        return outputURL
    }
}
