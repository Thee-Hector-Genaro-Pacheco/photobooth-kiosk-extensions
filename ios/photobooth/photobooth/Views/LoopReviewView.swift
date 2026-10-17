//
//  LoopReviewView.swift
//  photobooth
//
//  Plays the captured Loop back gaplessly (AVQueuePlayer + AVPlayerLooper —
//  the native seamless-loop mechanism) with the same Retake/accept pattern
//  as the still-photo review screen.
//

import AVFoundation
import SwiftUI

struct LoopReviewView: View {
    let url: URL
    let onRetake: () -> Void
    let onUseLoop: () -> Void

    @State private var appeared = false

    var body: some View {
        ZStack {
            OpticalBackdrop()

            VStack(spacing: Theme.Spacing.xl) {
                Text("REVIEW LOOP")
                    .font(Theme.Typography.label)
                    .tracking(3)
                    .foregroundStyle(Theme.Palette.textTertiary)

                LoopingVideoPlayer(url: url)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
                    .glassSurface(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous), illumination: 0.3)
                    .padding(.horizontal, Theme.Spacing.xl)

                HStack(spacing: Theme.Spacing.md) {
                    Button(action: onRetake) {
                        Label("Retake", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.opticalSecondary)

                    Button(action: onUseLoop) {
                        Label("Use Loop", systemImage: "checkmark")
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

private struct LoopingVideoPlayer: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> LoopingPlayerView {
        LoopingPlayerView(url: url)
    }

    func updateUIView(_ uiView: LoopingPlayerView, context: Context) {}
}

final class LoopingPlayerView: UIView {
    private let queuePlayer = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private let playerLayer = AVPlayerLayer()

    init(url: URL) {
        super.init(frame: .zero)
        let item = AVPlayerItem(url: url)
        playerLayer.player = queuePlayer
        playerLayer.videoGravity = .resizeAspect
        layer.addSublayer(playerLayer)
        looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        queuePlayer.play()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}
