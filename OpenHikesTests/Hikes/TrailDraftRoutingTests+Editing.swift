//
//  TrailDraftRoutingTests+Editing.swift
//  OpenHikesTests
//
//  What editing a drawn line costs on the wire.
//
//  Phase 2's rule was *one question per leg, once*, and it was easy to keep
//  while a line could only grow. Phase 3 rearranges the list underneath the
//  legs, and every one of the six operations could plausibly re-ask for all of
//  them: a reorder that keyed legs on their position rather than on their two
//  ends would ask about every leg after the one that moved, a drag that asked
//  per frame would spend a request a sixtieth of a second, and an undo that
//  rebuilt from points alone would ask for the whole trail again.
//
//  None of those is visible on screen — the line ends up right either way —
//  and all of them are visible to a volunteer-run API that has already
//  rate-limited this app in the field. So they are pinned here, by *which*
//  legs were asked about rather than only by how many.
//
//  ``TrailDraftEditingTests`` owns what each operation does to the list, and
//  ``TrailDraftHistoryTests`` owns the memo these claims rest on.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

extension TrailDraftRoutingTests {
    /// Four points on one line of longitude, far enough apart that no two are
    /// the same place.
    private enum Trail {
        static let longitude: Double = 12.8317
        static let first: Double = 47.7100
        static let second: Double = 47.7120
        static let third: Double = 47.7140
        static let fourth: Double = 47.7160
        static let elsewhere: Double = 47.7300
        static let all: [Double] = [first, second, third, fourth]
    }

    private static func place(_ latitude: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: Trail.longitude)
    }

    private static func waypoint(_ latitude: Double) -> TrailWaypoint {
        TrailWaypoint(coordinate: place(latitude))
    }

    private static func ends(_ from: Double, _ to: Double) -> TrailLegEnds {
        TrailLegEnds(from: waypoint(from), to: waypoint(to))
    }

    /// A maker with `latitudes` drawn on it, every leg already answered.
    private static func drawn(
        _ latitudes: [Double],
        over router: StubTrailLegRouter
    ) async -> TrailDraftController {
        let maker = TrailDraftController(router: router)
        maker.setEditing(true)
        for latitude in latitudes { maker.appendWaypoint(at: place(latitude)) }
        await settleDelegateHop(until: "the drawn line to settle") {
            maker.draft.legs.allSatisfy { $0.snap == .snapped }
        }
        return maker
    }

    // MARK: Rearranging

    /// The claim the whole of Phase 2's caching was built for: legs are keyed
    /// on the two *places* they run between, so moving a row that leaves an
    /// adjacency intact leaves that leg alone.
    @Test("a reorder re-resolves only the legs whose ends changed")
    func reorderAsksOnlyForWhatMoved() async {
        let router = StubTrailLegRouter(answering: .snapped)
        let maker = await Self.drawn(Trail.all, over: router)
        #expect(await router.askedCount() == 3)

        // A, B, C, D → A, D, B, C. Only B→C survives.
        maker.reorderWaypoints(fromOffsets: IndexSet([3]), toOffset: 1)

        await settleDelegateHop(until: "the two new legs to settle") {
            maker.draft.legs.allSatisfy { $0.snap == .snapped }
        }
        let asked = await router.askedEnds()
        #expect(asked.count == 5, "three legs drawn, two adjacencies made")
        #expect(
            Set(asked.suffix(2)) == [
                Self.ends(Trail.first, Trail.fourth),
                Self.ends(Trail.fourth, Trail.second),
            ]
        )
    }

    /// Reversing a trail changes every leg's direction and therefore every
    /// leg's key — and asks for none of them, because a walking path between
    /// two places is the same path either way and the shapes are simply turned
    /// round. See ``TrailDraft/reverse()``.
    @Test("reversing the line asks for nothing")
    func reversingAsksNothing() async {
        let router = StubTrailLegRouter(answering: .snapped)
        let maker = await Self.drawn(Trail.all, over: router)

        maker.reverse()

        await settleDelegateHop()
        #expect(await router.askedCount() == 3)
        #expect(maker.draft.legs.allSatisfy { $0.snap == .snapped })
    }

    @Test("deleting a point asks only about the leg that replaces two")
    func deletingAsksOnce() async {
        let router = StubTrailLegRouter(answering: .snapped)
        let maker = await Self.drawn(Trail.all, over: router)

        maker.removeWaypoints(atOffsets: IndexSet([1]))

        await settleDelegateHop(until: "the rejoined leg to settle") {
            maker.draft.legs.allSatisfy { $0.snap == .snapped }
        }
        let asked = await router.askedEnds()
        #expect(asked.count == 4)
        #expect(asked.last == Self.ends(Trail.first, Trail.third))
    }

    @Test("adding a stop into a leg asks about the two it became")
    func insertingAsksTwice() async {
        let router = StubTrailLegRouter(answering: .snapped)
        let maker = await Self.drawn([Trail.first, Trail.fourth], over: router)

        maker.addStop(at: Self.place(Trail.second), preferringLeg: 0)

        await settleDelegateHop(until: "the two new legs to settle") {
            maker.draft.legs.count == 2
                && maker.draft.legs.allSatisfy { $0.snap == .snapped }
        }
        let asked = await router.askedEnds()
        #expect(asked.count == 3)
        #expect(
            Set(asked.suffix(2)) == [
                Self.ends(Trail.first, Trail.second),
                Self.ends(Trail.second, Trail.fourth),
            ]
        )
    }

    /// Undo puts the shapes back from the drawing's own memory, so a hiker who
    /// undoes a delete does not pay for the whole trail again — which on a
    /// server that has just started refusing is the difference between a line
    /// that comes back and one that comes back straight.
    @Test("undoing an edit asks for nothing")
    func undoAsksNothing() async {
        let router = StubTrailLegRouter(answering: .snapped)
        let maker = await Self.drawn([Trail.first, Trail.second, Trail.third], over: router)
        maker.removeWaypoints(atOffsets: IndexSet([1]))
        await settleDelegateHop(until: "the rejoined leg to settle") {
            maker.draft.legs.allSatisfy { $0.snap == .snapped }
        }
        let beforeUndo = await router.askedCount()

        maker.undo()

        await settleDelegateHop()
        #expect(await router.askedCount() == beforeUndo)
        #expect(maker.draft.legs.count == 2)
        #expect(maker.draft.legs.allSatisfy { $0.snap == .snapped })
    }

    // MARK: A point under a finger

    /// The rule the untracked channel exists for, stated where it can be
    /// asserted: a drag is **one** edit however far the finger travels, and
    /// everything it costs is paid when the finger lifts.
    @Test("a drag asks nothing until it is let go")
    func draggingAsksNothingUntilItLands() async {
        let router = StubTrailLegRouter(answering: .snapped)
        let maker = await Self.drawn([Trail.first, Trail.second, Trail.third], over: router)

        #expect(maker.beginDrag(ofWaypointAt: 1))
        for latitude in stride(from: Trail.second, to: Trail.elsewhere, by: 0.002) {
            maker.dragWaypoint(to: Self.place(latitude))
        }

        await settleDelegateHop()
        #expect(await router.askedCount() == 2, "the line as it was, and nothing more")
        #expect(
            maker.draft.waypoints[1].latitude == Trail.second,
            "the list does not move until the finger lifts"
        )
    }

    @Test("letting go asks about the two legs the point is an end of")
    func droppingAsksAboutBothLegs() async {
        let router = StubTrailLegRouter(answering: .snapped)
        let maker = await Self.drawn([Trail.first, Trail.second, Trail.third], over: router)

        #expect(maker.beginDrag(ofWaypointAt: 1))
        maker.dragWaypoint(to: Self.place(Trail.elsewhere))
        #expect(maker.endDrag())

        await settleDelegateHop(until: "the two moved legs to settle") {
            maker.draft.legs.allSatisfy { $0.snap == .snapped }
        }
        let asked = await router.askedEnds()
        #expect(asked.count == 4)
        #expect(
            Set(asked.suffix(2)) == [
                Self.ends(Trail.first, Trail.elsewhere),
                Self.ends(Trail.elsewhere, Trail.third),
            ]
        )
    }

    /// A press held on a pin and released without travelling is not an edit,
    /// so it costs no request, no store write and no step of undo.
    @Test("a drag that went nowhere is not an edit")
    func aDragThatWentNowhere() async {
        let router = StubTrailLegRouter(answering: .snapped)
        let maker = await Self.drawn([Trail.first, Trail.second], over: router)

        #expect(maker.beginDrag(ofWaypointAt: 1))
        #expect(!maker.endDrag())

        await settleDelegateHop()
        #expect(await router.askedCount() == 1)
        // No step was taken either, which is what undoing once shows: the
        // thing it comes back from is the second point going down.
        maker.draft.undo()
        #expect(maker.draft.waypoints.count == 1)
    }

    @Test("a cancelled drag puts the point back and asks nothing")
    func aCancelledDrag() async {
        let router = StubTrailLegRouter(answering: .snapped)
        let maker = await Self.drawn([Trail.first, Trail.second], over: router)

        #expect(maker.beginDrag(ofWaypointAt: 1))
        maker.dragWaypoint(to: Self.place(Trail.elsewhere))
        maker.cancelDrag()

        await settleDelegateHop()
        #expect(maker.draft.drag == nil)
        #expect(maker.draft.waypoints[1].latitude == Trail.second)
        #expect(await router.askedCount() == 1)
    }

    /// The screen going away takes the finger with it — a drag left held would
    /// be a pin the map is no longer drawing, waiting for a gesture that
    /// cannot end.
    @Test("closing the maker lets go of whatever was being dragged")
    func closingLetsGo() async {
        let router = StubTrailLegRouter(answering: .snapped)
        let maker = await Self.drawn([Trail.first, Trail.second], over: router)
        #expect(maker.beginDrag(ofWaypointAt: 1))

        maker.setEditing(false)

        #expect(maker.draft.drag == nil)
        #expect(maker.draft.waypoints[1].latitude == Trail.second)
    }

    @Test("nothing can be taken hold of while the maker is closed")
    func closedMakersHoldNothing() {
        let maker = TrailDraftController(router: StubTrailLegRouter(answering: .snapped))
        maker.setEditing(true)
        maker.appendWaypoint(at: Self.place(Trail.first))
        maker.setEditing(false)

        #expect(!maker.beginDrag(ofWaypointAt: 0))
    }

    // MARK: What is written down

    /// Every edit is written down as it happens, for the reason a point going
    /// down is: a hiker who takes a call mid-rearrange comes back to the trail
    /// they were rearranging rather than to the one before it.
    @Test("an edit is written down as it happens")
    func editsArePersisted() throws {
        let store = TrailDraftStore(context: try Fixture.modelContext())
        let maker = TrailDraftController(
            store: store,
            router: StubTrailLegRouter(answering: .snapped)
        )
        maker.setEditing(true)
        for latitude in Trail.all { maker.appendWaypoint(at: Self.place(latitude)) }

        maker.removeWaypoints(atOffsets: IndexSet([0]))

        #expect(store.load().waypoints.count == 3)
        #expect(store.load().waypoints.first?.latitude == Trail.second)
    }

    /// And a drag is written down **once**, when it lands. A store write per
    /// frame is a disk write per frame.
    @Test("a drag is written down when it lands and not before")
    func aDragIsPersistedOnce() throws {
        let store = TrailDraftStore(context: try Fixture.modelContext())
        let maker = TrailDraftController(store: store, router: nil)
        maker.setEditing(true)
        maker.appendWaypoint(at: Self.place(Trail.first))
        maker.appendWaypoint(at: Self.place(Trail.second))

        #expect(maker.beginDrag(ofWaypointAt: 1))
        maker.dragWaypoint(to: Self.place(Trail.elsewhere))
        #expect(store.load().waypoints.last?.latitude == Trail.second)

        #expect(maker.endDrag())
        #expect(store.load().waypoints.last?.latitude == Trail.elsewhere)
    }
}
