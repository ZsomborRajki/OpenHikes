//
//  WeatherAlertOrderTests.swift
//  OpenHikesTests
//
//  The order the weather sheet lists alerts in: worst first, and otherwise as
//  the authority sent them.
//
//  The sort compares severity alone and leaves a tie to `sorted(by:)` being
//  stable, so the ties are the cases that matter here.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Weather alert order")
struct WeatherAlertOrderTests {
    private static func summary(_ id: String, _ severity: WeatherAlertSeverity) -> WeatherAlertSummary {
        WeatherAlertSummary(
            id: id,
            summary: "Warning \(id)",
            severity: severity,
            detailsURL: URL(string: "https://weather.example/\(id)") ?? URL(filePath: "/"),
            source: "Deutscher Wetterdienst"
        )
    }

    @Test("the worst alert comes first, an ungraded one last")
    func worstComesFirst() {
        let sent = [
            Self.summary("minor", .minor),
            Self.summary("ungraded", .unknown),
            Self.summary("extreme", .extreme),
            Self.summary("moderate", .moderate),
            Self.summary("severe", .severe),
        ]

        #expect(
            WeatherAlertSummary.worstFirst(sent).map(\.id)
                == ["extreme", "severe", "moderate", "minor", "ungraded"]
        )
    }

    @Test("alerts of the same grade keep the order the authority sent them in")
    func equalGradesKeepTheSentOrder() {
        let sent = [
            Self.summary("storm-1", .severe),
            Self.summary("frost-1", .minor),
            Self.summary("storm-2", .severe),
            Self.summary("frost-2", .minor),
            Self.summary("storm-3", .severe),
        ]

        #expect(
            WeatherAlertSummary.worstFirst(sent).map(\.id)
                == ["storm-1", "storm-2", "storm-3", "frost-1", "frost-2"]
        )
    }
}
