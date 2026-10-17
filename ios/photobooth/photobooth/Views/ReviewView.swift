//
//  ReviewView.swift
//  photobooth
//
//  Shows the composited capture (effect baked in, matching what the guest
//  saw live) with exactly two actions: retake or accept.
//

import SwiftUI

struct ReviewView: View {
    let image: UIImage
    let onRetake: () -> Void
    let onUsePhoto: () -> Void

    @State private var appeared = false

    var body: some View {
        ZStack {
            OpticalBackdrop()

            VStack(spacing: Theme.Spacing.xl) {
                Text("REVIEW")
                    .font(Theme.Typography.label)
                    .tracking(3)
                    .foregroundStyle(Theme.Palette.textTertiary)

                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
                    .glassSurface(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous), illumination: 0.3)
                    .padding(.horizontal, Theme.Spacing.xl)

                HStack(spacing: Theme.Spacing.md) {
                    Button(action: onRetake) {
                        Label("Retake", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.opticalSecondary)

                    Button(action: onUsePhoto) {
                        Label("Use Photo", systemImage: "checkmark")
                    }
                    .buttonStyle(.opticalPrimary)
                }
            }
            .padding(Theme.Spacing.xl)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 12)
        }
        .onAppear {
            withAnimation(Theme.Motion.reveal) { appeared = true }
        }
    }
}
