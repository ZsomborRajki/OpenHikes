//
//  MapSubscriptionTerms.swift
//  OpenHikes
//
//  What the paywall has to say out loud. App Review 3.1.2(a) requires a
//  subscription's length, price and renewal behaviour to be on the buying
//  screen itself — not one tap away in a description — so the wording is
//  modelled rather than hard-coded into the view.
//
//  These are plain values with no StoreKit types in them on purpose:
//  `Product.SubscriptionPeriod` cannot be constructed by a test, so phrasing
//  that lived on the StoreKit type could only ever be checked by eye.
//

import Foundation

/// Mirrors `Product.SubscriptionPeriod.Unit` so the wording built from it can
/// be tested without the App Store.
enum SubscriptionPeriodUnit: String, Sendable {
    case day = "day"
    case month = "month"
    case week = "week"
    case year = "year"
}

/// The offer, in the words the paywall shows.
struct MapSubscriptionTerms: Equatable, Sendable {
    /// Localized and storefront-correct, straight from `Product.displayPrice`.
    let price: String
    /// The billing period as a bare noun: `"year"`, `"3 months"`.
    let period: String
    /// The introductory offer's length — `"1 week"` — or `nil` when there is
    /// no free trial, or when this Apple Account has already used the one in
    /// this subscription group. Eligibility is per group and per account and
    /// is spent for good, so a returning subscriber must not be promised it.
    let freeTrial: String?

    /// The buy button's title.
    var callToAction: String {
        guard let freeTrial else { return "Subscribe for \(price)/\(period)" }
        return "Start \(freeTrial) Free"
    }

    /// The renewal disclosure, which has to appear whether or not there is a
    /// trial, and has to say that the trial turns into a charge.
    var disclosure: String {
        let renewal = "Renews automatically at \(price) per \(period) until cancelled."
            + " Cancel any time in Settings on your iPhone."
        guard let freeTrial else { return renewal }
        return "Free for \(freeTrial), then \(price) per \(period). \(renewal)"
    }
}

extension MapSubscriptionTerms {
    /// A billing period as the noun after "per": `"year"`, `"3 months"`.
    ///
    /// The singular drops the count, because "per 1 year" is not how a price
    /// is read aloud.
    static func periodNoun(unit: SubscriptionPeriodUnit, count: Int) -> String {
        count == 1 ? unit.rawValue : "\(count) \(unit.rawValue)s"
    }

    /// A duration on its own: `"1 week"`, `"7 days"`.
    ///
    /// Keeps the count that ``periodNoun(unit:count:)`` drops, because a trial
    /// is a length rather than a rate — "free for week" is not a sentence.
    static func durationPhrase(unit: SubscriptionPeriodUnit, count: Int) -> String {
        count == 1 ? "1 \(unit.rawValue)" : "\(count) \(unit.rawValue)s"
    }
}
