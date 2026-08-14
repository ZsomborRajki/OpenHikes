//
//  RecordingTraceTests.swift
//  OpenTrailsTests
//
//  `RecordingTrace` is the one model a recording writes on every accepted fix,
//  and `MapCoordinator` redraws an `MKPolyline` for every revision it
//  publishes. That makes two properties worth pinning, neither of which is
//  visible by reading a body:
//
//  * a revision means the drawn line is stale — publishing one for geometry
//    that did not move costs an allocation and a MapKit overlay swap to draw
//    the same line, and a stationary recorder produces exactly that case
//    repeatedly; and
//  * the stable prefix of `tail` is cached across rebuilds so that a fix costs
//    the provisional remainder rather than the whole tail, which means every
//    path that empties or commits underneath that prefix has to invalidate it.
//
//  The performance harness measures the first property as a per-fix ratio
//  (see PERFORMANCE.md); these tests are what say *why* the ratio is what it
//  is, and they fail long before a UI test would.
//

import CoreLocation
import Testing

@testable import OpenTrails

@MainActor
@Suite("Recording trace")
struct RecordingTraceTests {
    /// A stationary recorder produces the same matched geometry over and over.
    /// Publishing a revision for each one costs an `MKPolyline` allocation and
    /// a MapKit overlay swap to redraw a line that has not moved, so the trace
    /// is expected to notice and stay quiet.
    @Test("a live match that changes nothing publishes no revision")
    func identicalLiveMatchIsNotPublished() {
        let trace = RecordingTrace()
        let generation = trace.generation
        trace.append(
            CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86),
            provisional: true
        )
        let matched = [
            CLLocationCoordinate2D(latitude: 47.6301, longitude: 12.8599),
            CLLocationCoordinate2D(latitude: 47.6302, longitude: 12.8599),
        ]
        #expect(trace.applyLiveMatch(
            committing: [],
            provisional: matched,
            expectedGeneration: generation
        ))
        let settled = trace.revision
        let settledTail = trace.tailRevision

        #expect(trace.applyLiveMatch(
            committing: [],
            provisional: matched,
            expectedGeneration: generation
        ))

        #expect(trace.revision == settled)
        #expect(trace.tailRevision == settledTail)
        #expect(trace.tail.count == matched.count)
    }

    /// The counterpart: the optimisation above must not swallow a real move.
    @Test("a live match that moves the tail still publishes")
    func movedLiveMatchIsPublished() {
        let trace = RecordingTrace()
        let generation = trace.generation
        trace.append(
            CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86),
            provisional: true
        )
        let settled = trace.revision

        #expect(trace.applyLiveMatch(
            committing: [],
            provisional: [
                CLLocationCoordinate2D(latitude: 47.6305, longitude: 12.8599),
            ],
            expectedGeneration: generation
        ))

        #expect(trace.revision != settled)
        #expect(trace.tail.count == 1)
        #expect(abs(trace.tail[0].latitude - 47.6305) < 0.000001)
    }

    /// The stable prefix of `tail` is cached across rebuilds, so the case that
    /// invalidates it — a match committing new stable points underneath the
    /// provisional ones — has to produce the same tail a full rebuild would.
    @Test("committing stable points rebuilds the tail beneath the provisional one")
    func committedPointsSurviveTheCachedPrefix() {
        let trace = RecordingTrace()
        let generation = trace.generation
        trace.append(
            CLLocationCoordinate2D(latitude: 47.6300, longitude: 12.8600),
            provisional: true
        )
        #expect(trace.applyLiveMatch(
            committing: [
                CLLocationCoordinate2D(latitude: 47.6300, longitude: 12.8599),
            ],
            provisional: [
                CLLocationCoordinate2D(latitude: 47.6310, longitude: 12.8599),
            ],
            expectedGeneration: generation
        ))
        #expect(trace.tail.count == 2)

        #expect(trace.applyLiveMatch(
            committing: [
                CLLocationCoordinate2D(latitude: 47.6320, longitude: 12.8599),
            ],
            provisional: [
                CLLocationCoordinate2D(latitude: 47.6330, longitude: 12.8599),
            ],
            expectedGeneration: generation
        ))

        #expect(trace.tail.count == 3)
        #expect(abs(trace.tail[0].latitude - 47.6300) < 0.000001)
        #expect(abs(trace.tail[1].latitude - 47.6320) < 0.000001)
        #expect(abs(trace.tail[2].latitude - 47.6330) < 0.000001)
    }

    /// `reset()` and `replace(with:)` empty the tail without going through
    /// `rebuildTail()`, so the cached prefix length has to be cleared with it —
    /// otherwise the next rebuild trusts a description of a tail that is gone.
    @Test("resetting clears the cached tail prefix")
    func resetInvalidatesTheCachedPrefix() {
        let trace = RecordingTrace()
        trace.append(
            CLLocationCoordinate2D(latitude: 47.6300, longitude: 12.8600)
        )
        trace.append(
            CLLocationCoordinate2D(latitude: 47.6310, longitude: 12.8600)
        )
        #expect(trace.tail.count == 2)

        trace.reset()
        #expect(trace.tail.isEmpty)

        trace.append(
            CLLocationCoordinate2D(latitude: 47.6400, longitude: 12.8700),
            provisional: true
        )
        #expect(trace.tail.count == 1)
        #expect(abs(trace.tail[0].latitude - 47.6400) < 0.000001)
    }

    /// A recorder standing still keeps delivering fixes, and every one of them
    /// is dropped as too close to the last. Publishing a revision for those
    /// would rebuild an `MKPolyline` to draw the line already on screen.
    @Test("a fix too close to the last publishes nothing")
    func stationaryFixPublishesNothing() {
        let trace = RecordingTrace()
        trace.append(
            CLLocationCoordinate2D(latitude: 47.6300, longitude: 12.8600)
        )
        let revision = trace.revision
        let tailRevision = trace.tailRevision

        trace.append(
            CLLocationCoordinate2D(latitude: 47.6300, longitude: 12.8600)
        )

        #expect(trace.tail.count == 1)
        #expect(trace.revision == revision)
        #expect(trace.tailRevision == tailRevision)
    }

    /// The dropped fix must not invalidate the prefix cache either: the next
    /// real fix has to produce the tail a full rebuild would have.
    @Test("a dropped fix leaves the cached prefix usable")
    func droppedFixKeepsTheCachedPrefixCorrect() {
        let trace = RecordingTrace()
        trace.append(
            CLLocationCoordinate2D(latitude: 47.6300, longitude: 12.8600)
        )
        trace.append(
            CLLocationCoordinate2D(latitude: 47.6300, longitude: 12.8600)
        )
        trace.append(
            CLLocationCoordinate2D(latitude: 47.6310, longitude: 12.8600)
        )

        #expect(trace.tail.count == 2)
        #expect(abs(trace.tail[0].latitude - 47.6300) < 0.000001)
        #expect(abs(trace.tail[1].latitude - 47.6310) < 0.000001)
    }

}
