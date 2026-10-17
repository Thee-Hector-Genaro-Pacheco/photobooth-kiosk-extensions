//
//  EffectOverlayView.swift
//  photobooth
//
//  Draws the active effect's elements over the live camera preview using the
//  shared EffectPlacementEngine, once per currently tracked face. Zero
//  per-effect and zero per-face branches — every face gets independently
//  placed geometry from its own NormalizedFaceState.
//

import SwiftUI

struct EffectOverlayView: View {
    let effect: EffectDefinition
    let faces: [TrackedFaceState]

    @State private var images: [String: UIImage] = [:]

    var body: some View {
        Canvas { context, size in
            guard let sourceSize = faces.first?.faceState.sourceSize else { return }
            // All faces in this batch come from the same analyzed frame, so
            // they share one source size and one cover-fit mapping.
            let geometry = CoverFitGeometry(sourceSize: sourceSize, canvasSize: size)

            for tracked in faces {
                let face = tracked.faceState
                for element in effect.elements {
                    guard let uiImage = images[element.assetName],
                          let placement = EffectPlacementEngine.placement(
                            for: element,
                            face: face,
                            geometry: geometry,
                            assetPixelSize: uiImage.size
                          ) else { continue }

                    let resolved = context.resolve(Image(uiImage: uiImage))
                    context.drawLayer { layer in
                        layer.translateBy(x: placement.center.x, y: placement.center.y)
                        layer.rotate(by: .radians(placement.rotationRadians))
                        layer.draw(
                            resolved,
                            in: CGRect(
                                x: -placement.size.width / 2,
                                y: -placement.size.height / 2,
                                width: placement.size.width,
                                height: placement.size.height
                            )
                        )
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: effect.id) { loadImages() }
    }

    private func loadImages() {
        for element in effect.elements where images[element.assetName] == nil {
            if let image = UIImage(named: element.assetName) {
                images[element.assetName] = image
            }
        }
    }
}
