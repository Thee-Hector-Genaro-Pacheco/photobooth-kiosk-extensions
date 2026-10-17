//
//  EffectSelector.swift
//  photobooth
//
//  Compact glass control for choosing the live AR effect. Only the selected
//  option is illuminated — the row itself stays quiet.
//

import SwiftUI

struct EffectSelector: View {
    let selectedID: String
    let isEnabled: Bool
    let onSelect: (EffectDefinition) -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            ForEach(EffectCatalog.all) { effect in
                let isSelected = effect.id == selectedID
                Button {
                    onSelect(effect)
                } label: {
                    Text(effect.displayName.uppercased())
                        .font(Theme.Typography.controlSmall)
                        .tracking(1)
                        .foregroundStyle(isSelected ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                        .padding(.horizontal, Theme.Spacing.md - Theme.Spacing.xxs)
                        .padding(.vertical, Theme.Spacing.sm - Theme.Spacing.xxs)
                        .frame(minHeight: 40)
                        .glassSurface(Capsule(), illumination: isSelected ? 0.8 : 0)
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
            }
        }
        .padding(Theme.Spacing.xxs)
        .glassSurface(Capsule())
        .opacity(isEnabled ? 1 : 0.4)
        .animation(Theme.Motion.quick, value: selectedID)
    }
}
