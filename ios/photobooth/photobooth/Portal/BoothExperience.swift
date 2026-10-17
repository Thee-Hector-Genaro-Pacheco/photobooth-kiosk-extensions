//
//  BoothExperience.swift
//  photobooth
//
//  The smallest abstraction needed for the Experience Hub and CameraView to
//  pick a rendering pipeline / contextual control set without hardcoding
//  every mode into the navigation and view bodies directly. Adding a future
//  experience (photoStrip, aiScene, gestureFX, ...) means adding a case plus
//  its metadata/branch here, not rewriting navigation.
//
//  `.portal` is intentionally left out of `hubExperiences`: the segmentation
//  work is preserved and fully functional, but its edge quality isn't yet at
//  commercial default quality, so it isn't offered as a primary guest choice
//  this phase. Nothing about the Portal implementation was removed.
//

enum BoothExperience: Equatable, Hashable {
    case classic
    case arParty
    case loopClip
    case portal
}

extension BoothExperience {
    /// Guest-facing Experience Hub options, in display order.
    static let hubExperiences: [BoothExperience] = [.classic, .arParty, .loopClip]

    var title: String {
        switch self {
        case .classic: "Classic"
        case .arParty: "AR Party"
        case .loopClip: "Loop"
        case .portal: "Portal"
        }
    }

    /// Kept intentionally short — this is card copy, not a description page.
    var subtitle: String {
        switch self {
        case .classic: "Clean photo capture."
        case .arParty: "Live face effects."
        case .loopClip: "Short animated clip."
        case .portal: "Experimental scene replacement."
        }
    }

    var symbolName: String {
        switch self {
        case .classic: "camera.aperture"
        case .arParty: "sparkles"
        case .loopClip: "arrow.triangle.2.circlepath"
        case .portal: "photo.on.rectangle.angled"
        }
    }
}
