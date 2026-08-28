//
//  TrailWidgetMetricTests.swift
//  OpenHikesSharedTests
//
//  The stat chips are the widget's only elevation reporting, and they are
//  built in this package precisely so the app and the extension cannot round
//  or order them differently. These pin the parts a rendered widget can't be
//  asked about from a test: which chips are chosen, in what order, and how
//  each number is written.
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Widget number formatting")
struct WidgetFormatTests {
    private static let metric = Locale(identifier: "de_DE")
    private static let imperial = Locale(identifier: "en_US")

    /// The whole reason elevation doesn't reuse the length formatter: `.road`
    /// and `.general` both promote a four-figure height to kilometres, and a
    /// 1,250 m summit is not "1.2 km" high.
    @Test("a high summit stays in metres rather than becoming kilometres")
    func elevationIsNeverPromotedToKilometres() {
        let formatted = WidgetFormat.elevation(meters: 1250, locale: Self.metric)
        #expect(formatted.contains("1"))
        #expect(!formatted.contains("km"))
    }

    @Test("elevation follows the locale's measurement system")
    func elevationFollowsTheLocale() {
        #expect(WidgetFormat.elevation(meters: 620, locale: Self.metric).contains("m"))

        let feet = WidgetFormat.elevation(meters: 620, locale: Self.imperial)
        #expect(feet.contains("ft"))
        #expect(!feet.contains(" m"))
    }

    /// Whole units: a chip is a few characters wide, and "2,033.5 ft" of
    /// climb is false precision on a barometer's word.
    @Test("elevation is rounded to whole units")
    func elevationIsRounded() {
        #expect(!WidgetFormat.elevation(meters: 620.4, locale: Self.metric).contains(","))
        #expect(!WidgetFormat.elevation(meters: 620.4, locale: Self.imperial).contains("."))
    }

    @Test("speed follows the locale's measurement system")
    func speedFollowsTheLocale() {
        #expect(WidgetFormat.speed(metersPerSecond: 1.2, locale: Self.metric).contains("km/h"))
        #expect(WidgetFormat.speed(metersPerSecond: 1.2, locale: Self.imperial).contains("mph"))
    }

    /// The status line and the chips have to agree, which they only do while
    /// both go through here.
    @Test("the status line's distance comes from the shared length formatter")
    func statusLineUsesTheSharedFormatter() {
        let snapshot = SharedTrailSnapshot(
            hikeID: UUID(),
            title: "Ridge Loop",
            tintHex: "#34C759FF",
            totalDistanceMeters: 4200,
            polyline: []
        )
        #expect(snapshot.statusText == WidgetFormat.length(meters: 4200))
    }
}

@Suite("Trail widget metrics")
struct TrailWidgetMetricTests {
    private static let locale = Locale(identifier: "de_DE")

    private static func snapshot(
        gain: Double? = 620,
        loss: Double? = 580,
        high: Double? = 900,
        low: Double? = 600,
        liveElevation: Double? = nil
    ) -> SharedTrailSnapshot {
        SharedTrailSnapshot(
            hikeID: UUID(),
            title: "Ridge Loop",
            tintHex: "#34C759FF",
            totalDistanceMeters: 10_000,
            polyline: [
                .init(latitude: 47.63, longitude: 12.86),
                .init(latitude: 47.64, longitude: 12.87),
            ],
            elevationLowMeters: low,
            elevationHighMeters: high,
            elevationGainMeters: gain,
            elevationLossMeters: loss,
            liveFix: liveElevation.map { elevation in
                .init(
                    coordinate: .init(latitude: 47.635, longitude: 12.865),
                    distanceAlongRouteMeters: 2500,
                    offRouteMeters: 5,
                    timestamp: .now,
                    elevationMeters: elevation
                )
            }
        )
    }

    // MARK: What gets the width

    /// Ascent is the number the map behind the chips cannot show, so it is the
    /// one that survives the narrowest family.
    @Test("ascent leads, and is the chip the narrowest family keeps")
    func ascentLeads() {
        let metrics = Self.snapshot().metrics(limit: 1, locale: Self.locale)
        #expect(metrics.map(\.kind) == [.ascent])
    }

    /// The second slot is the walker's own height, and only while there is a
    /// live fix to read it from — off the trail there is nothing to put there.
    @Test("a live fix fills the second slot with the walker's elevation")
    func liveElevationTakesTheSecondSlot() {
        let metrics = Self.snapshot(liveElevation: 740).metrics(limit: 2, locale: Self.locale)
        #expect(metrics.map(\.kind) == [.ascent, .currentElevation])
    }

    @Test("without a fix the trail's climb is the only chip")
    func withoutAFix() {
        let metrics = Self.snapshot().metrics(limit: 4, locale: Self.locale)
        #expect(metrics.map(\.kind) == [.ascent])
    }

    /// The summit height and the descent used to have chips of their own. They
    /// are gone deliberately — a widget is a glance, and on a loop the descent
    /// repeats the ascent — so no width, however generous, brings them back.
    @Test("a wide family still gets only the pair")
    func wideFamilyGetsOnlyThePair() {
        let metrics = Self.snapshot(liveElevation: 740).metrics(limit: 99, locale: Self.locale)
        #expect(metrics.map(\.kind) == [.ascent, .currentElevation])
    }

    // MARK: Missing and degenerate data

    /// A GPX imported without elevations should draw fewer chips, not a row
    /// of dashes claiming zeroes.
    @Test("a route with no elevations has no chips to draw")
    func noElevationsMeansNoChips() {
        let bare = Self.snapshot(gain: nil, loss: nil, high: nil, low: nil)
        #expect(bare.metrics(limit: 4, locale: Self.locale).isEmpty)
        #expect(bare.metricsAccessibilityText(limit: 4, locale: Self.locale).isEmpty)
    }

    /// A dead-flat towpath climbs nothing. "Ascent 0 m" is noise where the
    /// absence of the chip says the same thing in no space at all — and with
    /// the summit chip gone there is nothing left to fall back to.
    @Test("a flat route with no fix draws no chips at all")
    func flatRouteDrawsNoChips() {
        let flat = Self.snapshot(gain: 0, loss: 0, high: 12, low: 12)
        #expect(flat.metrics(limit: 4, locale: Self.locale).isEmpty)
    }

    @Test("a family with no room for chips is given none", arguments: [0, -1])
    func degenerateLimit(limit: Int) {
        #expect(Self.snapshot().metrics(limit: limit, locale: Self.locale).isEmpty)
    }

    // MARK: VoiceOver

    /// The glyphs are hidden from VoiceOver, so the chips only exist for it
    /// through this phrase — an unlabelled "620 m" would be unreadable.
    @Test("every drawn chip is named in the spoken text")
    func spokenTextNamesEveryChip() {
        let snapshot = Self.snapshot(liveElevation: 740)
        let spoken = snapshot.metricsAccessibilityText(limit: 4, locale: Self.locale)
        for metric in snapshot.metrics(limit: 4, locale: Self.locale) {
            #expect(spoken.contains(metric.spokenLabel), "\(metric.kind)")
            #expect(spoken.contains(metric.value), "\(metric.kind)")
        }
    }

    @Test("the spoken text covers only the chips that are drawn")
    func spokenTextTracksTheLimit() {
        let snapshot = Self.snapshot(liveElevation: 740)
        let spoken = snapshot.metricsAccessibilityText(limit: 1, locale: Self.locale)
        #expect(spoken.contains("Ascent"))
        #expect(!spoken.contains("Elevation"))
    }

    /// Every kind has to answer for itself: a chip with an empty symbol draws
    /// a gap, and one with an empty label is silent.
    @Test("every kind has a glyph and a spoken name", arguments: TrailWidgetMetric.Kind.allCases)
    func everyKindIsRenderable(kind: TrailWidgetMetric.Kind) {
        let metric = TrailWidgetMetric(kind: kind, value: "1")
        #expect(!metric.symbolName.isEmpty)
        #expect(!metric.spokenLabel.isEmpty)
        #expect(metric.accessibilityPhrase.contains(metric.spokenLabel))
    }
}

@Suite("Recording widget metrics")
struct RecordingWidgetMetricTests {
    private static let locale = Locale(identifier: "de_DE")

    private static func snapshot(
        gain: Double? = 180,
        speed: Double? = 1.2
    ) -> SharedRecordingSnapshot {
        SharedRecordingSnapshot(
            sessionID: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_750_000_000),
            distanceMeters: 1400,
            pointCount: 320,
            polyline: [],
            elevationGainMeters: gain,
            averageSpeedMetersPerSecond: speed
        )
    }

    /// Distance and point count are already on the status line and the elapsed
    /// time is in the header, so these two are what a recording otherwise
    /// doesn't say.
    @Test("a live recording reports what its status line doesn't")
    func recordingChips() {
        #expect(Self.snapshot().metrics(limit: 4, locale: Self.locale).map(\.kind) == [.ascent, .pace])
    }

    /// A recording that has just started has neither figure yet.
    @Test("nothing is claimed before there is anything to claim")
    func nothingBeforeTheFirstFixes() {
        #expect(Self.snapshot(gain: nil, speed: nil).metrics(limit: 4, locale: Self.locale).isEmpty)
    }

    /// A stationary recorder has a speed of zero, and "0.0 km/h" is not a
    /// pace worth the width.
    @Test("a standing start reports no pace")
    func standingStartHasNoPace() {
        #expect(Self.snapshot(speed: 0).metrics(limit: 4, locale: Self.locale).map(\.kind) == [.ascent])
    }

    @Test("the chips survive the App Group round trip with the rest")
    func codableRoundTrip() throws {
        let snapshot = Self.snapshot()
        let decoded = try JSONDecoder().decode(
            SharedRecordingSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        #expect(decoded == snapshot)
        #expect(
            decoded.metrics(limit: 4, locale: Self.locale)
                == snapshot.metrics(limit: 4, locale: Self.locale)
        )
    }
}
