//
//  DeliveryView.swift
//  photobooth
//
//  Shown after Use Photo / Use Loop, once BoothFlow has persisted the
//  session and resolved payment/delivery. Purely a result screen — no
//  commerce controls ever appear during capture (see CameraView).
//

import SwiftUI

struct DeliveryView: View {
    let outcome: DeliveryOutcome
    let onContinue: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var appeared = false

    var body: some View {
        ZStack {
            OpticalBackdrop()

            VStack(spacing: Theme.Spacing.xl) {
                Text("YOUR MEDIA")
                    .font(Theme.Typography.label)
                    .tracking(3)
                    .foregroundStyle(Theme.Palette.textTertiary)

                resultCard

                if let cta = outcome.socialCTA {
                    socialCTAView(cta)
                }

                Button(action: onContinue) {
                    Label("Done", systemImage: "checkmark")
                }
                .buttonStyle(.opticalPrimary)
            }
            .padding(Theme.Spacing.xl)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 12)
        }
        .onAppear {
            withAnimation(Theme.Motion.reveal) { appeared = true }
        }
    }

    @ViewBuilder
    private var resultCard: some View {
        if outcome.paymentRequired {
            InfoCard(
                symbol: "creditcard.trianglebadge.exclamationmark",
                title: "PAYMENT NOT CONFIGURED",
                message: outcome.paymentMessage ?? "An administrator needs to configure a payment provider for this event."
            )
        } else if let url = outcome.claimURL {
            qrCard(url: url)
        } else {
            InfoCard(
                symbol: "wifi.slash",
                title: "DIGITAL DELIVERY NOT CONFIGURED",
                message: outcome.paymentMessage ?? "This is a development build without a delivery backend yet."
            )
        }
    }

    private func qrCard(url: URL) -> some View {
        VStack(spacing: Theme.Spacing.md) {
            if let qrImage = QRCodeService.generateImage(for: url.absoluteString) {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            }
            Text("SCAN TO DOWNLOAD")
                .font(Theme.Typography.label)
                .tracking(2)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .padding(Theme.Spacing.xl)
        .glassSurface(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous), illumination: 0.4)
    }

    private func socialCTAView(_ cta: SocialCTA) -> some View {
        VStack(spacing: Theme.Spacing.xs) {
            Button {
                openURL(cta.profileURL)
            } label: {
                Label("Follow \(cta.displayName)", systemImage: "at")
            }
            .buttonStyle(.opticalSecondary)
            Text(cta.message)
                .font(Theme.Typography.controlSmall)
                .foregroundStyle(Theme.Palette.textTertiary)
                .multilineTextAlignment(.center)
        }
    }
}

private struct InfoCard: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.Palette.caution)
            Text(title)
                .font(Theme.Typography.label)
                .tracking(1.5)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text(message)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: 440)
        .glassSurface(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
    }
}

struct PersistingView: View {
    var body: some View {
        ZStack {
            OpticalBackdrop()
            VStack(spacing: Theme.Spacing.md) {
                ProgressView()
                    .tint(Theme.Palette.optic)
                    .controlSize(.large)
                Text("SAVING")
                    .font(Theme.Typography.label)
                    .tracking(2)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
    }
}
