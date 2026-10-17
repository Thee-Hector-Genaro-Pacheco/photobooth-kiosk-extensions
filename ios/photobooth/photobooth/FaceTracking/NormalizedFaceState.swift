//
//  NormalizedFaceState.swift
//  photobooth
//
//  Tracker-agnostic description of a detected face. The AR effect layer only
//  ever sees this type, never Vision's request/observation objects, so the
//  tracking backend can change without touching effect placement code.
//

import CoreGraphics
import Vision

/// Normalized (0...1) face geometry plus the pixel dimensions of the source
/// image that the normalization is relative to. `sourceSize` is required so
/// callers can map these points onto a differently-sized/aspect-ratio'd
/// destination (e.g. an aspect-filled camera preview) via `CoverFitGeometry`.
struct NormalizedFaceState: Equatable {
    var sourceSize: CGSize
    var faceBounds: CGRect
    var leftEye: CGPoint
    var rightEye: CGPoint
    var eyeCenter: CGPoint
    /// Fraction of `sourceSize.width`.
    var interEyeDistance: CGFloat
    var noseAnchor: CGPoint
    var mouthAnchor: CGPoint
    /// Fraction of `sourceSize.width`.
    var mouthWidth: CGFloat
    var foreheadAnchor: CGPoint
    /// Radians, measured from the eye line in the same top-left/y-down space
    /// as every other point on this type.
    var rollRadians: CGFloat
    /// Mouth opening height divided by mouth width. ~0.1-0.2 closed, rises
    /// past 0.3 when clearly open.
    var mouthRatio: CGFloat
    var mouthOpen: Bool

    static let mouthOpenThreshold: CGFloat = 0.32
}

extension NormalizedFaceState {
    /// Builds a `NormalizedFaceState` from a Vision face + landmarks observation.
    ///
    /// - Parameter sourceSize: pixel size of the upright image that was handed
    ///   to the `VNImageRequestHandler` (after orientation correction). All
    ///   returned points/distances are normalized against this size.
    init?(observation: VNFaceObservation, sourceSize: CGSize) {
        guard let landmarks = observation.landmarks,
              sourceSize.width > 0, sourceSize.height > 0 else { return nil }

        let box = observation.boundingBox
        let w = sourceSize.width
        let h = sourceSize.height

        // Vision landmark points are normalized within the face bounding box,
        // itself normalized to the full image with origin bottom-left/y-up.
        // Convert into full-image-normalized, top-left/y-down coordinates.
        func normalizedPoint(_ p: CGPoint) -> CGPoint {
            let vx = box.origin.x + p.x * box.size.width
            let vy = box.origin.y + p.y * box.size.height
            return CGPoint(x: vx, y: 1 - vy)
        }

        func centroidNormalized(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
            guard let region, region.pointCount > 0 else { return nil }
            let pts = region.normalizedPoints
            let sum = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            return normalizedPoint(CGPoint(x: sum.x / CGFloat(pts.count), y: sum.y / CGFloat(pts.count)))
        }

        guard let leftEyeN = centroidNormalized(landmarks.leftEye),
              let rightEyeN = centroidNormalized(landmarks.rightEye) else { return nil }

        // Roll/direction math is done in true pixel space so it isn't skewed
        // by the image's aspect ratio (x and y normalize against different
        // dimensions). Scalars are then re-normalized by width only, matching
        // the convention used by the rest of this placement pipeline.
        let leftEyePx = CGPoint(x: leftEyeN.x * w, y: leftEyeN.y * h)
        let rightEyePx = CGPoint(x: rightEyeN.x * w, y: rightEyeN.y * h)
        let dx = leftEyePx.x - rightEyePx.x
        let dy = leftEyePx.y - rightEyePx.y
        let interEyePx = max(hypot(dx, dy), 1)
        let roll = atan2(dy, dx)
        let uUp = CGVector(dx: dy / interEyePx, dy: -dx / interEyePx)

        let centerPx = CGPoint(x: (leftEyePx.x + rightEyePx.x) / 2, y: (leftEyePx.y + rightEyePx.y) / 2)
        let foreheadPx = CGPoint(
            x: centerPx.x + uUp.dx * interEyePx * 0.75,
            y: centerPx.y + uUp.dy * interEyePx * 0.75
        )

        let noseN = centroidNormalized(landmarks.nose)
            ?? centroidNormalized(landmarks.noseCrest)
            ?? normalizedPoint(CGPoint(x: 0.5, y: 0.5))

        var mouthAnchorN = noseN
        var mouthWidthPx: CGFloat = 0
        var mouthRatioValue: CGFloat = 0
        if let outer = landmarks.outerLips, outer.pointCount > 1 {
            let ptsN = outer.normalizedPoints.map(normalizedPoint)
            if let minX = ptsN.min(by: { $0.x < $1.x }), let maxX = ptsN.max(by: { $0.x < $1.x }) {
                let minXPx = CGPoint(x: minX.x * w, y: minX.y * h)
                let maxXPx = CGPoint(x: maxX.x * w, y: maxX.y * h)
                mouthWidthPx = hypot(maxXPx.x - minXPx.x, maxXPx.y - minXPx.y)
                mouthAnchorN = CGPoint(x: (minX.x + maxX.x) / 2, y: (minX.y + maxX.y) / 2)
            }

            // Mouth-open ratio: prefer inner lip contour (the actual opening);
            // Vision does not expose a dedicated "jaw opening" metric, so this
            // vertical-extent/width ratio is the closest deterministic native
            // equivalent to the browser prototype's expression-engine value.
            let innerPtsN = landmarks.innerLips?.normalizedPoints.map(normalizedPoint) ?? ptsN
            if mouthWidthPx > 1,
               let minY = innerPtsN.min(by: { $0.y < $1.y }),
               let maxY = innerPtsN.max(by: { $0.y < $1.y }) {
                let minYPx = CGPoint(x: minY.x * w, y: minY.y * h)
                let maxYPx = CGPoint(x: maxY.x * w, y: maxY.y * h)
                let openPx = hypot(maxYPx.x - minYPx.x, maxYPx.y - minYPx.y)
                mouthRatioValue = openPx / mouthWidthPx
            }
        }

        self.sourceSize = sourceSize
        self.faceBounds = CGRect(x: box.origin.x, y: 1 - box.origin.y - box.height, width: box.width, height: box.height)
        self.leftEye = leftEyeN
        self.rightEye = rightEyeN
        self.eyeCenter = CGPoint(x: centerPx.x / w, y: centerPx.y / h)
        self.interEyeDistance = interEyePx / w
        self.noseAnchor = noseN
        self.mouthAnchor = mouthAnchorN
        self.mouthWidth = mouthWidthPx / w
        self.foreheadAnchor = CGPoint(x: foreheadPx.x / w, y: foreheadPx.y / h)
        self.rollRadians = roll
        self.mouthRatio = mouthRatioValue
        self.mouthOpen = mouthRatioValue > Self.mouthOpenThreshold
    }
}
