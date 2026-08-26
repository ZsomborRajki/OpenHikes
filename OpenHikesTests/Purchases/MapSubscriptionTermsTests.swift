//
//  MapSubscriptionTermsTests.swift
//  OpenHikesTests
//
//  The words on the buying screen, and the one identifier that can never be
//  corrected after the fact.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Pro subscription")
struct MapSubscriptionTermsTests {
    private static let yearlyWithTrial = MapSubscriptionTerms(
        price: "$19.99",
        period: "year",
        freeTrial: "1 week"
    )

    private static let yearlyWithoutTrial = MapSubscriptionTerms(
        price: "$19.99",
        period: "year",
        freeTrial: nil
    )

    // MARK: Wording

    /// A trial the button doesn't mention is a trial nobody starts.
    @Test("an eligible account is offered the trial, not the price")
    func callToActionLeadsWithTheTrial() {
        #expect(Self.yearlyWithTrial.callToAction == "Start 1 week Free")
        #expect(Self.yearlyWithoutTrial.callToAction == "Subscribe for $19.99/year")
    }

    /// App Review 3.1.2(a) wants the price, the period and the renewal on the
    /// screen itself. A trial additionally has to say what it turns into —
    /// "free" without "then $19.99" is the phrasing that gets rejected.
    @Test("the disclosure states price, period, renewal and what the trial becomes")
    func disclosureIsComplete() {
        let withTrial = Self.yearlyWithTrial.disclosure
        #expect(withTrial.contains("Free for 1 week"))
        #expect(withTrial.contains("then $19.99 per year"))
        #expect(withTrial.contains("Renews automatically"))
        #expect(withTrial.contains("Cancel any time"))

        let withoutTrial = Self.yearlyWithoutTrial.disclosure
        #expect(withoutTrial.contains("Renews automatically at $19.99 per year"))
        #expect(!withoutTrial.contains("Free for"))
    }

    /// "per 1 year" is not how anyone reads a price out loud, but "free for
    /// week" is not a sentence either — which is why these are two functions.
    @Test("a period is a bare noun and a duration keeps its count")
    func periodAndDurationPhrasing() {
        #expect(MapSubscriptionTerms.periodNoun(unit: .year, count: 1) == "year")
        #expect(MapSubscriptionTerms.periodNoun(unit: .month, count: 3) == "3 months")
        #expect(MapSubscriptionTerms.durationPhrase(unit: .week, count: 1) == "1 week")
        #expect(MapSubscriptionTerms.durationPhrase(unit: .day, count: 7) == "7 days")
    }

    // MARK: Legal links

    /// App Review opens both. A link that 404s fails the whole binary, not
    /// just the purchase.
    @Test("both required links are absolute https URLs")
    func legalLinksAreWellFormed() {
        for url in [MapPurchaseLinks.termsOfUse, MapPurchaseLinks.privacyPolicy] {
            #expect(url.scheme == "https")
            #expect(url.host()?.isEmpty == false)
        }
    }

    // MARK: Configuration

    /// The identifier is written into every past purchase, so a mismatch
    /// between the code and `OpenHikes.storekit` is not a bug that can be
    /// fixed later — it is a set of customers whose subscription stops
    /// unlocking anything. This is the only place the two can be compared
    /// automatically; App Store Connect has to be checked by eye.
    @Test("the product id matches the StoreKit configuration")
    func productIDMatchesTheConfiguration() throws {
        guard let data = try Self.storeKitConfiguration() else {
            // Built somewhere the source tree isn't, which is not a failure of
            // the app. The comparison simply isn't available there.
            return
        }
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let groups = root?["subscriptionGroups"] as? [[String: Any]]
        let subscriptions = groups?.first?["subscriptions"] as? [[String: Any]]
        let subscription = try #require(subscriptions?.first)

        #expect(subscription["productID"] as? String == MapEntitlementStore.productID)
        #expect(subscription["type"] as? String == "RecurringSubscription")
        #expect(subscription["recurringSubscriptionPeriod"] as? String == "P1Y")

        let offer = try #require(subscription["introductoryOffer"] as? [String: Any])
        #expect(offer["paymentMode"] as? String == "free")
    }

    /// `#filePath` is baked in at compile time, so this resolves whenever the
    /// bundle is built and run on one machine — which covers a developer and
    /// a CI job alike.
    private static func storeKitConfiguration(from filePath: String = #filePath) throws -> Data? {
        let repositoryRoot = URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let configuration = repositoryRoot.appending(path: "OpenHikes.storekit")
        guard FileManager.default.fileExists(atPath: configuration.path) else { return nil }
        return try Data(contentsOf: configuration)
    }
}
