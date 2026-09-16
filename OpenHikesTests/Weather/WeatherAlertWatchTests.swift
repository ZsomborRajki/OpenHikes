//
//  WeatherAlertWatchTests.swift
//  OpenHikesTests
//
//  Whether a severe-weather alert is worth interrupting a walk for, and
//  whether it has already been said.
//
//  The second half is what this suite mostly is. The weather loop re-asks
//  WeatherKit every few minutes and an agency's warning stands for hours, so
//  the same alert comes back on every request — and a banner per poll is the
//  fastest way to teach somebody to ignore the one notification in this app
//  that could matter. `announcesOnceAcrossRepeatedPolls` is that test, driven
//  the way the loop drives it rather than called twice.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Severe weather alerts worth saying")
struct WeatherAlertWatchTests {
    // MARK: Fixtures

    /// Non-optional on the type, so the fixture needs a real one — built
    /// through a static rather than force-unwrapped at each call site.
    private static func detailsURL(_ id: String) -> URL {
        URL(string: "https://weather.example/\(id)") ?? URL(filePath: "/")
    }

    private static func alert(
        id: String = "storm-1",
        severity: WeatherAlertSeverity = .severe,
        summary: String = "Severe thunderstorm warning"
    ) -> WeatherAlertSummary {
        WeatherAlertSummary(
            id: id,
            summary: summary,
            severity: severity,
            // Non-optional on purpose: an alert this app cannot link is an
            // alert it must not draw. See `WeatherAlerts`.
            detailsURL: detailsURL(id),
            source: "Deutscher Wetterdienst",
            expires: nil
        )
    }

    // MARK: The threshold

    @Test("a severe alert is worth interrupting a walk for")
    func announcesASevereAlert() {
        var watch = WeatherAlertWatch()

        let said = watch.observed(.active([Self.alert()]))

        #expect(said.count == 1)
        #expect(said.first?.id == "storm-1")
    }

    /// The grade agencies use for the weather a hiker dressed for. Still drawn
    /// in the sheet; just not a banner.
    @Test("a moderate alert is not worth a banner")
    func staysQuietForAModerateAlert() {
        var watch = WeatherAlertWatch()

        let said = watch.observed(.active([Self.alert(severity: .moderate)]))

        #expect(said.isEmpty)
    }

    /// An ungraded advisory is not evidence of danger, which is why `unknown`
    /// sorts as the least severe rather than the most.
    @Test("an ungraded alert is not treated as the worst case")
    func staysQuietForAnUngradedAlert() {
        var watch = WeatherAlertWatch()

        let said = watch.observed(.active([Self.alert(severity: .unknown)]))

        #expect(said.isEmpty)
    }

    @Test("an extreme alert is above the threshold too")
    func announcesAnExtremeAlert() {
        var watch = WeatherAlertWatch()

        let said = watch.observed(.active([Self.alert(severity: .extreme)]))

        #expect(said.count == 1)
    }

    // MARK: Saying it once

    /// **The one the feature rests on.** Driven as the poll loop drives it —
    /// the same standing alert, over and over — rather than by calling
    /// `observed` twice, because that is the shape that produces the failure.
    @Test("a standing alert is announced once however many times it is polled")
    func announcesOnceAcrossRepeatedPolls() {
        var watch = WeatherAlertWatch()
        let standing = WeatherAlerts.active([Self.alert()])

        var announcements: [WeatherAlertSummary] = []
        for _ in 0..<20 {
            announcements.append(contentsOf: watch.observed(standing))
        }

        #expect(announcements.count == 1)
    }

    @Test("a second, different alert is still news")
    func announcesADistinctSecondAlert() {
        var watch = WeatherAlertWatch()
        _ = watch.observed(.active([Self.alert()]))

        let said = watch.observed(
            .active([Self.alert(), Self.alert(id: "flood-1", summary: "Flood warning")])
        )

        #expect(said.count == 1)
        #expect(said.first?.id == "flood-1")
    }

    /// The caller posts only the first, because one kind is one banner — a
    /// second post replaces the first rather than stacking under it.
    @Test("several new alerts come back worst first")
    func ordersTheWorstFirst() {
        var watch = WeatherAlertWatch()

        let said = watch.observed(
            .active([
                Self.alert(id: "severe-1", severity: .severe),
                Self.alert(id: "extreme-1", severity: .extreme),
            ])
        )

        #expect(said.map(\.id) == ["extreme-1", "severe-1"])
    }

    // MARK: The two empties

    /// Neither empty clears what has been announced. *Unavailable* is the app
    /// learning nothing rather than learning the storm is over.
    @Test("an unavailable reading does not re-arm an announced alert")
    func unavailableDoesNotReArm() {
        var watch = WeatherAlertWatch()
        let standing = WeatherAlerts.active([Self.alert()])
        _ = watch.observed(standing)

        _ = watch.observed(.unavailable)
        let said = watch.observed(standing)

        #expect(said.isEmpty)
    }

    @Test("a clear reading does not re-arm an announced alert")
    func clearDoesNotReArm() {
        var watch = WeatherAlertWatch()
        let standing = WeatherAlerts.active([Self.alert()])
        _ = watch.observed(standing)

        _ = watch.observed(.clear)
        let said = watch.observed(standing)

        #expect(said.isEmpty)
    }

    @Test("neither empty is worth saying anything about")
    func bothEmptiesSayNothing() {
        var watch = WeatherAlertWatch()

        #expect(watch.observed(.clear).isEmpty)
        #expect(watch.observed(.unavailable).isEmpty)
        #expect(!watch.hasAnnounced)
    }

    // MARK: Moving on

    /// An alert already announced over one ridge is news again over another:
    /// it is a different place the hiker is being warned about.
    @Test("resetting makes a standing alert news again")
    func resetMakesAnAlertNewsAgain() {
        var watch = WeatherAlertWatch()
        let standing = WeatherAlerts.active([Self.alert()])
        _ = watch.observed(standing)

        watch.reset()

        #expect(watch.observed(standing).count == 1)
    }

    /// The bound is a leak stop rather than a policy — evicting an alert that
    /// is still standing re-announces it, so the limit sits well above any
    /// plausible number over one place at one time.
    @Test("the remembered set is bounded")
    func boundsWhatItRemembers() {
        var watch = WeatherAlertWatch()
        let overLimit = WeatherAlertPolicy.rememberedAlertLimit + 10

        for index in 0..<overLimit {
            _ = watch.observed(.active([Self.alert(id: "alert-\(index)")]))
        }

        // The oldest have been forgotten, so the very first is news again;
        // the most recent is still remembered.
        #expect(watch.observed(.active([Self.alert(id: "alert-0")])).count == 1)
        #expect(watch.observed(.active([Self.alert(id: "alert-\(overLimit - 1)")])).isEmpty)
    }
}
