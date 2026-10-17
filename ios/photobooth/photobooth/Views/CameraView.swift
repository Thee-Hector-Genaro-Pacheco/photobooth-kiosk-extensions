//
//  CameraView.swift
//  photobooth
//
//  Live front-camera screen. Drives CameraModel's lifecycle from view and
//  scene events; all AVFoundation work lives in the Camera layer. Controls
//  are contextual to `flow.selectedExperience` — this view never shows every
//  control for every experience at once.
//

import SwiftUI
import UIKit

struct CameraView: View {
    let camera: CameraModel
    let flow: BoothFlow
    let onExit: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var flashOpacity: Double = 0
    @State private var portalEngine = PortalEngine()
    @State private var loopPipeline = LoopCapturePipeline()
    @State private var isEffectDrawerPresented = false

    private var isLive: Bool { camera.state == .running }
    private var controlsEnabled: Bool { flow.stage == .camera }
    private var isPortalActive: Bool { flow.selectedExperience == .portal }
    private var isLoopExperience: Bool { flow.selectedExperience == .loopClip }
    private var isARPartyExperience: Bool { flow.selectedExperience == .arParty }

    var body: some View {
        ZStack {
            Theme.Palette.void.ignoresSafeArea()

            if isLive {
                Group {
                    if isPortalActive {
                        PortalLiveView(image: portalEngine.compositedImage)
                    } else {
                        CameraPreview(session: camera.captureSession, device: camera.activeDevice)
                    }
                }
                .ignoresSafeArea()
                .transition(.opacity)

                if isARPartyExperience {
                    EffectOverlayView(effect: flow.selectedEffect, faces: camera.trackedFaces)
                        .ignoresSafeArea()
                }
            }

            // Top scrim keeps chrome legible over bright scenes.
            LinearGradient(
                colors: [Color.black.opacity(0.45), .clear],
                startPoint: .top,
                endPoint: .center
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            ViewfinderOverlay(isLive: isLive)
                .padding(.horizontal, Theme.Spacing.xxl)
                .padding(.top, Theme.Spacing.xxxl + Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.xxl)

            stateContent
                .padding(Theme.Spacing.xl)

            if flow.stage == .countdown {
                CountdownOverlay(value: flow.countdownValue)
                    .transition(.opacity)
            }

            if flow.stage == .processingLoop {
                ProcessingLoopView()
                    .transition(.opacity)
            }

            Color.white.opacity(flashOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack {
                topBar
                if let captureError = flow.captureError {
                    CaptureErrorBanner(message: captureError)
                        .padding(.top, Theme.Spacing.sm)
                        .transition(.opacity)
                }
                Spacer()
                if isLive {
                    bottomControls
                        .padding(.bottom, Theme.Spacing.lg)
                }
            }
            .padding(Theme.Spacing.lg)

            if isEffectDrawerPresented {
                effectDrawer
            }
        }
        .animation(Theme.Motion.reveal, value: camera.state)
        .animation(Theme.Motion.standard, value: flow.stage)
        .animation(Theme.Motion.standard, value: isEffectDrawerPresented)
        .task { await camera.start() }
        .onDisappear {
            camera.stop()
            camera.onPortalFrame = nil
            camera.onLoopFrame = nil
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: Task { await camera.start() }
            case .background: camera.stop()
            default: break
            }
        }
        .onAppear { syncPortalWiring() }
        .onChange(of: flow.selectedExperience) { _, _ in syncPortalWiring() }
        .onChange(of: flow.selectedScene) { _, scene in portalEngine.scene = scene }
    }

    /// Wires/unwires the camera's raw-frame tap to PortalEngine so
    /// segmentation only ever runs while Portal is the active experience.
    /// Portal isn't reachable from the Experience Hub this phase, but the
    /// pipeline is preserved and still fully functional if re-enabled.
    private func syncPortalWiring() {
        portalEngine.scene = flow.selectedScene
        if isPortalActive {
            camera.onPortalFrame = { [portalEngine] buffer in
                portalEngine.ingest(buffer)
            }
        } else {
            camera.onPortalFrame = nil
            portalEngine.reset()
        }
    }

    // MARK: - Top bar

    private var modeLabel: String {
        switch flow.selectedExperience {
        case .classic: "CLASSIC"
        case .arParty: "AR PARTY"
        case .loopClip: "LOOP"
        case .portal: "PORTAL"
        }
    }

    private var topBar: some View {
        HStack {
            Button(action: onExit) {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(.opticalSecondary)
            .disabled(!controlsEnabled)
            .opacity(controlsEnabled ? 1 : 0.35)

            Spacer()

            Text(modeLabel)
                .font(Theme.Typography.label)
                .tracking(2)
                .foregroundStyle(Theme.Palette.textTertiary)

            Spacer()

            if isLive {
                if isARPartyExperience, camera.trackedFaces.count >= 2 {
                    StatusIndicator(label: "\(camera.trackedFaces.count) FACES")
                        .transition(.opacity)
                }
                StatusIndicator(label: "LIVE · FRONT")
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Contextual bottom controls

    @ViewBuilder
    private var bottomControls: some View {
        switch flow.selectedExperience {
        case .classic, .portal:
            captureButton
        case .arParty:
            VStack(spacing: Theme.Spacing.md) {
                HStack(spacing: Theme.Spacing.sm) {
                    currentEffectIndicator
                    Button {
                        isEffectDrawerPresented = true
                    } label: {
                        Label("Change Effect", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.opticalSecondary)
                    .disabled(!controlsEnabled)
                    .opacity(controlsEnabled ? 1 : 0.35)
                }
                captureButton
            }
        case .loopClip:
            VStack(spacing: Theme.Spacing.sm) {
                if flow.stage == .camera {
                    Text("Hold still, then move")
                        .font(Theme.Typography.controlSmall)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                if flow.stage == .recordingLoop {
                    LoopRecordingRing()
                } else {
                    recordButton
                }
            }
        }
    }

    private var currentEffectIndicator: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Circle()
                .fill(Theme.Palette.optic)
                .frame(width: 6, height: 6)
            Text(flow.selectedEffect.displayName.uppercased())
                .font(Theme.Typography.label)
                .tracking(1.2)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .glassSurface(Capsule())
    }

    /// Temporary Optical Glass drawer for choosing an AR Party effect —
    /// shown only on demand, dismissed immediately after a selection.
    private var effectDrawer: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { isEffectDrawerPresented = false }

            VStack {
                Spacer()
                VStack(spacing: Theme.Spacing.md) {
                    Text("CHANGE EFFECT")
                        .font(Theme.Typography.label)
                        .tracking(2)
                        .foregroundStyle(Theme.Palette.textTertiary)
                    EffectSelector(selectedID: flow.selectedEffect.id, isEnabled: true) { effect in
                        flow.selectEffect(effect)
                        isEffectDrawerPresented = false
                    }
                }
                .padding(Theme.Spacing.lg)
                .glassSurface(RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous), illumination: 0.3)
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.bottom, Theme.Spacing.xxl)
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: - Photo capture control

    private var captureButton: some View {
        Button(action: startCountdownAndCapture) {
            ZStack {
                Circle()
                    .stroke(Theme.Palette.textPrimary.opacity(0.8), lineWidth: Theme.Stroke.reticle)
                    .frame(width: 76, height: 76)
                Circle()
                    .fill(Theme.Palette.textPrimary)
                    .frame(width: 62, height: 62)
            }
            .opticalGlow(intensity: controlsEnabled ? 0.55 : 0)
        }
        .buttonStyle(.plain)
        .disabled(!controlsEnabled)
        .opacity(controlsEnabled ? 1 : 0.35)
        .accessibilityLabel("Capture")
    }

    // MARK: - Loop record control

    private var recordButton: some View {
        Button(action: startCountdownAndCapture) {
            ZStack {
                Circle()
                    .stroke(Theme.Palette.optic.opacity(0.75), lineWidth: Theme.Stroke.reticle)
                    .frame(width: 76, height: 76)
                Circle()
                    .fill(Theme.Palette.spectral.opacity(0.18))
                    .frame(width: 62, height: 62)
                Circle()
                    .fill(Theme.Palette.optic)
                    .frame(width: 18, height: 18)
            }
            .opticalGlow(intensity: controlsEnabled ? 0.6 : 0)
        }
        .buttonStyle(.plain)
        .disabled(!controlsEnabled)
        .opacity(controlsEnabled ? 1 : 0.35)
        .accessibilityLabel("Record Loop")
    }

    /// Drives the 3-2-1 countdown, then performs the capture appropriate to
    /// the active experience. Runs entirely off BoothFlow's stage so the
    /// rest of the view just reacts to state rather than tracking timers.
    private func startCountdownAndCapture() {
        guard controlsEnabled else { return }
        flow.beginCountdown()
        Task {
            while true {
                try? await Task.sleep(for: .seconds(1))
                if flow.tickCountdown() { break }
            }
            if isLoopExperience {
                await performLoopRecording()
            } else {
                triggerCaptureFlash()
                await performCapture()
            }
        }
    }

    private func triggerCaptureFlash() {
        withAnimation(.easeOut(duration: 0.06)) { flashOpacity = 0.9 }
        withAnimation(.easeOut(duration: 0.4).delay(0.06)) { flashOpacity = 0 }
    }

    /// Captures a still, then composites the Portal scene (if any) and, only
    /// for AR Party, the active AR effect — Classic capture stays clean even
    /// though `selectedEffect` still holds whatever was last chosen.
    private func performCapture() async {
        guard let raw = await camera.capturePhoto() else {
            flow.captureFailed("The photo could not be captured.")
            return
        }
        let applyAREffect = isARPartyExperience
        let effect = flow.selectedEffect
        let scene = flow.selectedScene
        let composited = await withCheckedContinuation { (continuation: CheckedContinuation<UIImage, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let sceneApplied = PortalCompositor.compositeStill(scene: scene, into: raw)
                let final = applyAREffect ? EffectCompositor.composite(effect: effect, into: sceneApplied) : sceneApplied
                continuation.resume(returning: final)
            }
        }
        flow.finishCapture(photo: composited)
    }

    /// Records ~2 seconds of camera frames (clean feed — see the file-level
    /// comment on LoopCapturePipeline for why AR compositing isn't applied
    /// here yet), then builds the forward/reverse loop off the main actor.
    private func performLoopRecording() async {
        loopPipeline.startRecording()
        try? await Task.sleep(for: .seconds(2))
        loopPipeline.stopRecording()
        flow.beginProcessingLoop()

        let pipeline = loopPipeline
        let result: Result<URL, Error> = await withCheckedContinuation { continuation in
            pipeline.buildLoopVideo(fps: 15) { result in
                continuation.resume(returning: result)
            }
        }
        switch result {
        case .success(let url):
            flow.finishLoop(url: url)
        case .failure:
            flow.captureFailed("The loop could not be created.")
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch camera.state {
        case .running:
            EmptyView()
        case .idle, .starting:
            CameraProgressView(message: "Starting camera")
        case .requestingAccess:
            CameraProgressView(message: "Waiting for camera access")
        case .denied:
            CameraNoticeView(
                symbol: "video.slash",
                title: "Camera access is off",
                message: "Allow Photo Booth to use the camera in Settings, then return here."
            ) {
                Button("Open Settings", action: openSettings)
                    .buttonStyle(.opticalPrimary)
                Button("Back", action: onExit)
                    .buttonStyle(.opticalSecondary)
            }
        case .restricted:
            CameraNoticeView(
                symbol: "lock",
                title: "Camera is restricted",
                message: "This iPad's restrictions or device management prevent camera use. An administrator can change this."
            ) {
                Button("Back", action: onExit)
                    .buttonStyle(.opticalSecondary)
            }
        case .failed(let message):
            CameraNoticeView(
                symbol: "exclamationmark.triangle",
                title: "Camera unavailable",
                message: message
            ) {
                Button("Try Again") { Task { await camera.start() } }
                    .buttonStyle(.opticalPrimary)
                Button("Back", action: onExit)
                    .buttonStyle(.opticalSecondary)
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// ~2-second circular progress shown while Loop is recording — visually
/// distinct from the still-photo capture button and the idle record ring.
private struct LoopRecordingRing: View {
    @State private var progress: CGFloat = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.Palette.hairline, lineWidth: 4)
                .frame(width: 76, height: 76)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Theme.Palette.optic, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 76, height: 76)
                .opticalGlow(intensity: 0.7)
        }
        .onAppear {
            withAnimation(.linear(duration: 2.0)) { progress = 1.0 }
        }
        .accessibilityLabel("Recording")
    }
}

private struct ProcessingLoopView: View {
    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            ProgressView()
                .tint(Theme.Palette.optic)
                .controlSize(.large)
            Text("BUILDING LOOP")
                .font(Theme.Typography.label)
                .tracking(2)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .padding(Theme.Spacing.xl)
        .glassSurface(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }
}

private struct CaptureErrorBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Theme.Palette.caution)
            Text(message)
                .font(Theme.Typography.controlSmall)
                .foregroundStyle(Theme.Palette.textPrimary)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .glassSurface(Capsule())
    }
}

private struct CameraProgressView: View {
    let message: String

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            ProgressView()
                .tint(Theme.Palette.optic)
                .controlSize(.large)
            Text(message.uppercased())
                .font(Theme.Typography.label)
                .tracking(2)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .transition(.opacity)
    }
}

private struct CameraNoticeView<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.Palette.caution)

            VStack(spacing: Theme.Spacing.xs) {
                Text(title)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(message)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: Theme.Spacing.sm) {
                actions
            }
            .padding(.top, Theme.Spacing.xs)
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: 520)
        .glassSurface(RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }
}
