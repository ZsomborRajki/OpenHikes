//
//  RenderIsolationTests+Observation.swift
//  OpenHikesTests
//
//  The framework behaviour the render-isolation suites are really asserting.
//
//  Almost every "…doesn't wake the map" test in this directory is a zero on an
//  `ObservationCounter`, and a zero has two possible authors: the app, which
//  compared before assigning, or the runtime, which discarded an assignment
//  that compared equal. Mutation testing separates them — break the app's own
//  guard and see whether the zero moves — and for a family of them it does
//  not, because the runtime got there first.
//
//  That is a legitimate answer, but only while it stays true, and none of it
//  is documented by Apple. So both halves are pinned here, on a type the tests
//  own, where no app-side guard can hide the result:
//
//  * an equal write to an `Equatable` `@Observable` property notifies nobody;
//  * an equal write to a SwiftData `@Model` property notifies everybody.
//
//  They point opposite ways and both are load-bearing. The first is what keeps
//  the map quiet when a colour picker is dragged back to where it started. The
//  second is what proves the first is doing work rather than never being
//  reached — it is why a same-value edit to `Hike.tintHex` genuinely travels
//  through `RouteStyle.track` into `apply`, rather than being dropped upstream
//  by SwiftData and leaving the appearance tests measuring nothing at all.
//

import CoreLocation
@testable import OpenHikes
import SwiftUI
import Testing

/// A bare coordinate-typed publisher, the shape `RouteHighlight` and
/// `LocationManager` had before either compared for itself.
///
/// Owned by the tests rather than borrowed from the app: what the two tests
/// below pin is Observation's own treatment of a non-`Equatable` value, which
/// is the *premise* those models' guards rest on — so it has to be measurable
/// on something unguarded, or the evidence for the guards disappears the moment
/// they're added.
@Observable
final class CoordinatePublisher {
    var coordinate: CLLocationCoordinate2D?
}

/// The three types ``RouteStyle`` publishes, on a class with no guards of its
/// own — owned by the tests for the same reason ``CoordinatePublisher`` is.
/// `RouteStyle`'s own equality checks would hide the runtime behaviour that
/// makes them redundant, and it is that behaviour the map's quiet actually
/// rests on.
@Observable
final class AppearancePublisher {
    var tint: Color = .green
    var width: Double = 3
    var pattern: RouteLinePattern = .solid
}

extension ObservationCostTests {
    /// Observation filters a write that doesn't change an `Equatable` value.
    /// So the hot paths' guards around `Double`/`Double?`/`CGFloat` state —
    /// `if moved { tracker.liveTrackerDistance = … }` and friends — are
    /// belt-and-braces on this toolchain: an unguarded equal assignment costs
    /// nothing either. Pinned because the comments around those guards claim
    /// otherwise, and because a future guard removed on this evidence should
    /// fail loudly here if the runtime ever changes back.
    @Test("an equal write to an Equatable property notifies nobody")
    func equalEquatableWriteIsFiltered() async {
        let tracker = TrackerState()
        tracker.trackerDistance = 100
        tracker.liveTrackerDistance = 100
        let distanceCounter = ObservationCounter { _ = tracker.trackerDistance }
        let liveCounter = ObservationCounter { _ = tracker.liveTrackerDistance }
        await distanceCounter.settle()

        tracker.trackerDistance = 100
        tracker.liveTrackerDistance = 100
        await distanceCounter.settle()
        #expect(distanceCounter.count == 0)
        #expect(liveCounter.count == 0)

        tracker.trackerDistance = 200
        await distanceCounter.settle()
        #expect(distanceCounter.count == 1, "a real move must still reach the chart")
    }

    /// …but `CLLocationCoordinate2D` is not `Equatable`, so Observation has
    /// no way to tell an unchanged position from a new one and notifies on
    /// every assignment. That is why the two coordinate-typed publishers —
    /// `RouteHighlight` and `LocationManager`, the two written most often
    /// (drag frequency and 1 Hz respectively) — compare before assigning
    /// instead of leaving it to the runtime.
    @Test("an equal write to a coordinate notifies anyway")
    func equalCoordinateWriteIsNotFiltered() async {
        let publisher = CoordinatePublisher()
        publisher.coordinate = CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86)
        let counter = ObservationCounter { _ = publisher.coordinate }
        await counter.settle()

        publisher.coordinate = CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86)
        await counter.settle()
        #expect(
            counter.count == 1,
            "same place, still a notification — the coordinate publishers must compare for themselves"
        )
    }

    /// The other half of the same idea: the guard genuinely costs nothing when
    /// it holds.
    @Test("a skipped write notifies nobody")
    func skippedWriteIsSilent() async {
        let publisher = CoordinatePublisher()
        let counter = ObservationCounter { _ = publisher.coordinate }
        await counter.settle()

        // The shape `RouteHighlight.move(to:)` applies: only write when there's
        // something to change.
        if publisher.coordinate != nil { publisher.coordinate = nil }
        await counter.settle()
        #expect(counter.count == 0)
    }

    /// The same filtering, on the three types the map's route styling actually
    /// publishes. `equalEquatableWriteIsFiltered` above covers `Double`; this
    /// covers the `Color` and `RouteLinePattern` that ``RouteStyle`` publishes
    /// alongside it, and it is what `RouteStyleTests` leans on when it claims
    /// an unchanged appearance doesn't wake the map.
    ///
    /// Two things here are load-bearing and neither is obvious. Filtering
    /// happens because these types are `Equatable` — a non-`Equatable` payload
    /// gets no filtering at all, which is the whole reason
    /// ``CoordinatePublisher``'s two tests exist. And a `Color` rebuilt from
    /// the same hex compares equal to the one already stored, so a route tint
    /// re-derived from `Hike.tintHex` on every notification still lands as an
    /// equal write rather than as a new value.
    @Test("an equal write to the map's appearance types notifies nobody")
    func equalAppearanceWriteIsFiltered() async {
        let appearance = AppearancePublisher()
        appearance.tint = Color(hex: "#FF0000FF") ?? .green
        appearance.pattern = .dashed
        let tintCounter = ObservationCounter { _ = appearance.tint }
        let patternCounter = ObservationCounter { _ = appearance.pattern }
        await tintCounter.settle()

        appearance.tint = Color(hex: "#FF0000FF") ?? .green
        appearance.pattern = .dashed
        await tintCounter.settle()
        #expect(tintCounter.count == 0, "a Color rebuilt from the same hex is an equal write")
        #expect(patternCounter.count == 0)

        appearance.tint = Color(hex: "#0000FFFF") ?? .green
        appearance.pattern = .dotted
        await tintCounter.settle()
        #expect(tintCounter.count == 1, "a real recolour must still reach the renderer")
        #expect(patternCounter.count == 1)
    }

    /// The other half of the premise, and it points the opposite way: a
    /// SwiftData `@Model` does **not** filter an equal write. Every write
    /// notifies, whatever the property is.
    ///
    /// This is what makes the filtering above load-bearing rather than
    /// redundant. A same-value write to `Hike.tintHex` does wake
    /// `RouteStyle.track`, which does re-derive the tint and does call
    /// `apply` — so the reason the map stays quiet is entirely the equality
    /// check on the far side, in `RouteStyle`'s own `@Observable` storage.
    /// If SwiftData ever started coalescing, the appearance tests would keep
    /// passing while measuring nothing, so `RouteStyleTests` asserts this as
    /// an explicit precondition and this pins the general fact behind it.
    ///
    /// Measured across the property shapes `Hike` actually uses, because
    /// "SwiftData swallows same-value writes" was believed here once and is
    /// false for all of them: a stored scalar, an `@Attribute(.externalStorage)`
    /// array and a to-many relationship all notify. The second `#expect` block
    /// pins the per-property granularity that makes the first block's zeroes
    /// mean something.
    @Test("a same-value write to a SwiftData model still notifies")
    func equalModelWriteIsNotFiltered() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context) { $0.tintHex = "#FF0000FF" }
        let tintCounter = ObservationCounter { _ = hike.tintHex }
        let widthCounter = ObservationCounter { _ = hike.routeWidth }
        let routeCounter = ObservationCounter { _ = hike.route }
        await tintCounter.settle()

        hike.tintHex = "#FF0000FF"
        await tintCounter.settle()
        #expect(tintCounter.count == 1, "SwiftData does not coalesce an equal write")
        #expect(widthCounter.count == 0, "…and observation of a @Model is still per-property")
        #expect(routeCounter.count == 0)

        hike.routeWidth = hike.routeWidth
        hike.route = hike.route
        await tintCounter.settle()
        #expect(widthCounter.count == 1, "a stored scalar notifies")
        #expect(routeCounter.count == 1, "and so does an externally-stored array")
    }
}
