//
//  BoothProduct.swift
//  photobooth
//
//  What a guest can walk away with, and what that entitles them to. Kept
//  separate from payment (see PaymentProvider.swift): a product can be free
//  under one EventConfiguration and paid under another without either type
//  needing to know about the other's rules.
//

import Foundation

enum BoothProduct: String, Codable, CaseIterable {
    case digitalPhoto
    case loopVideo
    case print4x6
    case digitalAndPrint
}

/// What a guest is actually allowed to receive, independent of how (or
/// whether) they paid for it.
enum Entitlement: String, Codable, Hashable {
    case downloadPhoto
    case downloadLoop
    case printPhoto
}
