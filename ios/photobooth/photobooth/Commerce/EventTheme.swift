//
//  EventTheme.swift
//  photobooth
//
//  Domain foundation for event-specific branding. Deliberately just data —
//  no frame renderer, no AI generation. Colors are stored as hex strings
//  (never SwiftUI Color) so this stays a portable, validated, Codable value
//  that could be edited by a future admin UI or synced from a backend.
//

import Foundation
import SwiftUI

struct EventTheme: Codable, Equatable {
    var displayTitle: String
    var displaySubtitle: String
    var primaryColorHex: String
    var secondaryColorHex: String
    var accentColorHex: String
    var logoAssetReference: String?
    var framePackReference: String?
    var designNotes: String

    /// Neutral default matching the app's own Optical Glass palette —
    /// intentionally generic, not any client's branding.
    static let none = EventTheme(
        displayTitle: "",
        displaySubtitle: "",
        primaryColorHex: "#050810",
        secondaryColorHex: "#0E1014",
        accentColorHex: "#61E1F2",
        logoAssetReference: nil,
        framePackReference: nil,
        designNotes: ""
    )
}

enum HexColor {
    /// Validates a "#RRGGBB" or "#RRGGBBAA" string (leading `#` optional).
    static func isValid(_ hex: String) -> Bool {
        var value = hex
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6 || value.count == 8 else { return false }
        return value.allSatisfy(\.isHexDigit)
    }
}

extension Color {
    /// Best-effort convenience for previewing theme colors in the admin UI.
    /// Falls back to a neutral gray for an invalid/incomplete hex string
    /// rather than crashing mid-edit.
    init(hex: String) {
        var value = hex
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6 || value.count == 8, let rgba = UInt64(value, radix: 16) else {
            self = .gray
            return
        }
        let hasAlpha = value.count == 8
        let r = Double((rgba >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((rgba >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((rgba >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(rgba & 0xFF) / 255 : 1
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
