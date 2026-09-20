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

    /// The climb and the length are the pair the top-right corner exists for,
    /// and no Home Screen family gives either of them up — which is why the
    /// narrowest one asks for two rather than one.
    @Test("the climb and the length are what the narrowest family keeps")
    func theNarrowestFamilyKeepsThePair() {
        let metrics = Self.snapshot().metrics(limit: 2, locale: Self.locale)
        #expect(metrics.map(\.kind) == [.ascent, .length])
    }

    /// The third slot is the hiker's own height, and only while there is a
    /// live fix to read it from — off the trail there is nothing to put there.
    @Test("a live fix fills the third slot with the hiker's elevation")
    func liveElevationTakesTheThirdSlot() {
        let metrics = Self.snapshot(liveElevation: 740).metrics(limit: 3, locale: Self.locale)
        #expect(metrics.map(\.kind) == [.ascent, .length, .currentElevation])
    }

    /// A trail always has a length, so the second chip is drawn whether or not
    /// anyone is walking it. Only the third depends on a fix.
    @Test("without a fix the climb and the length are still drawn")
    func withoutAFix() {
        let metrics = Self.snapshot().metrics(limit: 4, locale: Self.locale)
        #expect(metrics.map(\.kind) == [.ascent, .length])
    }

    /// The summit height and the descent used to have chips of their own. They
    /// are gone deliberately — a widget is a glance, and on a loop the descent
    /// repeats the ascent — so no width, however generous, brings them back.
    @Test("a wide family still gets only the three")
    func wideFamilyGetsOnlyTheThree() {
        let metrics = Self.snapshot(liveElevation: 740).metrics(limit: 99, locale: Self.locale)
        #expect(metrics.map(\.kind) == [.ascent, .length, .currentElevation])
    }

    // MARK: Missing and degenerate data

    /// A GPX imported without elevations should draw fewer chips, not a row
    /// of dashes claiming zeroes. The length survives, because it is measured
    /// from the line rather than read out of the file.
    @Test("a route with no elevations draws its length and nothing more")
    func noElevationsMeansOnlyTheLength() {
        let bare = Self.snapshot(gain: nil, loss: nil, high: nil, low: nil)
        #expect(bare.metrics(limit: 4, locale: Self.locale).map(\.kind) == [.length])
        #expect(!bare.metricsAccessibilityText(limit: 4, locale: Self.locale).isEmpty)
    }

    /// A dead-flat towpath climbs nothing. "Ascent 0 m" is noise where the
    /// absence of the chip says the same thing in no space at all — and with
    /// the summit chip gone there is nothing left to fall back to.
    @Test("a flat route with no fix draws no climb")
    func flatRouteDrawsNoClimb() {
        let flat = Self.snapshot(gain: 0, loss: 0, high: 12, low: 12)
        #expect(flat.metrics(limit: 4, locale: Self.locale).map(\.kind) == [.length])
    }

    /// The one route that draws nothing at all: a line with no length is a
    /// failed import, and "0 m" beside a drawn trail is the widget
    /// contradicting itself.
    @Test("a zero-length route draws no chips at all")
    func zeroLengthRouteDrawsNothing() {
        var empty = Self.snapshot(gain: nil, loss: nil, high: nil, low: nil)
        empty.totalDistanceMeters = 0
        #expect(empty.metrics(limit: 4, locale: Self.locale).isEmpty)
        #expect(empty.metricsAccessibilityText(limit: 4, locale: Self.locale).isEmpty)
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
