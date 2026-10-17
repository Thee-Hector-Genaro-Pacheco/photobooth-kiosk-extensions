//
//  CountdownToggle.swift
//  photobooth
//
//  Compact glass control for the guest's TIMER choice (5s / 10s) on the
//  camera screen — mirrors PhotoFrameToggle's exact visual language (same
//  capsule row, same illumination-on-selection) so the two controls read
//  as a matched set.
//

import SwiftUI

struct CountdownToggle: View {
    let selectedSeconds: Int
    let isEnabled: Bool
    let onSelect: (Int) -> Void

    private static let options = [5, 10]

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            Text("TIMER")
                .font(Theme.Typography.label)
                .tracking(1.6)
                .foregroundStyle(Theme.Palette.textTertiary)

            HStack(spacing: Theme.Spacing.xxs) {
                ForEach(Self.options, id: \.self) { seconds in
                    option(seconds: seconds)
                }
            }
            .padding(Theme.Spacing.xxs)
            .glassSurface(Capsule())
            .opacity(isEnabled ? 1 : 0.4)
        }
    }

    private func option(seconds: Int) -> some View {
        let isSelected = selectedSeconds == seconds
        return Button {
            onSelect(seconds)
        } label: {
            Text("\(seconds) SEC")
                .font(Theme.Typography.controlSmall)
                .tracking(1)
                .foregroundStyle(isSelected ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                .padding(.horizontal, Theme.Spacing.md - Theme.Spacing.xxs)
                .padding(.vertical, Theme.Spacing.sm - Theme.Spacing.xxs)
                .frame(minHeight: 44)
                .glassSurface(Capsule(), illumination: isSelected ? 0.8 : 0)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}
