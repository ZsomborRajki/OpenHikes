//
//  LibraryTotalsUnitTests.swift
//  OpenHikesTests
//
//  The unit *Totals*' month chart is drawn in, held to the unit its distance
//  tiles are written in. The chart converts to the unit it labels, so the one
//  way to get it wrong is to choose that unit by a different rule from the
//  tiles' — which it did, by asking `measurementSystem`, and Liberia and
//  Myanmar read "5 km" over a chart in miles (#1368).
//
//  Which regions sign their roads in miles is not decided here: that is
//  `WidgetFormatTests`' question, asked of ICU. These are the regions the
//  elevation and speed suites already use, two of which are where the two
//  rules part company. Nothing reads `Locale.current`, so the machine's own
//  region cannot be the answer.
//
//  With it, the rest of what `TotalsFormat` spells: nothing walked, a line
//  of the chart's axis, and a figure as it is drawn and as it is spoken.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

@Suite("Library totals units")
struct LibraryTotalsUnitTests {
    /// Five kilometres, the distance `WidgetFormat` asks its road question
    /// with: far enough above a kilometre that no region writes it in metres.
    private static let probeMeters = 5000.0

    /// The tile as it would read if the region's roads were signed in
    /// kilometres.
    private static func inKilometers(_ locale: Locale) -> String {
        Measurement(value: probeMeters / 1000, unit: UnitLength.kilometers)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided).locale(locale))
    }

    /// The invariant the bug broke, without a table of which region uses
    /// which unit: the chart is in kilometres exactly when the tile is.
    @Test(
        "the chart is drawn in the unit its distance tiles are written in",
        arguments: ["en_US", "en_GB", "de_DE", "ja_JP", "en_LR", "my_MM"]
    )
    func chartFollowsTheTiles(identifier: String) {
        let locale = Locale(identifier: identifier)
        let tile = TotalsFormat.distance(Self.probeMeters, locale: locale)
        let unit = TotalsFormat.chartUnit(in: locale)

        #expect(
            (unit.symbol == UnitLength.kilometers.symbol) == (tile == Self.inKilometers(locale)),
            "\(identifier) wrote \"\(tile)\" over a chart in \(unit.symbol)"
        )
    }

    /// A month nothing was walked in is read off a chart whose axis starts
    /// at "0 km". A road sign's rule writes nothing as "0 m", or "0 ft",
    /// which is neither the chart's unit nor the unit of the year beside it.
    @Test(
        "nothing walked is written in the chart's unit",
        arguments: ["en_US", "en_GB", "de_DE", "ja_JP", "en_LR", "my_MM"]
    )
    func nothingWalked(identifier: String) {
        let locale = Locale(identifier: identifier)
        let unit = TotalsFormat.chartUnit(in: locale)
        #expect(TotalsFormat.distance(0, locale: locale) == TotalsFormat.axisDistance(0, in: unit, locale: locale))
    }

    @Test("a line of the chart's axis is written with its unit")
    func axisLines() {
        #expect(TotalsFormat.axisDistance(150, in: .kilometers, locale: Locale(identifier: "de_DE")) == "150 km")
        #expect(TotalsFormat.axisDistance(1500, in: .kilometers, locale: Locale(identifier: "en_US")) == "1,500 km")
        #expect(TotalsFormat.axisDistance(0.5, in: .miles, locale: Locale(identifier: "en_US")) == "0.5 mi")
    }

    @Test("a bar is as tall as its distance in the chart's unit")
    func chartValues() {
        #expect(TotalsFormat.chartValue(5000, in: .kilometers) == 5)
        #expect(TotalsFormat.chartValue(1609.344, in: .miles).isApproximatelyEqual(to: 1, absoluteTolerance: 1e-9))
    }

    /// "225h 45m" is what a tile has room for and what VoiceOver misreads,
    /// so a duration is the one figure spoken otherwise than it is drawn.
    @Test("only a duration is read aloud otherwise than it is drawn")
    func readings() {
        let duration = TotalsReading.duration(812_700)
        #expect(duration.drawn == HikeFormat.duration(812_700))
        #expect(duration.spoken == HikeFormat.spokenDuration(812_700))
        #expect(duration.drawn != duration.spoken)

        let distance = TotalsReading.distance(5000)
        #expect(distance.drawn == TotalsFormat.distance(5000))
        #expect(distance.spoken == distance.drawn)
        let height = TotalsReading.height(1250)
        #expect(height.drawn == TotalsFormat.height(1250))
        #expect(height.spoken == height.drawn)
        let count = TotalsReading.count(42)
        #expect(count.drawn == 42.formatted())
        #expect(count.spoken == count.drawn)
    }

    /// The pair the old rule got wrong, with the measurement system asserted
    /// beside it, so that a change back to asking it fails here with the
    /// reason written down.
    @Test("a region with imperial units and metric roads is charted in kilometres", arguments: ["en_LR", "my_MM"])
    func imperialSystemMetricRoads(identifier: String) {
        let locale = Locale(identifier: identifier)
        #expect(locale.measurementSystem != .metric)
        #expect(TotalsFormat.chartUnit(in: locale).symbol == UnitLength.kilometers.symbol)
    }
}
