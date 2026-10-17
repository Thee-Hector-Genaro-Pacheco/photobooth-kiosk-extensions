//
//  CinematicScene.swift
//  photobooth
//
//  Reusable "fictional AR content inside the real environment" effect
//  model. The default and only policy Dark Vampire uses is
//  `.preserveCamera`: the real camera frame (real walls, real furniture,
//  real other people, real lighting) is never discarded. Person
//  segmentation is used for OCCLUSION, not background replacement — a
//  behind-subject AR layer is drawn onto the real frame, then the real
//  segmented guest is composited back OVER it, so fictional content reads
//  as "inside the room" rather than "instead of the room."
//
//  `.replaceBackground` is kept as a second policy purely for
//  architectural completeness / future reuse (a future effect that
//  genuinely wants a fully replaced scene, Portal-style) — nothing
//  currently routes through CinematicScene with it, and Portal Mode keeps
//  its own separate, untouched PortalScene/PortalEngine/PortalCompositor
//  pipeline exactly as it already worked before this file existed.
//
//  Compositing itself is done by CinematicSceneCompositor, which calls
//  straight into the existing PortalCompositor.composite (segmentation
//  blend) and EffectPlacementEngine.placement (face-element geometry) —
//  the same two functions Portal Mode and every AR Party effect already
//  use. No new rendering engine.
//

import CoreGraphics

/// Where a CinematicLayer sits relative to the segmented guest.
enum CinematicDepthRole {
    /// Drawn onto the real frame BEFORE the guest is composited back over
    /// it — reads as being physically behind/around the guest in the real
    /// room (e.g. a collapsed victim silhouette on the real couch).
    case behindSubject
    /// Drawn on top of everything (real frame + guest + face elements) —
    /// e.g. drifting mist/haze passing partially in front of the guest.
    case foreground
}

/// One fictional AR layer inside a CinematicScene. Deliberately simple:
/// normalized screen-space placement only, no 3D scene understanding, no
/// furniture/surface detection. The goal is high-quality compositing, not
/// semantic understanding of every couch in the venue.
struct CinematicLayer {
    var assetName: String
    var depthRole: CinematicDepthRole
    var opacity: CGFloat = 1.0
    /// Normalized (0...1) placement rect within the frame, same top-left/
    /// y-down convention as every other placement in this app. Defaults
    /// to full-bleed; a smaller rect places the asset in one region (e.g.
    /// a corner) without needing real scene geometry.
    var placement: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
}

/// One named environment image, used only by `.replaceBackground`.
struct CinematicBackground {
    var assetName: String
}

/// How a CinematicScene treats the real camera frame.
enum CinematicBackgroundPolicy {
    /// The real environment is always preserved; fictional content (if
    /// any) is added as CinematicLayer elements behind/in front of the
    /// segmented guest. What Dark Vampire uses.
    case preserveCamera
    /// Discards the real background entirely for `resting`/`triggered`
    /// scene art (Portal Mode's own model) — architectural completeness
    /// only; see the file header.
    case replaceBackground(resting: CinematicBackground, triggered: CinematicBackground)
}

struct CinematicScene {
    var backgroundPolicy: CinematicBackgroundPolicy = .preserveCamera
    /// Layers always active. Empty for Dark Vampire's calm resting state
    /// — no bodies, no aftermath, just the real room.
    var restingLayers: [CinematicLayer] = []
    /// ADDITIVE to `restingLayers` while `trigger` is satisfied — nothing
    /// in `restingLayers` disappears (same additive convention every other
    /// reactive effect in this app already uses).
    var triggeredLayers: [CinematicLayer] = []
    /// Always-visible face elements, drawn directly on the real guest.
    var restingElements: [EffectElement] = []
    /// ADDITIVE face elements while triggered.
    var triggeredElements: [EffectElement] = []
    /// What flips resting -> triggered. Reuses the existing mouth-open
    /// signal — no new expression-detection system.
    var trigger: EffectVisibilityRule
    /// Thin edge-light glow blending the real segmented guest against a
    /// behind-subject layer (or a replaced background), reusing
    /// PortalScene's exact mechanism. Alpha-0 (default) costs nothing.
    var edgeTint: CGColor = CGColor(gray: 0, alpha: 0)

    /// Behind-subject layers active for the given trigger state — the
    /// single source of truth both the compositor and the "do we even
    /// need to run segmentation this frame" check consult. Segmentation
    /// is genuinely unnecessary whenever this is empty (nothing to
    /// occlude), which is the main lever this architecture gives for
    /// keeping the resting state cheap.
    func behindSubjectLayers(isTriggered: Bool) -> [CinematicLayer] {
        (isTriggered ? restingLayers + triggeredLayers : restingLayers).filter { $0.depthRole == .behindSubject }
    }

    func foregroundLayers(isTriggered: Bool) -> [CinematicLayer] {
        (isTriggered ? restingLayers + triggeredLayers : restingLayers).filter { $0.depthRole == .foreground }
    }

    func faceElements(isTriggered: Bool) -> [EffectElement] {
        isTriggered ? restingElements + triggeredElements : restingElements
    }

    /// Whether this scene ever needs a segmentation mask for the given
    /// trigger state — `false` skips the Vision call entirely, not just
    /// its result.
    func needsSegmentation(isTriggered: Bool) -> Bool {
        if case .replaceBackground = backgroundPolicy { return true }
        return !behindSubjectLayers(isTriggered: isTriggered).isEmpty
    }
}
