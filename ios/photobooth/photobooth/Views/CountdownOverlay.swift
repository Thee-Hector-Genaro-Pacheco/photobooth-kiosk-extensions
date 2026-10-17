//
//  CountdownOverlay.swift
//  photobooth
//
//  Restrained booth countdown: large precision typography and a single
//  optical pulse per tick, with illumination increasing as capture nears.
//  Deliberately free of bounce/cartoon motion.
//

import SwiftUI

struct CountdownOverlay: View {
    let value: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    /// 3 -> dim, 1 -> brightest, matching "increasing illumination as capture approaches."
    private var illumination: Double {
        switch value {
        case ...1: 1.0
        case 2: 0.65
        default: 0.35
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Theme.Palette.optic.opacity(0.28 * illumination), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 240
                    )
                )
                .frame(width: 420, height: 420)

            Text("\(value)")
                .font(.system(size: 168, weight: .thin, design: .rounded))
                .foregroundStyle(Theme.Palette.textPrimary)
                .opticalGlow(intensity: 0.5 + illumination * 0.5)
        }
        .scaleEffect(revealed ? 1.0 : 0.92)
        .opacity(revealed ? 1 : 0)
        .id(value)
        .onAppear {
            revealed = false
            guard !reduceMotion else {
                revealed = true
                return
            }
            withAnimation(.easeOut(duration: 0.32)) { revealed = true }
        }
        .accessibilityHidden(true)
    }
}
