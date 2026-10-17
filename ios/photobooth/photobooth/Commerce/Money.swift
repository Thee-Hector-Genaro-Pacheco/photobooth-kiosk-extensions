//
//  Money.swift
//  photobooth
//
//  Integer minor-unit money type. Never use Float/Double for currency —
//  binary floating point can't represent amounts like $0.10 exactly, which
//  is exactly the kind of bug that shows up as a wrong charge later.
//

import Foundation

struct Money: Codable, Equatable, Hashable {
    let amountInMinorUnits: Int
    let currencyCode: String

    static func free(currencyCode: String = "USD") -> Money {
        Money(amountInMinorUnits: 0, currencyCode: currencyCode)
    }

    var isFree: Bool { amountInMinorUnits <= 0 }

    /// Locale-appropriate display string, e.g. "$3.00".
    var formatted: String {
        let decimalAmount = Decimal(amountInMinorUnits) / 100
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        return formatter.string(from: decimalAmount as NSDecimalNumber) ?? "\(currencyCode) \(decimalAmount)"
    }
}
