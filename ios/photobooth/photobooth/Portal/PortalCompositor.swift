//
//  PortalCompositor.swift
//  photobooth
//
//  Core Image compositing shared by the live throttled preview and the
//  high-quality still capture: person over replacement background, masked
//  by Vision's person-segmentation matte, with a thin tinted edge-light for
//  restrained environmental integration. One code path for both, so live
//  and captured Portal output can never drift apart.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import Vision

enum PortalCompositor {
    /// Composites `person` over `background` using `mask` (Vision's person
    /// segmentation matte, arbitrary resolution) plus a subtle `edgeTint`
    /// glow at the segmentation boundary. Returns `nil` only on a Core Image
    /// failure — callers should fall back to the uncomposited frame/image.
    static func composite(
        person: CIImage,
        mask: CIImage,
        background: CIImage,
        edgeTint: CGColor,
        context: CIContext
    ) -> CGImage? {
        let extent = person.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let maskScaleX = extent.width / max(mask.extent.width, 1)
        let maskScaleY = extent.height / max(mask.extent.height, 1)
        let scaledMask = mask.transformed(by: CGAffineTransform(scaleX: maskScaleX, y: maskScaleY))

        // A tight and a feathered version of the same mask: the difference
        // between them is a thin ring right at the segmentation boundary,
        // used below for the edge-light glow. Feathering also avoids a
        // harsh cutout where the person meets the replacement background.
        let tightMask = scaledMask.clampedToExtent().cropped(to: extent)
        let featheredMask = scaledMask.clampedToExtent()
            .applyingGaussianBlur(sigma: 4)
            .cropped(to: extent)

        let backgroundFitted = background.transformed(by: CGAffineTransform(
            scaleX: extent.width / max(background.extent.width, 1),
            y: extent.height / max(background.extent.height, 1)
        ))

        let blend = CIFilter.blendWithMask()
        blend.inputImage = person
        blend.backgroundImage = backgroundFitted
        blend.maskImage = featheredMask
        guard let composited = blend.outputImage else { return nil }

        // Best-effort edge glow — any failure here just skips the glow and
        // returns the plain composite rather than failing the whole frame.
        guard edgeTint.alpha > 0,
              let edgeBand = CIFilter(name: "CISubtractBlendMode") else {
            return context.createCGImage(composited, from: extent)
        }
        edgeBand.setValue(featheredMask, forKey: kCIInputImageKey)
        edgeBand.setValue(tightMask, forKey: kCIInputBackgroundImageKey)
        guard let edgeMask = edgeBand.outputImage else {
            return context.createCGImage(composited, from: extent)
        }

        let colorGenerator = CIFilter.constantColorGenerator()
        colorGenerator.color = CIColor(cgColor: edgeTint)
        guard let tintImage = colorGenerator.outputImage?.cropped(to: extent) else {
            return context.createCGImage(composited, from: extent)
        }

        let tintedEdge = CIFilter.blendWithMask()
        tintedEdge.inputImage = tintImage
        tintedEdge.backgroundImage = composited
        tintedEdge.maskImage = edgeMask
        let final = tintedEdge.outputImage ?? composited

        return context.createCGImage(final, from: extent)
    }

    /// High-quality still-capture path: runs `.accurate` segmentation on the
    /// full-resolution captured photo and bakes the selected scene in.
    /// AR face effects are composited separately (by `EffectCompositor`,
    /// applied after this) so the two concerns stay decoupled.
    static func compositeStill(scene: PortalScene, into image: UIImage) -> UIImage {
        guard scene != .classic, let cgImage = image.cgImage else { return image }

        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        let segmentation = PersonSegmentationProvider(quality: .accurate)
        guard let maskBuffer = segmentation.mask(cgImage: cgImage, orientation: orientation) else { return image }

        let person = CIImage(cgImage: cgImage)
        let mask = CIImage(cvPixelBuffer: maskBuffer)
        let background = CIImage(image: scene.backgroundImage(pixelSize: image.size)) ?? CIImage.empty()
        let context = CIContext()

        guard let outputCG = composite(person: person, mask: mask, background: background, edgeTint: scene.edgeTintColor, context: context) else {
            return image
        }
        return UIImage(cgImage: outputCG, scale: image.scale, orientation: .up)
    }
}
