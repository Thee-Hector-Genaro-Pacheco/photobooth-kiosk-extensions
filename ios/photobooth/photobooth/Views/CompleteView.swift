//
//  CompleteView.swift
//  photobooth
//
//  Minimal accepted-state screen. Sharing/printing are explicitly out of
//  scope for this milestone.
//

import SwiftUI

struct CompleteView: View {
    let onNewSession: () -> Void

    @State private var appeared = false

    var body: some View {
        ZStack {
            OpticalBackdrop()

            VStack(spacing: Theme.Spacing.lg) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 60, weight: .ultraLight))
                    .foregroundStyle(Theme.Palette.optic)
                    .opticalGlow(intensity: 0.7)

                Text("PHOTO READY")
                    .font(Theme.Typography.display)
                    .foregroundStyle(Theme.Palette.textPrimary)

                Button(action: onNewSession) {
                    Label("New Session", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.opticalPrimary)
                .padding(.top, Theme.Spacing.lg)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 12)
        }
        .onAppear {
            withAnimation(Theme.Motion.reveal) { appeared = true }
        }
    }
}
