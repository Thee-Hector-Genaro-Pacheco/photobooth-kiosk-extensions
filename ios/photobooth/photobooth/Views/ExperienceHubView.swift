//
//  ExperienceHubView.swift
//  photobooth
//
//  Premium mode-selection screen between Ready and the camera. Each
//  experience reads like a mode on advanced imaging hardware, not a
//  dashboard tile grid — one glass card per experience, only the essentials.
//

import SwiftUI

struct ExperienceHubView: View {
    let onSelect: (BoothExperience) -> Void
    let onBack: () -> Void

    @State private var appeared = false

    var body: some View {
        ZStack {
            OpticalBackdrop()

            VStack(spacing: Theme.Spacing.xl) {
                header

                Spacer(minLength: Theme.Spacing.lg)

                VStack(spacing: Theme.Spacing.md) {
                    ForEach(BoothExperience.hubExperiences, id: \.self) { experience in
                        ExperienceCard(experience: experience) {
                            onSelect(experience)
                        }
                    }
                }

                Spacer(minLength: Theme.Spacing.xl)
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.lg)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 12)
        }
        .onAppear {
            withAnimation(Theme.Motion.reveal) { appeared = true }
        }
    }

    private var header: some View {
        HStack {
            Button(action: onBack) {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(.opticalSecondary)

            Spacer()

            Text("SELECT EXPERIENCE")
                .font(Theme.Typography.label)
                .tracking(3)
                .foregroundStyle(Theme.Palette.textTertiary)

            Spacer()

            // Balances the Back button so the title stays visually centered.
            Color.clear.frame(width: 1, height: 1)
        }
    }
}

private struct ExperienceCard: View {
    let experience: BoothExperience
    let action: () -> Void

    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.lg) {
                Image(systemName: experience.symbolName)
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Theme.Palette.optic)
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(experience.title.uppercased())
                        .font(Theme.Typography.control)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(experience.subtitle)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .padding(Theme.Spacing.lg)
            .glassSurface(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous), illumination: pressed ? 0.7 : 0.2)
        }
        .buttonStyle(.plain)
        .scaleEffect(pressed ? 0.98 : 1)
        .animation(Theme.Motion.quick, value: pressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
    }
}
