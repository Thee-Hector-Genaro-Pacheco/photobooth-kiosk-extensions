//
//  ContentView.swift
//  photobooth
//
//  Created by Hector Pacheco on 9/24/26.
//

import SwiftUI

struct ContentView: View {
    @State private var flow = BoothFlow()
    @State private var camera = CameraModel()
    @State private var isAdminPresented = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Theme.Palette.void.ignoresSafeArea()

            if let event = flow.eventConfiguration {
                switch flow.stage {
                case .ready:
                    ReadyView(authorization: camera.authorization) { flow.startExperienceSelection() }
                        // Hidden admin entry point — no guest-facing affordance,
                        // no authentication yet (explicitly deferred).
                        .onLongPressGesture(minimumDuration: 1.5) { isAdminPresented = true }
                        .transition(.opacity)
                case .experienceSelection:
                    ExperienceHubView(
                        availableExperiences: event.availableExperiences,
                        onSelect: { flow.selectExperience($0) },
                        onBack: { flow.returnToReady() }
                    )
                    .transition(.opacity)
                case .camera, .countdown, .capturingPhoto, .recordingLoop, .processingLoop:
                    CameraView(camera: camera, flow: flow) {
                        flow.exitCamera()
                    }
                    .transition(.opacity)
                case .photoReview:
                    if let photo = flow.capturedPhoto {
                        ReviewView(image: photo, onRetake: flow.retake, onUsePhoto: flow.usePhoto)
                            .transition(.opacity)
                    }
                case .loopReview:
                    if let url = flow.capturedLoopURL {
                        LoopReviewView(url: url, onRetake: flow.retake, onUseLoop: flow.useLoop)
                            .transition(.opacity)
                    }
                case .persisting:
                    PersistingView()
                        .transition(.opacity)
                case .delivery:
                    if let outcome = flow.deliveryOutcome {
                        DeliveryView(outcome: outcome, onContinue: flow.completeDelivery)
                            .transition(.opacity)
                    }
                case .complete:
                    CompleteView(onNewSession: flow.newSession)
                        .transition(.opacity)
                }
            } else {
                ConfigurationRequiredView(onOpenAdmin: { isAdminPresented = true })
                    .transition(.opacity)
            }
        }
        .animation(Theme.Motion.standard, value: flow.stage)
        .onChange(of: flow.stage) { _, _ in camera.refreshAuthorization() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { camera.refreshAuthorization() }
        }
        .sheet(isPresented: $isAdminPresented) {
            AdminEventEditorView(
                store: flow.configurationStore,
                current: flow.eventConfiguration,
                onSaved: { updated in
                    flow.applyUpdatedConfiguration(updated)
                    isAdminPresented = false
                },
                onCancel: { isAdminPresented = false }
            )
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }
}

#Preview {
    ContentView()
}
