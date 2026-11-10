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

import Foundation
@testable import OpenHikes
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
