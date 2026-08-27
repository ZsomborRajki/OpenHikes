//
//  RecordingEnduranceTests.swift
//  OpenHikesTests
//
//  A recording the length of a real hike, rather than the handful of fixes
//  every other recording suite drives.
//
//  Several things in this pipeline can only misbehave at scale, and none of
//  them had a test that reached that scale: the journal's flush cadence across
//  thousands of appends, ``SerialAsyncQueue``'s "everything accepted before
//  the barrier is durable once it drains" invariant at a queue depth of
//  thousands, the distance and elevation accumulators after four thousand
//  incremental additions, and ``RecordingTrace``'s widget decimation once the
//  trace is an order of magnitude longer than the polyline can carry.
//
//  Six hours are simulated through the injected clock, so the cost is a couple
//  of seconds of wall time rather than six hours — both unit bundles are
//  `parallelizable: false`, so a slow test here is slow for everyone. The
//  route comes from ``SeededGenerator``, so a failure names the seed it
//  happened on and can be replayed on exactly the values that produced it.
//
//  The walk itself, and the tolerances these tests hold the pipeline to, are
//  in `RecordingEnduranceWalk.swift`.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesShared
import Synchronization
import Testing

// MARK: - Tests

extension HikeRecorderTests {

    @Test("A six-hour recording comes back whole")
    func sixHourRecordingSurvivesTheJournalRoundTrip() async throws {
        let walk = EnduranceWalk()
        let hikeRecorder = makeRecorder()
        let journal = try #require(hikeRecorder.journal)
        await hikeRecorder.start()

        var delivered = 0
        for segment in enduranceSegments(of: walk.steps[...]) {
            deliver(segment, to: hikeRecorder)
            delivered += segment.count
            // A real barrier rather than a settle: `drain()` submits an
            // operation behind everything already queued, so returning from it
            // means every append enqueued above has run.
            await hikeRecorder.journalQueue.drain()
            let flushed = try #require(await journal.loadSession())
            #expect(
                flushed.points.count == delivered,
                """
                the journal fell behind the recording after \
                \(delivered) fixes (seed \(walk.seed))
                """
            )
        }

        #expect(
            hikeRecorder.stats.pointCount == delivered,
            "a fix was dropped between delivery and the recorder (seed \(walk.seed))"
        )
        let liveDistance = hikeRecorder.stats.distanceMeters
        let liveElevationGain = hikeRecorder.stats.elevationGainMeters
        let widgetPolyline = hikeRecorder.trace.widgetPolyline()

        let hike = try savedHike(from: await hikeRecorder.stop())

        expectRouteIsWhole(hike.route, matches: walk, delivered: delivered)
        expectDistanceSurvived(hike, live: liveDistance, walk: walk)
        expectElevationSurvived(hike, live: liveElevationGain, seed: walk.seed)
        expectWidgetPolylineKeptTheShape(widgetPolyline, of: hike.route, seed: walk.seed)
    }

    /// The invariant ``SerialAsyncQueue`` exists for, at a depth no other test
    /// reaches. Nothing is awaited while the fixes are delivered, so the
    /// queue's consumer never gets a chance to run and the whole hour piles up
    /// behind one barrier.
    @Test("Every fix accepted before the barrier is in the journal after it")
    func journalQueueDrainsAnHourOfFixesInOrder() async throws {
        let walk = EnduranceWalk(hours: 1)
        let hikeRecorder = makeRecorder()
        let journal = try #require(hikeRecorder.journal)
        await hikeRecorder.start()

        deliver(walk.steps[...], to: hikeRecorder)
        let accepted = hikeRecorder.stats.pointCount
        #expect(
            accepted == walk.steps.count,
            "a fix was rejected the generator meant to be accepted (seed \(walk.seed))"
        )

        await hikeRecorder.journalQueue.drain()

        let session = try #require(await journal.loadSession())
        #expect(
            session.points.count == accepted,
            """
            \(accepted - session.points.count) of \(accepted) fixes were \
            accepted but not durable once the queue drained (seed \(walk.seed))
            """
        )
        let outOfOrder = zip(session.points, session.points.dropFirst())
            .filter { $0.0.timestamp >= $0.1.timestamp }
        #expect(
            outOfOrder.isEmpty,
            "\(outOfOrder.count) journal records are out of order (seed \(walk.seed))"
        )
    }

    /// A stop the walk itself produces, rather than an injected condition:
    /// six minutes of fixes that go nowhere, then walking again.
    @Test("A stop widens the distance filter and walking again narrows it")
    func stationaryWindowWidensTheDistanceFilterMidRecording() async throws {
        // An hour rather than the full six: three stops still fit into it, so
        // the walk produces a stationary window on its own, and the test stays
        // cheap.
        let walk = EnduranceWalk(hours: 1)
        let hikeRecorder = makeRecorder()
        await hikeRecorder.start()
        #expect(source.currentProfile == .precise)

        let firstStop = try #require(walk.stopRanges.first)
        deliver(walk.steps[0..<firstStop.upperBound], to: hikeRecorder)
        #expect(
            source.currentProfile?.distanceFilter
                == RecordingEnergyPolicy.stationaryDistanceFilter,
            """
            standing still for six minutes did not widen the distance filter \
            (seed \(walk.seed))
            """
        )

        // Exactly the stretch between the first two stops, so the segment
        // cannot end inside another stationary window and report the wrong
        // reason for the wrong profile.
        let secondStop = try #require(walk.stopRanges.dropFirst().first)
        deliver(
            walk.steps[firstStop.upperBound..<secondStop.lowerBound],
            to: hikeRecorder
        )
        #expect(
            source.currentProfile == .precise,
            "walking again did not restore the precise profile (seed \(walk.seed))"
        )
    }

    /// The two conditions ``RecordingEnergyPolicy`` watches, arriving and
    /// clearing part-way through a recording rather than being true at
    /// `start()` — which is the only shape the other energy tests cover.
    @Test("Low Power Mode and thermal pressure arriving mid-recording reach the GPS")
    func energyConditionsArrivingMidRecordingReachTheGPS() async {
        let power = Mutex(PowerState())
        let monitor = PowerStateMonitor(
            read: { power.withLock { $0 } },
            observesNotifications: false
        )
        let hikeRecorder = makeRecorder(powerMonitor: monitor)
        let walk = EnduranceWalk(hours: 1)
        await hikeRecorder.start()

        let thirds = enduranceSegments(of: walk.steps[...], count: 3)
        power.withLock { state in state = PowerState(isLowPowerModeEnabled: true) }
        monitor.refresh()
        deliver(thirds[0], to: hikeRecorder)
        await settleDelegateHop(until: "the conserving profile to be applied") {
            self.source.currentProfile?.desiredAccuracy
                == RecordingEnergyPolicy.conservingAccuracy
        }

        power.withLock { state in
            state = PowerState(isLowPowerModeEnabled: true, thermalState: .serious)
        }
        monitor.refresh()
        deliver(thirds[1], to: hikeRecorder)

        power.withLock { state in state = PowerState() }
        monitor.refresh()
        deliver(thirds[2], to: hikeRecorder)
        await settleDelegateHop(until: "the precise profile to be restored") {
            self.source.currentProfile?.desiredAccuracy == kCLLocationAccuracyBest
        }

        expectEnergyTransitions(source.appliedProfiles, seed: walk.seed)
    }
}

// MARK: - Driving the walk

extension HikeRecorderTests {

    /// Splits the walk so the journal can be reconciled part-way through,
    /// which is also what a real recording gets: the main actor yields between
    /// fixes, so the serial queue drains continuously rather than at the end.
    private func enduranceSegments(
        of steps: ArraySlice<EnduranceStep>,
        count: Int = Endurance.segments
    ) -> [ArraySlice<EnduranceStep>] {
        guard count > 1 else { return [steps] }
        return (0..<count).map { index in
            let lower = steps.startIndex + steps.count * index / count
            let upper = steps.startIndex + steps.count * (index + 1) / count
            return steps[lower..<upper]
        }
    }

    /// Delivers synchronously and without awaiting anything: `deliver` runs the
    /// delegate inline through `onMainActor`, so the recorder has finished with
    /// each fix before the next one is built.
    private func deliver(
        _ steps: ArraySlice<EnduranceStep>,
        to hikeRecorder: HikeRecorder
    ) {
        for step in steps {
            clock.advance(by: step.interval)
            source.deliver(step.location(at: clock.now))
        }
    }
}

// MARK: - Assertions

extension HikeRecorderTests {

    /// Names rather than whole profiles: a stop may or may not be in progress
    /// when a condition arrives, and "stationary" is an independent term in
    /// the same name.
    private func expectEnergyTransitions(
        _ profiles: [RecordingEnergyProfile],
        seed: UInt64
    ) {
        let names = profiles.map(\.name)
        #expect(
            names.contains(where: { $0.contains("stationary") }),
            "the stationary profile was never applied (seed \(seed)): \(names)"
        )
        #expect(
            names.contains(where: { $0.contains("low-power") }),
            "Low Power Mode never reached CoreLocation (seed \(seed)): \(names)"
        )
        #expect(
            names.contains(where: { $0.contains("low-power") && $0.contains("thermal") }),
            """
            a hot phone in Low Power Mode never reached CoreLocation \
            (seed \(seed)): \(names)
            """
        )
        #expect(
            profiles.last?.desiredAccuracy == kCLLocationAccuracyBest,
            "the GPS stayed conservative after conditions cleared (seed \(seed))"
        )
    }

    private func expectRouteIsWhole(
        _ route: [RouteCoordinate],
        matches walk: EnduranceWalk,
        delivered: Int
    ) {
        #expect(
            route.count == delivered,
            """
            the saved route is \(route.count) points, \(delivered) were \
            accepted (seed \(walk.seed))
            """
        )
        let outOfOrder = zip(route, route.dropFirst()).filter { pair in
            guard let first = pair.0.timestamp, let second = pair.1.timestamp else { return true }
            return first >= second
        }
        #expect(
            outOfOrder.isEmpty,
            "\(outOfOrder.count) saved route points are out of order (seed \(walk.seed))"
        )
        #expect(
            route.first?.latitude == walk.steps.first?.latitude,
            "the route does not begin where the walk did (seed \(walk.seed))"
        )
        #expect(
            route.last?.longitude == walk.steps.last?.longitude,
            "the route does not end where the walk did (seed \(walk.seed))"
        )
    }

    private func expectDistanceSurvived(
        _ hike: Hike,
        live: Double,
        walk: EnduranceWalk
    ) {
        #expect(
            abs(hike.distanceMeters - live)
                <= EnduranceExpectation.replayToleranceMeters,
            """
            the journal replay produced \(hike.distanceMeters) m where the \
            live accumulator produced \(live) m (seed \(walk.seed))
            """
        )
        #expect(
            hike.distanceMeters
                <= walk.plannedDistanceMeters + EnduranceExpectation.overCountMeters,
            """
            \(hike.distanceMeters) m recorded for a \
            \(walk.plannedDistanceMeters) m walk — distance is being double \
            counted (seed \(walk.seed))
            """
        )
        #expect(
            hike.distanceMeters >= walk.plannedDistanceMeters
                * (1 - EnduranceExpectation.underCountFraction),
            """
            \(hike.distanceMeters) m recorded for a \
            \(walk.plannedDistanceMeters) m walk — more was lost than three \
            stationary windows can account for (seed \(walk.seed))
            """
        )
    }

    private func expectElevationSurvived(
        _ hike: Hike,
        live: Double?,
        seed: UInt64
    ) {
        let profile = RouteProfile(route: hike.route)
        guard let gain = profile.elevation.gainMeters else {
            Issue.record(
                "a route that climbs three times reported no elevation gain (seed \(seed))"
            )
            return
        }
        #expect(gain > 0, "the saved route reports no climb (seed \(seed))")
        guard let live else {
            Issue.record("the recorder reported no live elevation gain (seed \(seed))")
            return
        }
        #expect(
            abs(gain - live) <= EnduranceExpectation.elevationToleranceMeters,
            """
            the saved profile reports \(gain) m of gain where the recorder \
            reported \(live) m (seed \(seed))
            """
        )
        let distance = profile.distances.last ?? 0
        #expect(
            distance >= hike.distanceMeters,
            """
            the route profile measures \(distance) m, less than the \
            \(hike.distanceMeters) m the hike stores — the accumulator can \
            only ever come in under a plain sum of the same legs (seed \(seed))
            """
        )
        #expect(
            distance - hike.distanceMeters
                <= hike.distanceMeters * EnduranceExpectation.profileExcessFraction,
            """
            the route profile measures \(distance) m where the hike stores \
            \(hike.distanceMeters) m — more than three stationary windows \
            can account for (seed \(seed))
            """
        )
    }

    private func expectWidgetPolylineKeptTheShape(
        _ polyline: [SharedTrailSnapshot.CodableCoordinate],
        of route: [RouteCoordinate],
        seed: UInt64
    ) {
        #expect(
            polyline.count <= EnduranceExpectation.widgetPolylineBudget,
            """
            the widget polyline grew to \(polyline.count) points over a \
            \(route.count) point route (seed \(seed))
            """
        )
        #expect(
            polyline.count > 2,
            "the widget polyline collapsed to \(polyline.count) points (seed \(seed))"
        )
        guard let first = polyline.first,
              let last = polyline.last,
              let routeFirst = route.first,
              let routeLast = route.last else {
            Issue.record("the widget polyline is empty (seed \(seed))")
            return
        }
        #expect(
            RouteGeometry.distanceMeters(
                from: CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude),
                to: CLLocationCoordinate2D(latitude: routeFirst.latitude, longitude: routeFirst.longitude)
            ) < EnduranceExpectation.boundingBoxToleranceMeters,
            "the widget polyline does not start at the start of the walk (seed \(seed))"
        )
        #expect(
            RouteGeometry.distanceMeters(
                from: CLLocationCoordinate2D(latitude: last.latitude, longitude: last.longitude),
                to: CLLocationCoordinate2D(latitude: routeLast.latitude, longitude: routeLast.longitude)
            ) < EnduranceExpectation.boundingBoxToleranceMeters,
            "the widget polyline does not end at the end of the walk (seed \(seed))"
        )
        expectBoundingBoxSurvived(polyline, of: route, seed: seed)
    }

    private func expectBoundingBoxSurvived(
        _ polyline: [SharedTrailSnapshot.CodableCoordinate],
        of route: [RouteCoordinate],
        seed: UInt64
    ) {
        let latitudes = polyline.map(\.latitude)
        let longitudes = polyline.map(\.longitude)
        let routeLatitudes = route.map(\.latitude)
        let routeLongitudes = route.map(\.longitude)
        guard let low = latitudes.min(), let high = latitudes.max(),
              let west = longitudes.min(), let east = longitudes.max(),
              let routeLow = routeLatitudes.min(), let routeHigh = routeLatitudes.max(),
              let routeWest = routeLongitudes.min(), let routeEast = routeLongitudes.max() else {
            Issue.record("the widget polyline has no extent (seed \(seed))")
            return
        }
        let latitudeSpan = (high - low) * Endurance.metersPerDegreeLatitude
        let routeLatitudeSpan = (routeHigh - routeLow) * Endurance.metersPerDegreeLatitude
        let longitudeSpan = (east - west) * Endurance.metersPerDegreeLongitude
        let routeLongitudeSpan = (routeEast - routeWest) * Endurance.metersPerDegreeLongitude
        #expect(
            routeLatitudeSpan - latitudeSpan < EnduranceExpectation.boundingBoxToleranceMeters,
            """
            decimation lost \(routeLatitudeSpan - latitudeSpan) m of the \
            route's north-south extent (seed \(seed))
            """
        )
        #expect(
            routeLongitudeSpan - longitudeSpan < EnduranceExpectation.boundingBoxToleranceMeters,
            """
            decimation lost \(routeLongitudeSpan - longitudeSpan) m of the \
            route's east-west extent (seed \(seed))
            """
        )
    }
}
