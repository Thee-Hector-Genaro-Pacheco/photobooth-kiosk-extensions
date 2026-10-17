//
//  PrintService.swift
//  photobooth
//
//  Boundary for physical printing — not integrated this phase (no
//  AirPrint/LAN bridge/vendor SDK chosen yet). NoPrinterService is the only
//  implementation: it always reports the printer as unavailable rather than
//  faking a successful print.
//

import Foundation

enum PrintLayout: String, Codable {
    case fourBySix = "4x6"
}

struct PrintJob {
    let sessionID: UUID
    let mediaItemID: UUID
    let layout: PrintLayout
    let copies: Int
}

enum PrintError: LocalizedError {
    case printerUnavailable

    var errorDescription: String? {
        switch self {
        case .printerUnavailable: "No printer is available."
        }
    }
}

protocol PrintService {
    func submit(_ job: PrintJob) async throws
}

struct NoPrinterService: PrintService {
    func submit(_ job: PrintJob) async throws {
        throw PrintError.printerUnavailable
    }
}
