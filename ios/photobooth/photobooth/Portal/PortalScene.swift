//
//  PortalScene.swift
//  photobooth
//
//  Data-driven Portal background catalog. Scenes are rendered natively
//  (gradient + sparse static particle field via Core Graphics) rather than
//  shipping bundled art — this keeps the milestone network-free and leaves
//  room to swap in real branded scene assets later without touching the
//  compositing pipeline.
//

import CoreGraphics
import UIKit

enum PortalScene: String, CaseIterable, Identifiable, Equatable {
    case classic
    case neonCity
    case deepSpace
    case redCarpet

    var id: String { rawValue }

    /// `.classic` skips segmentation/background-replacement entirely and
    /// uses the real camera feed — every other scene is Portal Mode.
    var experience: BoothExperience { self == .classic ? .classic : .portal }

    var displayName: String {
        switch self {
        case .classic: "Classic"
        case .neonCity: "Neon"
        case .deepSpace: "Space"
        case .redCarpet: "Red Carpet"
        }
    }

    private var gradientColors: [UIColor] {
        switch self {
        case .classic:
            [.black, .black]
        case .neonCity:
            [UIColor(red: 0.06, green: 0.02, blue: 0.14, alpha: 1), UIColor(red: 0.52, green: 0.08, blue: 0.62, alpha: 1)]
        case .deepSpace:
            [UIColor(red: 0.01, green: 0.02, blue: 0.05, alpha: 1), UIColor(red: 0.04, green: 0.07, blue: 0.16, alpha: 1)]
        case .redCarpet:
            [UIColor(red: 0.12, green: 0.02, blue: 0.03, alpha: 1), UIColor(red: 0.38, green: 0.07, blue: 0.09, alpha: 1)]
        }
    }

    private var particleColor: UIColor {
        switch self {
        case .classic: .clear
        case .neonCity: UIColor(red: 0.55, green: 0.95, blue: 1.0, alpha: 1)
        case .deepSpace: .white
        case .redCarpet: UIColor(red: 1.0, green: 0.82, blue: 0.55, alpha: 1)
        }
    }

    private var particleCount: Int {
        switch self {
        case .classic: 0
        case .neonCity: 40
        case .deepSpace: 90
        case .redCarpet: 30
        }
    }

    /// Restrained accent used for the thin edge-light glow where the
    /// segmented guest meets the replacement background. Kept low-alpha so
    /// it reads as environmental integration, not a filter over the guest.
    var edgeTintColor: CGColor {
        switch self {
        case .classic: CGColor(gray: 0, alpha: 0)
        case .neonCity: CGColor(red: 0.38, green: 0.88, blue: 0.95, alpha: 0.55)
        case .deepSpace: CGColor(red: 0.55, green: 0.65, blue: 1.0, alpha: 0.4)
        case .redCarpet: CGColor(red: 1.0, green: 0.75, blue: 0.45, alpha: 0.45)
        }
    }

    /// Renders this scene's background at `pixelSize`. Deterministic art
    /// (gradient + evenly-seeded particle scatter), safe to cache per size.
    func backgroundImage(pixelSize: CGSize) -> UIImage {
        let size = CGSize(width: max(1, pixelSize.width), height: max(1, pixelSize.height))
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { rendererContext in
            let cgContext = rendererContext.cgContext
            let colors = gradientColors.map(\.cgColor) as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: nil) {
                cgContext.drawLinearGradient(
                    gradient,
                    start: .zero,
                    end: CGPoint(x: size.width, y: size.height),
                    options: []
                )
            }

            guard particleCount > 0 else { return }
            var rng = SplitMix64(seed: 0x506F7274616C ^ UInt64(rawValue.hashValue))
            for _ in 0..<particleCount {
                let x = CGFloat(rng.nextUnit()) * size.width
                let y = CGFloat(rng.nextUnit()) * size.height
                let radius = 1.5 + CGFloat(rng.nextUnit()) * 3.5
                let alpha = 0.15 + CGFloat(rng.nextUnit()) * 0.45
                cgContext.setFillColor(particleColor.withAlphaComponent(alpha).cgColor)
                cgContext.fillEllipse(in: CGRect(x: x - radius / 2, y: y - radius / 2, width: radius, height: radius))
            }
        }
    }
}

/// Tiny deterministic PRNG so a scene's particle scatter is stable across
/// repeated renders (safe to cache) without pulling in a random-number
/// dependency for what is otherwise a cosmetic placeholder texture.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func nextUnit() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0)
    }
}
