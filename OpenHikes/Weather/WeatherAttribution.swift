//
//  WeatherAttribution.swift
//  OpenHikes
//
//  Apple Weather's credits, which are a condition of the WeatherKit
//  entitlement rather than a courtesy.
//
//  WeatherKit's terms require an app that displays its data to show the Apple
//  Weather mark and to link the legal attribution page from the screen
//  presenting that data. This app showed a temperature over the map and
//  nothing else, which risks the entitlement itself as well as App Review.
//
//  Everything here is taken from `WeatherService.attribution` rather than
//  hardcoded. Apple publishes the marks as URLs precisely so they can change
//  without every app shipping a new asset, and a logo checked into this
//  repository would be a copy that silently goes out of date. The one
//  hardcoded URL below is a *fallback*, used only when the service call
//  cannot be made at all — see ``AppleWeatherAttribution/fallbackLegalPageURL``.
//

import Foundation
import os
import WeatherKit

/// The parts of WeatherKit's `WeatherAttribution` this app draws.
///
/// A value of our own rather than the framework type, for the reason
/// ``WeatherSnapshot`` is not `CurrentWeather`: `WeatherAttribution` can only
/// be obtained from a live, entitled, networked call, so nothing — a preview,
/// a test, an offline launch — could stand one up, and the view would be
/// reachable only against the real service.
nonisolated struct WeatherAttributionMarks: Equatable, Sendable {
    /// What the legal link is called when Apple has not supplied its own
    /// wording. Apple's `legalAttributionText` is preferred wherever it is
    /// available, because it is the phrasing the terms were written around.
    static let defaultLinkTitle = "Other data sources"

    let legalPageURL: URL
    /// The wordmark-plus-glyph pair. Combined rather than `squareMarkURL`,
    /// because the combined marks carry the words "Apple Weather" beside the
    /// glyph — which is the attribution — while the square mark is the glyph
    /// alone and needs the wording supplied separately.
    let lightMarkURL: URL
    let darkMarkURL: URL
    let linkTitle: String

    init(
        legalPageURL: URL,
        lightMarkURL: URL,
        darkMarkURL: URL,
        linkTitle: String = Self.defaultLinkTitle
    ) {
        self.legalPageURL = legalPageURL
        self.lightMarkURL = lightMarkURL
        self.darkMarkURL = darkMarkURL
        // An empty string is a real answer from the framework here, and it
        // would render as a link with no text at all — worse than a generic
        // label, because there is nothing left to tap.
        self.linkTitle = linkTitle.isEmpty ? Self.defaultLinkTitle : linkTitle
    }

    init(_ attribution: WeatherAttribution) {
        self.init(
            legalPageURL: attribution.legalPageURL,
            lightMarkURL: attribution.combinedMarkLightURL,
            darkMarkURL: attribution.combinedMarkDarkURL,
            linkTitle: attribution.legalAttributionText
        )
    }

    /// The mark drawn for the scheme it will sit on. Apple ships two because
    /// the wordmark is dark ink on the light one, and picking by hand is the
    /// only way to keep it legible in both.
    func markURL(inDarkMode isDark: Bool) -> URL {
        isDark ? darkMarkURL : lightMarkURL
    }
}

nonisolated enum AppleWeatherAttribution {
    private static let logger = Logger(
        subsystem: "OpenHikes",
        category: "WeatherAttribution"
    )

    /// The wording the terms require beside the data, and the one thing that
    /// is drawn whether or not the marks ever arrive.
    static let serviceName = "Apple Weather"

    // Force-unwrapped deliberately, matching `MapPurchaseLinks`: this is a
    // compile-time constant, and a typo should fail a test here rather than
    // quietly remove a link the entitlement depends on.
    // swiftlint:disable:next force_unwrapping
    static let fallbackLegalPageURL = URL(string: "https://weatherkit.apple.com/legal-attribution.html")!

    /// The credits as WeatherKit reports them, or `nil` when it could not be
    /// asked.
    ///
    /// Failure is expected rather than exceptional: this is a network call
    /// against the same entitlement the forecast needs, so a walker with no
    /// signal — exactly the walker most likely to open this sheet, since a
    /// stale reading is what draws them to it — will get `nil`. The caller
    /// draws the wording and the fallback link in that case; a sheet that
    /// shows nothing at all would satisfy neither the user nor the terms.
    static func marks(from service: WeatherService = .shared) async -> WeatherAttributionMarks? {
        do {
            return WeatherAttributionMarks(try await service.attribution)
        } catch {
            logger.error(
                "Weather attribution unavailable: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
}
