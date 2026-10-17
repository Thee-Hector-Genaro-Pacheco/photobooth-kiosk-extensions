//
//  EventGalleryView.swift
//  photobooth
//
//  Local, on-device gallery of this event's already-accepted media. Reads
//  straight from SessionRepository/BoothSession/MediaItem — the exact same
//  on-disk store BoothFlow itself writes to — rather than a second media
//  database. Never depends on network: thumbnails and full previews are
//  always loaded from the local file already persisted during capture.
//
//  Per-item delivery state (QR / retry) reuses the existing
//  DigitalDeliveryService protocol and BoothSession.remoteDelivery exactly
//  as BoothFlow does, but never touches BoothFlow's own in-memory
//  stage/currentSession — this view can be opened from Ready while a
//  completely unrelated guest session could in principle be active, so it
//  only ever reads/writes its own local BoothSession copies through
//  SessionRepository, never BoothFlow's state machine.
//

import AVFoundation
import ImageIO
import SwiftUI

/// One piece of locally persisted guest media, scoped to a single
/// BoothSession.
private struct GalleryEntry: Identifiable {
    let session: BoothSession
    let media: MediaItem
    let fileURL: URL
    var id: UUID { media.id }
}

struct EventGalleryView: View {
    let event: EventConfiguration
    let onReturnToBooth: () -> Void

    @State private var entries: [GalleryEntry] = []
    @State private var selectedEntry: GalleryEntry?
    @State private var appeared = false
    @State private var inactivityTask: Task<Void, Never>?

    private let repository = SessionRepository()
    private let deliveryService = DeliveryServiceFactory.makeDefault()

    /// No complex idle-activity tracking — mirrors the same shape as
    /// ContentView's abandoned-session reset: a flat timeout, restarted on
    /// the gallery's own screen transitions (open, and entering/leaving the
    /// fullscreen preview), so a guest actively looking at a photo isn't
    /// about to be yanked out mid-glance, but simply leaving the booth on
    /// the grid doesn't strand it either.
    private static let inactivityTimeout: Duration = .seconds(75)

    var body: some View {
        ZStack {
            OpticalBackdrop()

            VStack(spacing: Theme.Spacing.lg) {
                header

                if entries.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.lg)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            loadEntries()
            restartInactivityTimer()
            withAnimation(Theme.Motion.reveal) { appeared = true }
        }
        .onDisappear {
            inactivityTask?.cancel()
        }
        .onChange(of: selectedEntry?.id) { _, _ in restartInactivityTimer() }
        .fullScreenCover(item: $selectedEntry) { entry in
            GalleryItemDetailView(
                entry: entry,
                deliveryService: deliveryService,
                onClose: { selectedEntry = nil },
                onSessionUpdated: { updated in applyUpdatedSession(updated) }
            )
        }
    }

    private var header: some View {
        HStack {
            Button(action: onReturnToBooth) {
                Label("Booth", systemImage: "chevron.left")
            }
            .buttonStyle(.opticalSecondary)

            Spacer()

            Text("EVENT GALLERY")
                .font(Theme.Typography.label)
                .tracking(3)
                .foregroundStyle(Theme.Palette.textTertiary)

            Spacer()

            // Balances the Back button so the title stays visually centered.
            Color.clear.frame(width: 1, height: 1)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.Palette.textTertiary)
            Text("No photos yet")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 170, maximum: 230), spacing: Theme.Spacing.md)],
                spacing: Theme.Spacing.md
            ) {
                ForEach(entries) { entry in
                    GalleryThumbnailCell(entry: entry)
                        .onTapGesture { selectedEntry = entry }
                }
            }
            .padding(.bottom, Theme.Spacing.xl)
        }
        .scrollIndicators(.hidden)
    }

    /// Scoped to this event only via the already-persisted `eventID` on
    /// each session (the same identifier BoothFlow stamps onto every
    /// BoothSession at creation) — no new metadata, no cross-event mixing.
    /// Scanning disk happens off the main actor so opening the gallery
    /// never janks, even as a venue accumulates many past events over time.
    private func loadEntries() {
        let eventID = event.id
        let repo = repository
        Task.detached(priority: .userInitiated) {
            let sessions = repo.allSessions().filter { $0.eventID == eventID }
            let built = sessions
                .flatMap { session in
                    session.mediaItems.map { item in
                        GalleryEntry(session: session, media: item, fileURL: repo.resolvedURL(for: item, in: session))
                    }
                }
                .sorted { $0.media.createdAt > $1.media.createdAt }
            await MainActor.run { entries = built }
        }
    }

    private func applyUpdatedSession(_ updated: BoothSession) {
        entries = entries.map { entry in
            guard entry.session.id == updated.id else { return entry }
            return GalleryEntry(session: updated, media: entry.media, fileURL: entry.fileURL)
        }
    }

    private func restartInactivityTimer() {
        inactivityTask?.cancel()
        inactivityTask = Task {
            try? await Task.sleep(for: Self.inactivityTimeout)
            guard !Task.isCancelled else { return }
            onReturnToBooth()
        }
    }
}

// MARK: - Grid cell

private struct GalleryThumbnailCell: View {
    let entry: GalleryEntry

    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(Theme.Palette.surface)

            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ProgressView()
                    .tint(Theme.Palette.optic)
            }

            if entry.media.kind == .loopVideo {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.white.opacity(0.9))
                            .shadow(radius: 3)
                            .padding(Theme.Spacing.xs)
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .glassSurface(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .task(id: entry.id) {
            thumbnail = await GalleryThumbnailLoader.thumbnail(for: entry.media.kind, url: entry.fileURL, maxDimension: 320)
        }
    }
}

/// Downsampled thumbnails only — never decodes a full-resolution photo or
/// loads a whole video file into memory just to show a grid cell. Each call
/// is independent and cancellable (via the caller's `.task(id:)`), so a
/// fast-scrolling grid never accumulates unbounded in-flight work.
private enum GalleryThumbnailLoader {
    static func thumbnail(for kind: MediaItem.Kind, url: URL, maxDimension: CGFloat) async -> UIImage? {
        await Task.detached(priority: .utility) {
            switch kind {
            case .photo: photoThumbnail(url: url, maxDimension: maxDimension)
            case .loopVideo: videoThumbnail(url: url, maxDimension: maxDimension)
            }
        }.value
    }

    private static func photoThumbnail(url: URL, maxDimension: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private static func videoThumbnail(url: URL, maxDimension: CGFloat) -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Fullscreen item detail

private struct GalleryItemDetailView: View {
    let entry: GalleryEntry
    let deliveryService: DigitalDeliveryService
    let onClose: () -> Void
    let onSessionUpdated: (BoothSession) -> Void

    @State private var session: BoothSession
    @State private var isRetrying = false
    @State private var retryError: String?
    private let repository = SessionRepository()

    init(entry: GalleryEntry, deliveryService: DigitalDeliveryService, onClose: @escaping () -> Void, onSessionUpdated: @escaping (BoothSession) -> Void) {
        self.entry = entry
        self.deliveryService = deliveryService
        self.onClose = onClose
        self.onSessionUpdated = onSessionUpdated
        _session = State(initialValue: entry.session)
    }

    var body: some View {
        ZStack {
            OpticalBackdrop()

            VStack(spacing: Theme.Spacing.lg) {
                HStack {
                    Button(action: onClose) {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(.opticalSecondary)
                    Spacer()
                }

                Spacer(minLength: 0)
                mediaPreview
                Spacer(minLength: 0)

                deliverySection
            }
            .padding(Theme.Spacing.xl)
        }
    }

    @ViewBuilder
    private var mediaPreview: some View {
        switch entry.media.kind {
        case .photo:
            if let image = UIImage(contentsOfFile: entry.fileURL.path) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
                    .glassSurface(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous), illumination: 0.3)
            } else {
                unavailableMediaCard
            }
        case .loopVideo:
            LoopingVideoPlayer(url: entry.fileURL)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
                .glassSurface(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous), illumination: 0.3)
        }
    }

    private var unavailableMediaCard: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "photo")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.Palette.caution)
            Text("This file is no longer available on this iPad.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Spacing.xl)
        .glassSurface(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
    }

    /// Mirrors the two states the brief calls for, nothing finer-grained:
    /// delivery already `.ready` → show the real claim QR (never a second
    /// claim, never a link to a local file); anything else → an honest
    /// "not available yet" plus an optional retry that reuses the same
    /// DigitalDeliveryService protocol BoothFlow's own delivery uses.
    @ViewBuilder
    private var deliverySection: some View {
        switch session.remoteDelivery.status {
        case .ready:
            if let url = try? deliveryService.claimURL(for: session) {
                qrCard(url: url)
            } else {
                Text("Delivery link unavailable.")
                    .font(Theme.Typography.controlSmall)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        default:
            VStack(spacing: Theme.Spacing.sm) {
                Text("UPLOAD NOT AVAILABLE YET")
                    .font(Theme.Typography.label)
                    .tracking(1.5)
                    .foregroundStyle(Theme.Palette.textSecondary)

                if isRetrying {
                    ProgressView().tint(Theme.Palette.optic)
                } else {
                    Button(action: retryDelivery) {
                        Label("Retry Delivery", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.opticalSecondary)
                }

                if let retryError {
                    Text(retryError)
                        .font(Theme.Typography.controlSmall)
                        .foregroundStyle(Theme.Palette.caution)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    private func qrCard(url: URL) -> some View {
        VStack(spacing: Theme.Spacing.md) {
            if let qrImage = QRCodeService.generateImage(for: url.absoluteString) {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 200, height: 200)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            }
            Text("SCAN TO DOWNLOAD")
                .font(Theme.Typography.label)
                .tracking(2)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .padding(Theme.Spacing.lg)
        .glassSurface(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous), illumination: 0.4)
    }

    /// Re-runs the same DigitalDeliveryService.prepareDelivery this
    /// session's original delivery attempt used, against this session's
    /// already-existing claimToken — never a second/new claim. Writes
    /// results only through SessionRepository, never through BoothFlow's
    /// in-memory stage/currentSession, since an unrelated guest could be
    /// mid-flow elsewhere in the app while this runs.
    private func retryDelivery() {
        guard !isRetrying else { return }
        isRetrying = true
        retryError = nil

        var updated = session
        updated.remoteDelivery.status = .preparing
        updated.remoteDelivery.lastError = nil
        updated.remoteDelivery.updatedAt = Date()
        updated.updatedAt = Date()
        try? repository.save(updated)
        session = updated
        onSessionUpdated(updated)

        Task {
            do {
                try await deliveryService.prepareDelivery(for: updated)
                var finished = updated
                finished.remoteDelivery.status = .ready
                finished.remoteDelivery.lastError = nil
                finished.remoteDelivery.updatedAt = Date()
                finished.status = .delivered
                finished.updatedAt = Date()
                try? repository.save(finished)
                session = finished
                isRetrying = false
                onSessionUpdated(finished)
            } catch {
                var failed = updated
                failed.remoteDelivery.status = .failed
                failed.remoteDelivery.lastError = error.localizedDescription
                failed.remoteDelivery.updatedAt = Date()
                failed.updatedAt = Date()
                try? repository.save(failed)
                session = failed
                isRetrying = false
                retryError = "We couldn't upload this media. Check the connection and try again."
                onSessionUpdated(failed)
            }
        }
    }
}
