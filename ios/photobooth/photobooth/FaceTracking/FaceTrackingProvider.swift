//
//  FaceTrackingProvider.swift
//  photobooth
//
//  Thin wrapper around Vision. Runs synchronously and is always called from a
//  background queue (never the main actor) — callers are responsible for
//  throttling how often frames are analyzed.
//
//  Also owns the small bit of *temporal* state that a per-frame geometry
//  snapshot (NormalizedFaceState) can't carry itself: stable multi-face
//  identity across frames, and per-face hysteresis/smoothing for the
//  mouth-open expression so it doesn't flicker near the boundary. Each call
//  site (live session, still capture) uses its own FaceTrackingProvider
//  instance, so this state never leaks between them.
//

import CoreVideo
import QuartzCore
import Vision

final class FaceTrackingProvider {
    /// Initial production cap — keeps live Vision processing bounded
    /// regardless of how many people wander into frame.
    static let maxTrackedFaces = 4

    /// Normalized (fraction of image width/height) center distance below
    /// which a new observation is considered "the same face" as an existing
    /// track. Matches the browser prototype's multi-face matching radius.
    private static let matchDistanceThreshold: CGFloat = 0.18
    /// How many consecutive missed frames a track tolerates (a brief look-away
    /// or motion-blur miss) before it's retired and its ID freed.
    private static let maxMissedFrames = 5

    private struct FaceTrack {
        var lastCenter: CGPoint
        var missedFrames = 0
        var isMouthOpen = false
        var smoothedMouthRatio: CGFloat?
    }

    private var tracks: [Int: FaceTrack] = [:]
    private var nextID = 1
    private var lastDebugLogTime: CFTimeInterval = 0

    /// Analyzes a single upright pixel buffer for all faces (up to
    /// `maxTrackedFaces`) and returns them with stable per-session IDs.
    /// Returns an empty array when no face is found or analysis fails —
    /// callers should treat that as "no faces this cycle", not an error.
    func analyze(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> [TrackedFaceState] {
        let sourceSize = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        let observations = detect(cvPixelBuffer: pixelBuffer, orientation: orientation)
        let result = processObservations(observations, sourceSize: sourceSize)
        logMouthDebugIfNeeded(result)
        return result
    }

    /// Analyzes a still image (already oriented per `orientation`) for all
    /// faces. Used to re-evaluate geometry against a full-resolution capture
    /// instead of stretching preview-time coordinates onto it.
    func analyze(cgImage: CGImage, orientation: CGImagePropertyOrientation, sourceSize: CGSize) -> [TrackedFaceState] {
        let observations = detect(cgImage: cgImage, orientation: orientation)
        return processObservations(observations, sourceSize: sourceSize)
    }

    private func detect(cvPixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> [VNFaceObservation] {
        let handler = VNImageRequestHandler(cvPixelBuffer: cvPixelBuffer, orientation: orientation, options: [:])
        return runFaceLandmarks(handler)
    }

    private func detect(cgImage: CGImage, orientation: CGImagePropertyOrientation) -> [VNFaceObservation] {
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        return runFaceLandmarks(handler)
    }

    private func runFaceLandmarks(_ handler: VNImageRequestHandler) -> [VNFaceObservation] {
        let request = VNDetectFaceLandmarksRequest()
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        return request.results ?? []
    }

    /// Builds normalized geometry for each observation, associates it with an
    /// existing track (nearest-center match within `matchDistanceThreshold`)
    /// or allocates a new ID, ages out tracks that went unmatched this frame,
    /// and applies per-face mouth hysteresis/smoothing.
    private func processObservations(_ observations: [VNFaceObservation], sourceSize: CGSize) -> [TrackedFaceState] {
        var candidates = observations.compactMap { NormalizedFaceState(observation: $0, sourceSize: sourceSize) }

        // If more faces are visible than we track, keep the most prominent
        // (largest/closest) ones rather than an arbitrary detection-order subset.
        candidates.sort { $0.interEyeDistance > $1.interEyeDistance }
        if candidates.count > Self.maxTrackedFaces {
            candidates = Array(candidates.prefix(Self.maxTrackedFaces))
        }

        var unmatched = Set(tracks.keys)
        var results: [TrackedFaceState] = []

        for candidate in candidates {
            let center = candidate.eyeCenter
            var bestID: Int?
            var bestDistance = Self.matchDistanceThreshold
            for id in unmatched {
                guard let track = tracks[id] else { continue }
                let distance = hypot(track.lastCenter.x - center.x, track.lastCenter.y - center.y)
                if distance < bestDistance {
                    bestDistance = distance
                    bestID = id
                }
            }

            let id: Int
            if let bestID {
                id = bestID
                unmatched.remove(bestID)
            } else {
                id = nextID
                nextID += 1
                tracks[id] = FaceTrack(lastCenter: center)
            }
            tracks[id]?.lastCenter = center
            tracks[id]?.missedFrames = 0

            var state = candidate
            applyMouthExpression(to: &state, trackID: id)
            results.append(TrackedFaceState(id: id, faceState: state))
        }

        // Faces truly lost (missed too many consecutive frames) are dropped —
        // their expression state goes with them, so a later reappearance (new
        // ID) starts clean rather than resuming a stale mouth-open state.
        for id in unmatched {
            tracks[id]?.missedFrames += 1
            if let missed = tracks[id]?.missedFrames, missed > Self.maxMissedFrames {
                tracks.removeValue(forKey: id)
            }
        }

        return results
    }

    /// Lightly smooths the raw ratio (mild — hysteresis, not smoothing, does
    /// most of the anti-flicker work so the tongue still reacts quickly),
    /// then applies open/close hysteresis so `mouthOpen` doesn't chatter
    /// right at the threshold. Tracked per-face so one person's mouth state
    /// can never leak onto another's.
    private func applyMouthExpression(to state: inout NormalizedFaceState, trackID: Int) {
        guard var track = tracks[trackID] else { return }
        let previous = track.smoothedMouthRatio ?? state.mouthRatio
        let smoothed = previous + 0.5 * (state.mouthRatio - previous)
        track.smoothedMouthRatio = smoothed
        state.mouthRatio = smoothed

        if track.isMouthOpen {
            if smoothed <= NormalizedFaceState.mouthCloseThreshold {
                track.isMouthOpen = false
            }
        } else if smoothed >= NormalizedFaceState.mouthOpenThreshold {
            track.isMouthOpen = true
        }
        state.mouthOpen = track.isMouthOpen
        tracks[trackID] = track
    }

    private func logMouthDebugIfNeeded(_ faces: [TrackedFaceState]) {
        #if DEBUG
        let now = CACurrentMediaTime()
        guard now - lastDebugLogTime > 0.3, !faces.isEmpty else { return }
        lastDebugLogTime = now
        let summary = faces
            .map { String(format: "#%d r=%.2f open=%@", $0.id, $0.faceState.mouthRatio, $0.faceState.mouthOpen ? "Y" : "N") }
            .joined(separator: "  ")
        print("[AR] \(summary)")
        #endif
    }
}
