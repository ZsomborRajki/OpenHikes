//
//  HikeDetailSpokenLabelTests.swift
//  OpenHikesTests
//
//  What VoiceOver reads the hike detail's figures by. The two averages are
//  captioned "… Avg Speed", which a voice would have to guess at, and are
//  spoken in full, as every surface speaks its average (*Settled decisions*
//  in the repository instructions). Every other figure is spoken by its
//  caption.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Hike detail spoken labels")
struct HikeDetailSpokenLabelTests {
    private static let start = Date(timeIntervalSince1970: 1_757_000_000)
    private static let distanceMeters = 8000.0

    /// A fix an hour and two kilometres apart, climbing: a clock to divide
    /// by, so both averages are drawn.
    private static let route = [800.0, 1300, 1800, 1600].enumerated().map { index, elevation in
        RouteCoordinate(
            latitude: 47.60 + Double(index) * 0.02,
            longitude: 12.90,
            elevation: elevation,
            timestamp: start.addingTimeInterval(Double(index) * 3600)
        )
    }

    private func stats() async throws -> [Stat] {
        try await HikeDetailPreparation.prepare(route: Self.route, distanceMeters: Self.distanceMeters).stats
    }

    @Test("both averages are spoken in full under the captions that shorten them")
    func averagesAreSpokenInFull() async throws {
        let stats = try await stats()
        let overall = try #require(stats.first { $0.label == "Overall Avg Speed" })
        let moving = try #require(stats.first { $0.label == "Moving Avg Speed" })

        #expect(overall.spokenLabel == "Overall Average Speed")
        #expect(moving.spokenLabel == "Moving Average Speed")
    }

    /// Read off every figure the screen draws rather than the two above, so
    /// that a row added later under an "Avg" caption is held to it too.
    @Test("no figure is spoken as \"Avg\", and the rest are spoken by their captions")
    func noFigureIsSpokenAsAnAbbreviation() async throws {
        let stats = try await stats()
        #expect(stats.contains { $0.label.contains("Avg") }, "the route has a clock, so the averages are drawn")

        for stat in stats {
            let spoken = stat.spokenLabel ?? stat.label
            #expect(!spoken.contains("Avg"), "\(stat.label) is spoken \"\(spoken)\"")
            if !stat.label.contains("Avg") {
                #expect(stat.spokenLabel == nil, "\(stat.label) is spoken by its caption")
            }
        }
    }
}
