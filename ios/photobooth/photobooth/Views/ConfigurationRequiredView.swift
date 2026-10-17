//
//  ConfigurationRequiredView.swift
//  photobooth
//
//  Shown instead of the guest flow when no EventConfiguration exists yet.
//  The app never fabricates or silently activates a default event — an
//  admin has to configure one first.
//

import SwiftUI

struct ConfigurationRequiredView: View {
    let onOpenAdmin: () -> Void

    var body: some View {
        ZStack {
            OpticalBackdrop()

            VStack(spacing: Theme.Spacing.lg) {
                Image(systemName: "gearshape.2")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Theme.Palette.caution)

                Text("EVENT CONFIGURATION REQUIRED")
                    .font(Theme.Typography.label)
                    .tracking(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.Palette.textPrimary)

                Text("No event has been configured on this iPad yet. An administrator needs to set one up before guests can use the booth.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Spacing.xl)

                Button(action: onOpenAdmin) {
                    Label("Configure Event", systemImage: "wrench.and.screwdriver")
                }
                .buttonStyle(.opticalPrimary)
            }
            .padding(Theme.Spacing.xl)
        }
    }
}
