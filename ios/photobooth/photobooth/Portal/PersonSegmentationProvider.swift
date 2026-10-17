//
//  PersonSegmentationProvider.swift
//  photobooth
//
//  Thin wrapper around Vision's native person segmentation. Produces one
//  matte covering every person in frame (not per-instance) — sufficient for
//  background replacement, which only needs "foreground people vs. not."
//  Always called off the main actor.
//

import CoreVideo
import Vision

final class PersonSegmentationProvider {
    private let request: VNGeneratePersonSegmentationRequest

    init(quality: VNGeneratePersonSegmentationRequest.QualityLevel) {
        request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = quality
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    func mask(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> CVPixelBuffer? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        return request.results?.first?.pixelBuffer
    }

    func mask(cgImage: CGImage, orientation: CGImagePropertyOrientation) -> CVPixelBuffer? {
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        return request.results?.first?.pixelBuffer
    }
}
