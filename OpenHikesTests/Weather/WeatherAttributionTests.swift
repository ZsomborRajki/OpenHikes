//
//  WeatherAttributionTests.swift
//  OpenHikesTests
//

import Foundation
@testable import OpenHikes
import Testing

/// Apple Weather's credits, which are a term of the WeatherKit entitlement
/// rather than a nicety — the sheet has to say "Apple Weather" and offer the
/// legal link whether or not the marks ever arrive over the network.
@Suite("Weather attribution")
struct WeatherAttributionTests {
    // swiftlint:disable force_unwrapping
    private let legal = URL(string: "https://example.invalid/legal")!
    private let light = URL(string: "https://example.invalid/light.png")!
    private let dark = URL(string: "https://example.invalid/dark.png")!
    // swiftlint:enable force_unwrapping

    @Test("the mark follows the colour scheme it is drawn on")
    func marksFollowColorScheme() {
        let marks = WeatherAttributionMarks(
            legalPageURL: legal,
            lightMarkURL: light,
            darkMarkURL: dark
        )

        #expect(marks.markURL(inDarkMode: false) == light)
        #expect(marks.markURL(inDarkMode: true) == dark)
    }

    /// `legalAttributionText` is a non-optional `String` on the framework
    /// type, so "no wording" arrives as an empty one — which would render as a
    /// link with nothing to tap.
    @Test("an empty link title falls back to a readable one")
    func emptyLinkTitleFallsBack() {
        let named = WeatherAttributionMarks(
            legalPageURL: legal,
            lightMarkURL: light,
            darkMarkURL: dark,
            linkTitle: "Other data sources for this forecast"
        )
        let unnamed = WeatherAttributionMarks(
            legalPageURL: legal,
            lightMarkURL: light,
            darkMarkURL: dark,
            linkTitle: ""
        )

        #expect(named.linkTitle == "Other data sources for this forecast")
        #expect(unnamed.linkTitle == WeatherAttributionMarks.defaultLinkTitle)
        #expect(!WeatherAttributionMarks.defaultLinkTitle.isEmpty)
    }

    /// The floor the sheet draws when the attribution call fails, which is the
    /// likeliest case for the walker most likely to open it — no signal is
    /// both why the reading went stale and why the marks cannot be fetched.
    @Test("the fallback credits satisfy the terms on their own")
    func fallbackCreditsAreComplete() {
        #expect(AppleWeatherAttribution.serviceName == "Apple Weather")
        #expect(
            AppleWeatherAttribution.fallbackLegalPageURL.absoluteString
                == "https://weatherkit.apple.com/legal-attribution.html"
        )
    }
}
