//
//  SceneSelector.swift
//  photobooth
//
//  Compact glass control for choosing the Portal background scene. Mirrors
//  EffectSelector's visual language — only the selected scene illuminates.
//

import SwiftUI

struct SceneSelector: View {
    let selectedID: String
    let isEnabled: Bool
    let onSelect: (PortalScene) -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            ForEach(PortalScene.allCases) { scene in
                let isSelected = scene.id == selectedID
                Button {
                    onSelect(scene)
                } label: {
                    Text(scene.displayName.uppercased())
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
