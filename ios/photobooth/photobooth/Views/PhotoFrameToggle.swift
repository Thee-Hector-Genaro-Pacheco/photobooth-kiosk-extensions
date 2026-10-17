//
//  PhotoFrameToggle.swift
//  photobooth
//
//  Compact glass control for the guest's in-the-moment NORMAL/BIG 50 choice
//  on the still-photo camera screen — mirrors EffectSelector/SceneSelector's
//  exact visual language (only the selected option illuminates) so it reads
//  as the same kind of control, not a new UI idiom.
//
//  Deliberately two fixed options rather than iterating PhotoFrameCatalog:
//  there is exactly one frame today, and the brief this exists to satisfy
//  specifies this exact literal control ("[ NORMAL ] [ BIG 50 ]"), not a
//  generic N-way frame picker — adding that generalization is a bigger
//  change than this pass calls for.
//

import SwiftUI

struct PhotoFrameToggle: View {
    let selectedFrameID: String?
    let isEnabled: Bool
    let onSelect: (PhotoFrame?) -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            Text("FRAME")
                .font(Theme.Typography.label)
                .tracking(1.6)
                .foregroundStyle(Theme.Palette.textTertiary)

            HStack(spacing: Theme.Spacing.xxs) {
                option(title: "NORMAL", frame: nil)
                option(title: "BIG 50", frame: PhotoFrameCatalog.big50)
            }
            .padding(Theme.Spacing.xxs)
            .glassSurface(Capsule())
            .opacity(isEnabled ? 1 : 0.4)
        }
    }

    private func option(title: String, frame: PhotoFrame?) -> some View {
        let isSelected = selectedFrameID == frame?.id
        return Button {
            onSelect(frame)
        } label: {
            Text(title)
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
