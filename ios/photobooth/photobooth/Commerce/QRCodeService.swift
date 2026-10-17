//
//  QRCodeService.swift
//  photobooth
//
//  Native QR generation for a claim URL via Core Image — no third-party
//  dependency needed for this. High error-correction level, explicit quiet
//  zone, and nearest-neighbor scaling so the result stays crisp/scannable at
//  display size rather than a blurry stretched bitmap.
//

import CoreImage
import UIKit

enum QRCodeService {
    static func generateImage(for string: String, scale: CGFloat = 10) -> UIImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")
        guard let outputImage = filter.outputImage else { return nil }

        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // Quiet zone: pad with white on all sides so scanners have the
        // margin the QR spec expects, independent of whatever CIImage's
        // default padding happens to be.
        let quietZone = scale * 4
        let paddedExtent = scaled.extent.insetBy(dx: -quietZone, dy: -quietZone)
        let background = CIImage(color: .white).cropped(to: paddedExtent)
        let composited = scaled.composited(over: background)

        let context = CIContext()
        guard let cgImage = context.createCGImage(composited, from: paddedExtent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
