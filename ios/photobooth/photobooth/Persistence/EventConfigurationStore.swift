//
//  EventConfigurationStore.swift
//  photobooth
//
//  Persistent boundary for event configuration — the production runtime
//  must not depend on editing Swift source and rebuilding to change an
//  event. Backed by plain Codable JSON files in Application Support (no
//  database dependency needed at this scale):
//
//    Application Support/PhotoBooth/Events/<event-id>/event.json
//    Application Support/PhotoBooth/active-event.json   (pointer)
//
//  `save(_:)` refuses to persist a configuration that fails EventPolicy
//  validation — invalid configurations (e.g. a sponsored event with a
//  non-zero guest price) are rejected here, not just by the admin UI.
//

import Foundation

enum EventConfigurationError: LocalizedError {
    case invalid([EventConfigurationValidationError])
    case eventNotFound

    var errorDescription: String? {
        switch self {
        case .invalid(let errors):
            errors.compactMap(\.errorDescription).joined(separator: " ")
        case .eventNotFound:
            "That event could not be found."
        }
    }
}

protocol EventConfigurationStore {
    func loadActive() -> EventConfiguration?
    func save(_ configuration: EventConfiguration) throws
    func setActive(_ id: UUID) throws
    func listConfigurations() -> [EventConfiguration]
}

final class LocalEventConfigurationStore: EventConfigurationStore {
    private struct ActivePointer: Codable {
        let eventID: UUID
    }

    private let fileManager = FileManager.default
    private let eventsDirectory: URL
    private let activePointerURL: URL

    init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = appSupport.appendingPathComponent("PhotoBooth", isDirectory: true)
        eventsDirectory = root.appendingPathComponent("Events", isDirectory: true)
        activePointerURL = root.appendingPathComponent("active-event.json")
    }

    func loadActive() -> EventConfiguration? {
        guard let data = try? Data(contentsOf: activePointerURL),
              let pointer = try? JSONDecoder().decode(ActivePointer.self, from: data) else { return nil }
        return listConfigurations().first { $0.id == pointer.eventID }
    }

    func save(_ configuration: EventConfiguration) throws {
        let violations = EventPolicy.validate(configuration)
        guard violations.isEmpty else { throw EventConfigurationError.invalid(violations) }

        let directory = eventsDirectory.appendingPathComponent(configuration.id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(configuration)
        try data.write(to: directory.appendingPathComponent("event.json"), options: .atomic)
    }

    func setActive(_ id: UUID) throws {
        guard listConfigurations().contains(where: { $0.id == id }) else {
            throw EventConfigurationError.eventNotFound
        }
        try fileManager.createDirectory(at: activePointerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(ActivePointer(eventID: id))
        try data.write(to: activePointerURL, options: .atomic)
    }

    func listConfigurations() -> [EventConfiguration] {
        guard let eventDirs = try? fileManager.contentsOfDirectory(at: eventsDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return eventDirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("event.json")) else { return nil }
            return try? decoder.decode(EventConfiguration.self, from: data)
        }
    }
}
