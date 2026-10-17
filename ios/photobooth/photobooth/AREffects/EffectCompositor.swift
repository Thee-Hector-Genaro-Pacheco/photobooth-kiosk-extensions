//
//  EffectCompositor.swift
//  photobooth
//
//  Bakes the active effect into a captured still so the reviewed photo
//  matches what the guest saw live. Re-runs face detection against the full
//  resolution capture rather than reusing preview-time coordinates, since a
//  still can be captured at a different moment/resolution than the last
//  live analysis.
//

import UIKit
import Vision

enum EffectCompositor {
    /// Returns a new image with `effect` composited on top of `image`. Falls
    /// back to the original image untouched if no face is found or the
    /// effect has no elements — capture must never fail because AR did.
    static func composite(effect: EffectDefinition, into image: UIImage) -> UIImage {
        guard !effect.elements.isEmpty, let cgImage = image.cgImage else { return image }

        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        let provider = FaceTrackingProvider()
        guard let face = provider.analyze(cgImage: cgImage, orientation: orientation, sourceSize: image.size) else {
            return image
        }

        let geometry = CoverFitGeometry(sourceSize: face.sourceSize, canvasSize: image.size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)

        return renderer.image { context in
            image.draw(at: .zero)
            let cgContext = context.cgContext

            for element in effect.elements {
                guard let asset = UIImage(named: element.assetName),
                      let placement = EffectPlacementEngine.placement(
                        for: element,
                        face: face,
                        geometry: geometry,
                        assetPixelSize: asset.size
                      ) else { continue }

                cgContext.saveGState()
                cgContext.translateBy(x: placement.center.x, y: placement.center.y)
                cgContext.rotate(by: placement.rotationRadians)
                asset.draw(in: CGRect(
                    x: -placement.size.width / 2,
                    y: -placement.size.height / 2,
                    width: placement.size.width,
                    height: placement.size.height
                ))
                cgContext.restoreGState()
            }
        }
    }
}

extension CGImagePropertyOrientation {
    init(_ uiOrientation: UIImage.Orientation) {
        switch uiOrientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
