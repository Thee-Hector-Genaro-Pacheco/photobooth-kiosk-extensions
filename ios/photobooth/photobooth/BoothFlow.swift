//
//  BoothFlow.swift
//  photobooth
//
//  Single source of truth for where the guest is in the booth experience.
//  Views read `stage` and call the intent methods below; no navigation
//  booleans (isRecording, showLoopReview, isProcessingLoop, ...) are
//  scattered across views.
//
//  Also orchestrates what happens once a guest accepts their media: persist
//  it (SessionRepository), resolve payment/entitlements (EntitlementResolver
//  + EventPolicy) under the active EventConfiguration, and prepare delivery
//  (QR or a clear "not configured" state) — all after Review, never inside
//  CameraView.
//
//  `eventConfiguration` comes from EventConfigurationStore, not a hardcoded
//  default — if the store has no active event yet, this is `nil` and
//  ContentView shows a configuration-required state rather than the guest
//  flow ever silently running under a fabricated/monetized event.
//

import Observation
import UIKit

/// What the Delivery screen should show. Built once persistence + payment/
/// delivery resolution finish; never mutated afterward.
struct DeliveryOutcome: Equatable {
    var claimURL: URL?
    var deliveryUnavailable: Bool
    var paymentRequired: Bool
    var paymentMessage: String?
    var socialCTA: SocialCTA?
}

@Observable
final class BoothFlow {
    enum Stage: Equatable {
        case ready
        case experienceSelection
        case camera
        case countdown
        case capturingPhoto
        case recordingLoop
        case processingLoop
        case photoReview
        case loopReview
        case persisting
        case delivery
        case complete
    }

    private(set) var stage: Stage = .ready
    private(set) var selectedExperience: BoothExperience = .classic
    /// Glasses is the baseline geometry-verification effect, so it's the
    /// default whenever AR Party is entered.
    var selectedEffect: EffectDefinition = EffectCatalog.glasses
    /// Portal-only; classic means no background replacement. Not reachable
    /// from the Experience Hub this phase (Portal is preserved but hidden —
    /// see BoothExperience), kept only so the Portal pipeline still has a
    /// valid scene if re-enabled later.
    private(set) var selectedScene: PortalScene = .classic
    private(set) var countdownValue: Int = 3
    private(set) var capturedPhoto: UIImage?
    private(set) var capturedLoopURL: URL?
    private(set) var captureError: String?

    /// `nil` until an admin configures an event via EventConfigurationStore.
    private(set) var eventConfiguration: EventConfiguration?
    private(set) var currentSession: BoothSession?
    private(set) var deliveryOutcome: DeliveryOutcome?

    /// Exposed (not private) so the admin editor, presented from ContentView,
    /// can read/write through the same store this flow uses.
    let configurationStore: EventConfigurationStore
    private let sessionRepository: SessionRepository
    private let deliveryService: DigitalDeliveryService

    init(
        configurationStore: EventConfigurationStore = LocalEventConfigurationStore(),
        sessionRepository: SessionRepository = SessionRepository(),
        deliveryService: DigitalDeliveryService = UnconfiguredDeliveryService()
    ) {
        self.configurationStore = configurationStore
        self.sessionRepository = sessionRepository
        self.deliveryService = deliveryService
        self.eventConfiguration = configurationStore.loadActive()
    }

    /// Called after the admin editor saves + activates a configuration.
    func applyUpdatedConfiguration(_ configuration: EventConfiguration) {
        eventConfiguration = configuration
    }

    // MARK: - Navigation

    func startExperienceSelection() {
        guard eventConfiguration != nil else { return }
        stage = .experienceSelection
    }

    func returnToReady() {
        stage = .ready
    }

    func selectExperience(_ experience: BoothExperience) {
        guard stage == .experienceSelection,
              let event = eventConfiguration,
              event.availableExperiences.contains(experience) else { return }
        selectedExperience = experience
        if experience != .arParty {
            selectedEffect = EffectCatalog.glasses
        }
        stage = .camera
    }

    /// "Back" from the camera screen returns to the Hub, not all the way to
    /// Ready — the guest is choosing a different mode, not leaving the booth.
    func exitCamera() {
        stage = .experienceSelection
    }

    func selectEffect(_ effect: EffectDefinition) {
        guard stage == .camera else { return }
        selectedEffect = effect
    }

    func selectScene(_ scene: PortalScene) {
        guard stage == .camera else { return }
        selectedScene = scene
    }

    // MARK: - Countdown / capture

    func beginCountdown() {
        guard stage == .camera else { return }
        countdownValue = 3
        captureError = nil
        stage = .countdown
    }

    /// Advances the countdown by one tick. Returns `true` once it reaches
    /// zero, at which point `stage` moves on to the capture path appropriate
    /// for the active experience and the caller should perform it.
    @discardableResult
    func tickCountdown() -> Bool {
        guard stage == .countdown else { return false }
        if countdownValue > 1 {
            countdownValue -= 1
            return false
        }
        stage = selectedExperience == .loopClip ? .recordingLoop : .capturingPhoto
        return true
    }

    /// Loop recording has stopped; the forward/reverse video is being built.
    func beginProcessingLoop() {
        guard stage == .recordingLoop else { return }
        stage = .processingLoop
    }

    func finishCapture(photo: UIImage) {
        capturedPhoto = photo
        stage = .photoReview
    }

    func finishLoop(url: URL) {
        capturedLoopURL = url
        stage = .loopReview
    }

    func captureFailed(_ message: String) {
        captureError = message
        capturedPhoto = nil
        discardLoopFile()
        stage = .camera
    }

    func retake() {
        capturedPhoto = nil
        discardLoopFile()
        stage = .camera
    }

    // MARK: - Accept media -> persist -> resolve delivery/payment

    func usePhoto() {
        guard stage == .photoReview, let photo = capturedPhoto, let event = eventConfiguration else { return }
        stage = .persisting
        Task { await persistPhoto(photo, event: event) }
    }

    func useLoop() {
        guard stage == .loopReview, let url = capturedLoopURL, let event = eventConfiguration else { return }
        stage = .persisting
        Task { await persistLoop(url, event: event) }
    }

    private func persistPhoto(_ photo: UIImage, event: EventConfiguration) async {
        guard let jpegData = photo.jpegData(compressionQuality: 0.9) else {
            presentDeliveryFailure("The photo could not be prepared.")
            return
        }
        do {
            let resolution = EntitlementResolver.resolve(product: .digitalPhoto, configuration: event)
            var session = makeSession(product: .digitalPhoto, event: event, resolution: resolution)
            try sessionRepository.addMedia(kind: .photo, data: jpegData, fileExtension: "jpg", mimeType: "image/jpeg", to: &session)
            try sessionRepository.save(session)
            currentSession = session
            await resolveDeliveryAndAdvance(session: session, provider: resolution.provider, product: .digitalPhoto, event: event)
        } catch {
            presentDeliveryFailure("The photo could not be saved.")
        }
    }

    private func persistLoop(_ url: URL, event: EventConfiguration) async {
        do {
            let resolution = EntitlementResolver.resolve(product: .loopVideo, configuration: event)
            var session = makeSession(product: .loopVideo, event: event, resolution: resolution)
            try sessionRepository.addMedia(kind: .loopVideo, sourceURL: url, mimeType: "video/quicktime", to: &session)
            try sessionRepository.save(session)
            currentSession = session
            // The temp file was copied into the session directory above; the
            // original in tmp/ is no longer needed.
            try? FileManager.default.removeItem(at: url)
            capturedLoopURL = nil
            await resolveDeliveryAndAdvance(session: session, provider: resolution.provider, product: .loopVideo, event: event)
        } catch {
            presentDeliveryFailure("The loop could not be saved.")
        }
    }

    private func makeSession(product: BoothProduct, event: EventConfiguration, resolution: EntitlementResolver.Resolution) -> BoothSession {
        let claimToken = (try? ClaimTokenGenerator.generate()) ?? UUID().uuidString
        let now = Date()
        return BoothSession(
            id: UUID(),
            eventID: event.id,
            createdAt: now,
            updatedAt: now,
            status: .active,
            selectedExperience: selectedExperience,
            mediaItems: [],
            claimToken: claimToken,
            paymentState: resolution.paymentState,
            entitlements: resolution.entitlements,
            expirationDate: now.addingTimeInterval(event.mediaRetentionPolicy.duration)
        )
    }

    /// Exercises the real PaymentProvider/DigitalDeliveryService boundaries
    /// rather than special-casing on state — a paid product with no
    /// configured provider fails here with a real thrown error, the same way
    /// a future real provider's failure would. `session.paymentState` was
    /// already decided by EntitlementResolver (backed by EventPolicy), so a
    /// sponsored/promotional session can never reach the checkout branch.
    private func resolveDeliveryAndAdvance(session: BoothSession, provider: PaymentProvider, product: BoothProduct, event: EventConfiguration) async {
        if session.paymentState == .pending {
            do {
                _ = try await provider.createCheckout(for: session, products: [product])
            } catch {
                deliveryOutcome = DeliveryOutcome(
                    claimURL: nil,
                    deliveryUnavailable: false,
                    paymentRequired: true,
                    paymentMessage: error.localizedDescription,
                    socialCTA: event.socialCTA
                )
                stage = .delivery
                return
            }
        }

        guard event.digitalDeliveryEnabled else {
            deliveryOutcome = DeliveryOutcome(claimURL: nil, deliveryUnavailable: true, paymentRequired: false, paymentMessage: nil, socialCTA: event.socialCTA)
            stage = .delivery
            return
        }

        do {
            try await deliveryService.prepareDelivery(for: session)
            let url = try deliveryService.claimURL(for: session)
            deliveryOutcome = DeliveryOutcome(claimURL: url, deliveryUnavailable: false, paymentRequired: false, paymentMessage: nil, socialCTA: event.socialCTA)
        } catch {
            deliveryOutcome = DeliveryOutcome(claimURL: nil, deliveryUnavailable: true, paymentRequired: false, paymentMessage: nil, socialCTA: event.socialCTA)
        }
        stage = .delivery
    }

    private func presentDeliveryFailure(_ message: String) {
        deliveryOutcome = DeliveryOutcome(claimURL: nil, deliveryUnavailable: true, paymentRequired: false, paymentMessage: message, socialCTA: nil)
        stage = .delivery
    }

    func completeDelivery() {
        stage = .complete
    }

    func newSession() {
        capturedPhoto = nil
        discardLoopFile()
        captureError = nil
        currentSession = nil
        deliveryOutcome = nil
        selectedEffect = EffectCatalog.glasses
        selectedScene = .classic
        selectedExperience = .classic
        stage = .ready
    }

    /// Temporary Loop media lives in the app sandbox and is never persisted
    /// automatically — discard it whenever it's no longer the active review.
    private func discardLoopFile() {
        if let url = capturedLoopURL {
            try? FileManager.default.removeItem(at: url)
        }
        capturedLoopURL = nil
    }
}
