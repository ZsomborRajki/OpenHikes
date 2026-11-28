//
//  PromptForecasts.swift
//  OpenHikesTests
//
//  A WeatherKit for the suites that drive the real poll loop and need its
//  requests to come back: it answers every place the same, a turn after it
//  was asked, and remembers where it was asked about.
//
//  ``WeatherPollFocusTests`` keeps a stub of its own, which answers only when
//  a case tells it to. That is the one to reach for when the order of two
//  answers is the point.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import RealModule

@MainActor
final class PromptForecasts: WeatherReadingFetching {
    /// What every answer reads, so a case can tell one from a stored reading.
    static let celsius = 21.0
    private static let tolerance = 1e-9

    private var asked: [Double] = []

    func reading(at coordinate: CLLocationCoordinate2D) async throws -> WeatherSnapshot {
        asked.append(coordinate.latitude)
        // Never in the turn it was asked in, as no request is, and not at
        // all once its poll has gone.
        await Task.yield()
        try Task.checkCancellation()
        return WeatherSnapshot(
            symbolName: "sun.max.fill",
            temperature: Measurement(value: Self.celsius, unit: UnitTemperature.celsius),
            conditionDescription: "Clear",
            capturedAt: .now,
            conditions: .preview
        )
    }

    /// How many requests were about `coordinate`, told apart by latitude.
    func timesAsked(about coordinate: CLLocationCoordinate2D) -> Int {
        asked.count { $0.isApproximatelyEqual(to: coordinate.latitude, absoluteTolerance: Self.tolerance) }
    }
}
