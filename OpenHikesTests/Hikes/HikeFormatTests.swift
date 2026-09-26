//
//  HikeFormatTests.swift
//  OpenHikesTests
//
//  "Stat formatting", split out of HikeStatisticsTests.swift so that a file
//  declares one @Suite. That file's header still holds the context the two
//  share.
//

import CoreLocation
import Foundation
import OpenHikesData
import SwiftData
import Testing

@Suite("Stat formatting")
struct HikeFormatTests {
    /// Under an hour the interesting unit is seconds; over it, nobody wants
    /// to read "72 min 13 sec".
    @Test("duration switches units at the hour mark")
    func duration() {
        let short = HikeFormat.duration(90)
        #expect(short.contains("1"))
        #expect(!short.lowercased().contains("h"))

        let long = HikeFormat.duration(3600 + 25 * 60)
        #expect(long.lowercased().contains("h"))
        #expect(long.contains("25"))
    }

    /// Elevations are whole units — a stat tile reading "217.4382 m" is false
    /// precision on data this noisy. Which unit, and the non-finite case, are
    /// `ElevationFormatTests`' business: they are the region-sensitive half
    /// and nothing here may read `Locale.current` to decide them.
    @Test("elevations are rounded to whole units")
    func elevation() {
        let text = HikeFormat.elevation(
            Measurement(value: 217.4382, unit: .meters),
            locale: Locale(identifier: "de_DE")
        )
        #expect(text == "217 m")
    }

    /// Speeds arrive in metres per second and are read in km/h — and the
    /// decimal is the substance of the claim, since rounding 3.6 km/h to
    /// "4 km/h" erases the difference between a stroll and a march. Compared
    /// against the locale's own decimal separator, because the region the
    /// simulator is set to decides whether that is a dot or a comma.
    /// Pinned to one region rather than read from `Locale.current`: speed is
    /// now a regional unit, so a test that takes the machine's own region as
    /// its input agrees with whatever the machine happens to be set to. The
    /// full regional matrix lives in ``SpeedFormatTests``; what this asserts
    /// is the conversion out of metres per second and the surviving decimal.
    @Test("speeds are converted to km/h with one decimal")
    func speed() {
        let metric = Locale(identifier: "de_DE")

        let fast = HikeFormat.speed(Measurement(value: 10, unit: .metersPerSecond), locale: metric)
        #expect(fast == "36,0 km/h")

        // 1 m/s is 3.6 km/h: the conversion has to happen at all, and the
        // digit it lands on has to survive the rounding.
        let walking = HikeFormat.speed(Measurement(value: 1, unit: .metersPerSecond), locale: metric)
        #expect(walking == "3,6 km/h")
    }
}
