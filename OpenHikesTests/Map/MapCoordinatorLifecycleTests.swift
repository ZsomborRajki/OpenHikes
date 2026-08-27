//
//  MapCoordinatorLifecycleTests.swift
//  OpenHikesTests
//
//  The one piece of the map that changes at GPS frequency is the recording
//  trace, and `MapView.Coordinator` refuses to draw it while the app is in the
//  background: an `MKPolyline` allocation and a MapKit overlay swap per fix,
//  for every fix of a six-hour walk, producing output nobody is looking at.
//  What it does instead is keep tracking the revision and catch the whole
//  thing up in a single pass on return.
//
//  Both halves of that need pinning, and they are easy to confuse. "Nothing
//  was drawn" is trivially satisfiable by a coordinator that stopped observing
//  the trace altogether — which would also mean the map never woke up again,
//  and the walker would come back to a line that ends where they backgrounded
//  the app. So the tests below separate the two: a second coordinator, created
//  after the notification and therefore still in the foreground, watches the
//  same trace and draws every fix, which is both the proof that the revisions
//  really were reaching the coordinators and a measure of the per-fix cost the
//  backgrounded one avoided.
//
//  Driven through `NotificationCenter` rather than `scenePhase` because that is
//  what the coordinator observes — deliberately, so this gate stays off
//  SwiftUI's render path entirely.
//

#if os(iOS)
import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import Testing
import UIKit

/// An `MKMapView` that counts the overlay traffic sent to it.
///
/// The claim under test is about cost rather than about the picture: a
/// backgrounded recording and a foregrounded one converge on the same
/// overlays, and what separates them is how many were allocated and installed
/// on the way there.
final class OverlayCountingMapView: MKMapView {
    private(set) var addOverlayCount = 0
    private(set) var removeOverlayCount = 0

    override func addOverlay(_ overlay: MKOverlay, level: MKOverlayLevel) {
        addOverlayCount += 1
        super.addOverlay(overlay, level: level)
    }

    override func removeOverlay(_ overlay: MKOverlay) {
        removeOverlayCount += 1
        super.removeOverlay(overlay)
    }
}

/// Records that an app-lifecycle notification reached its observers, so a test
/// can wait for the delivery rather than assume it.
@MainActor
final class LifecycleDeliverySentinel {
    private(set) var isDelivered = false

    func markDelivered() {
        isDelivered = true
    }
}

@MainActor
@Suite("Map coordinator app lifecycle")
struct MapCoordinatorLifecycleTests {
    /// Points about 1.1 m apart, comfortably past the 5 cm below which the
    /// trace treats a fix as noise, so every appended coordinate is a fix the
    /// map is expected to know about.
    static func route(_ count: Int) -> [CLLocationCoordinate2D] {
        (0..<count).map { index in
            CLLocationCoordinate2D(
                latitude: 47.63 + Double(index) * 0.00001,
                longitude: 12.86
            )
        }
    }

    /// A map with a size, so MapKit has a visible rect to reason about. Views
    /// under test are never in a window.
    static func makeMap() -> OverlayCountingMapView {
        let map = OverlayCountingMapView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844)
        )
        map.layoutIfNeeded()
        return map
    }

    /// Hands MapKit's machinery back before the test ends: the coordinator that
    /// owns these overlays is about to deallocate.
    static func detach(_ map: MKMapView) {
        map.delegate = nil
        map.removeOverlays(map.overlays)
    }

    /// Posts an app-lifecycle notification and returns once the observers
    /// registered before this call have handled it.
    ///
    /// The coordinator observes on `OperationQueue.main`, so its block is
    /// *scheduled* by the post rather than run by it. A sentinel registered on
    /// the same queue afterwards is scheduled behind it, which turns "the
    /// notification has been delivered" into an effect a test can wait for
    /// instead of a number of scheduler turns it has to guess at.
    static func post(lifecycle name: Notification.Name) async {
        let sentinel = LifecycleDeliverySentinel()
        let token = NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { sentinel.markDelivered() }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        NotificationCenter.default.post(name: name, object: nil)
        await settleDelegateHop(until: "\(name.rawValue) to reach the observers registered before it") {
            sentinel.isDelivered
        }
    }

    /// Every coordinator alive in this process shares these notifications, so a
    /// test that leaves one backgrounded leaves it backgrounded for the whole
    /// bundle.
    static func restoreForeground() {
        NotificationCenter.default.post(
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    @Test("a backgrounded map draws no fix, then draws them all in one pass")
    func backgroundedFixesAreDeferredAndCaughtUpOnce() async throws {
        let seededPoints = 2
        let backgroundedFixes = 5
        let route = Self.route(seededPoints + backgroundedFixes + 1)
        let trace = RecordingTrace()
        for index in 0..<seededPoints {
            trace.append(route[index])
        }

        let backgrounded = MapView.Coordinator()
        let backgroundedMap = Self.makeMap()
        defer {
            Self.restoreForeground()
            Self.detach(backgroundedMap)
        }
        backgrounded.observeRecordingTrace(trace, on: backgroundedMap)
        let seededOverlay = try #require(backgrounded.recordingTailOverlay)
        #expect(seededOverlay.pointCount == seededPoints)
        let addsBeforeLeaving = backgroundedMap.addOverlayCount
        let removesBeforeLeaving = backgroundedMap.removeOverlayCount
        let revisionBeforeLeaving = trace.revision

        await Self.post(lifecycle: UIApplication.didEnterBackgroundNotification)

        // Built after the notification, so it never saw it and is still
        // drawing. Same trace, same fixes, one map in each state.
        let stillForeground = MapView.Coordinator()
        let stillForegroundMap = Self.makeMap()
        defer { Self.detach(stillForegroundMap) }
        stillForeground.observeRecordingTrace(trace, on: stillForegroundMap)
        let twinAddsBeforeTheFixes = stillForegroundMap.addOverlayCount

        for index in seededPoints..<(seededPoints + backgroundedFixes) {
            trace.append(route[index])
            // Waiting on the twin is what makes the assertions below mean
            // something: once it has drawn fix `index`, the revision that
            // carried it has been through the main actor, and the backgrounded
            // coordinator has had the same chance to draw it.
            await settleDelegateHop(until: "the foreground twin to draw fix \(index)") {
                stillForeground.recordingTailOverlay?.pointCount == index + 1
            }
        }

        let drawnWhileAway = try #require(backgrounded.recordingTailOverlay)
        #expect(drawnWhileAway === seededOverlay, "the line on the backgrounded map was never rebuilt")
        #expect(drawnWhileAway.pointCount == seededPoints)
        #expect(backgroundedMap.addOverlayCount == addsBeforeLeaving)
        #expect(backgroundedMap.removeOverlayCount == removesBeforeLeaving)
        #expect(
            trace.revision > revisionBeforeLeaving,
            "the trace has to have gone on accumulating, or nothing was deferred"
        )
        #expect(
            stillForegroundMap.addOverlayCount == twinAddsBeforeTheFixes + backgroundedFixes,
            "a polyline per fix is exactly what the backgrounded map did not pay for"
        )

        await Self.post(lifecycle: UIApplication.willEnterForegroundNotification)
        await settleDelegateHop(until: "the backgrounded map to catch up on its return") {
            backgrounded.recordingTailOverlay?.pointCount == seededPoints + backgroundedFixes
        }

        #expect(
            backgroundedMap.addOverlayCount == addsBeforeLeaving + 1,
            "five fixes have to cost one overlay on return, not five"
        )
        #expect(backgroundedMap.removeOverlayCount == removesBeforeLeaving + 1)

        // The catch-up alone cannot tell a coordinator that kept tracking from
        // one that read the trace once on its way back in. A fix delivered now
        // can: only a live registration draws it.
        trace.append(route[route.count - 1])
        await settleDelegateHop(until: "a fix after the return to be drawn") {
            backgrounded.recordingTailOverlay?.pointCount == route.count
        }
        #expect(backgroundedMap.addOverlayCount == addsBeforeLeaving + 2)
    }

    /// The case the deferral is actually for: a walk long enough for the trace
    /// to seal a chunk while the phone is in a pocket. Coming back has to
    /// install the sealed chunk *and* the tail, and that is the whole bill for
    /// the absence.
    @Test("an absence long enough to seal a chunk still costs one pass")
    func aSealedChunkIsCaughtUpInOnePass() async throws {
        let seededPoints = 2
        let totalPoints = 300
        let route = Self.route(totalPoints)
        let trace = RecordingTrace()
        for index in 0..<seededPoints {
            trace.append(route[index])
        }

        let coordinator = MapView.Coordinator()
        let map = Self.makeMap()
        defer {
            Self.restoreForeground()
            Self.detach(map)
        }
        coordinator.observeRecordingTrace(trace, on: map)
        let addsBeforeLeaving = map.addOverlayCount

        await Self.post(lifecycle: UIApplication.didEnterBackgroundNotification)
        for index in seededPoints..<totalPoints {
            trace.append(route[index])
        }
        #expect(trace.committedChunks.count == 1, "the absence has to cross a seal to be the case described")

        await Self.post(lifecycle: UIApplication.willEnterForegroundNotification)
        await settleDelegateHop(until: "the sealed chunk and the tail to be installed") {
            coordinator.recordingChunkOverlays.count == 1
                && coordinator.recordingTailOverlay != nil
        }

        let chunk = try #require(coordinator.recordingChunkOverlays.first)
        #expect(chunk.pointCount == RecordingTrace.chunkSize)
        let tail = try #require(coordinator.recordingTailOverlay)
        #expect(tail.pointCount == trace.tail.count)
        #expect(
            map.addOverlayCount == addsBeforeLeaving + 2,
            "298 deferred fixes are worth one chunk and one tail, whatever else happened while away"
        )
    }
}
#endif
