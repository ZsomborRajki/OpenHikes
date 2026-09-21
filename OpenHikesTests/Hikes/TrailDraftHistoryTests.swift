//
//  TrailDraftHistoryTests.swift
//  OpenHikesTests
//
//  Undo, redo, and the one claim that is not about the list of points.
//
//  The stacks themselves are ordinary and are asserted as such. What is worth
//  the file is the third claim: **undo restores the resolved geometry rather
//  than re-fetching it.** A snapshot holds points and nothing else, so an undo
//  that took its legs from nowhere would put a snapped line back as a straight
//  one and then ask Overpass for every leg of it — which on a busy server is
//  a hiker watching their own trail come back wrong. ``TrailLegMemo`` is what
//  makes that untrue, and this is where it is pinned from the draft's side;
//  ``TrailDraftRoutingTests`` pins the half about who is asked.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Trail draft history")
struct TrailDraftHistoryTests {
    private enum Line {
        static let longitude: Double = 12.8317
        static let first: Double = 47.7100
        static let second: Double = 47.7120
        static let third: Double = 47.7140
        static let detour: Double = 47.7300
    }

    private static func coordinate(_ latitude: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: Line.longitude)
    }

    private static func draft(_ latitudes: [Double]) -> TrailDraft {
        let draft = TrailDraft()
        for latitude in latitudes { draft.append(coordinate(latitude)) }
        return draft
    }

    private static func latitudes(of draft: TrailDraft) -> [Double] {
        draft.waypoints.map(\.latitude)
    }

    /// Gives every leg of `draft` a shape, the way a router's answers would.
    ///
    /// A bulge in the middle, so a restored leg is recognisable as the one
    /// that was resolved rather than as the straight line between the same two
    /// points.
    private static func resolveLegs(of draft: TrailDraft) {
        // Marked as asked about first, for the reason the controller does it
        // in the same turn it asks: an answer is only taken by a leg that is
        // waiting for one.
        draft.beginRouting(draft.legs.map(\.ends))
        for leg in draft.legs {
            draft.apply(
                TrailLegRoute(
                    coordinates: [
                        leg.ends.start,
                        RouteCoordinate(latitude: Line.detour, longitude: Line.longitude),
                        leg.ends.end,
                    ],
                    distanceMeters: 4321,
                    snap: .snapped
                ),
                to: leg.ends
            )
        }
    }

    // MARK: The stacks

    @Test("a new draft has nothing to undo or redo")
    func nothingToUndo() {
        let draft = TrailDraft()
        #expect(!draft.canUndo)
        #expect(!draft.canRedo)
    }

    @Test("undo takes the last point back off")
    func undoingAnAppend() {
        let draft = Self.draft([Line.first, Line.second])

        draft.undo()

        #expect(Self.latitudes(of: draft) == [Line.first])
        #expect(draft.canRedo)
    }

    @Test("redo puts it back")
    func redoing() {
        let draft = Self.draft([Line.first, Line.second])
        draft.undo()

        draft.redo()

        #expect(Self.latitudes(of: draft) == [Line.first, Line.second])
        #expect(!draft.canRedo)
    }

    @Test("undo walks back through every kind of edit")
    func undoingEachOperation() {
        let draft = Self.draft([Line.first, Line.second, Line.third])
        draft.reverse()
        draft.remove(atOffsets: IndexSet([0]))
        draft.closeTheLoop()

        draft.undo()
        #expect(Self.latitudes(of: draft) == [Line.second, Line.first])
        draft.undo()
        #expect(Self.latitudes(of: draft) == [Line.third, Line.second, Line.first])
        draft.undo()
        #expect(Self.latitudes(of: draft) == [Line.first, Line.second, Line.third])
    }

    /// The standard rule, and the one a hiker would otherwise be bitten by:
    /// the redo stack describes a branch that has been left, so drawing
    /// something new abandons it rather than offering to replace the new line
    /// with an unrelated one.
    @Test("drawing again after an undo abandons the redo")
    func editingClearsTheRedo() {
        let draft = Self.draft([Line.first, Line.second])
        draft.undo()
        #expect(draft.canRedo)

        draft.append(Self.coordinate(Line.third))

        #expect(!draft.canRedo)
        #expect(Self.latitudes(of: draft) == [Line.first, Line.third])
    }

    @Test("the history is bounded")
    func theHistoryIsBounded() {
        var history = TrailDraftHistory()
        for _ in 0...TrailDraftHistory.depth {
            history.record([TrailWaypoint(coordinate: Self.coordinate(Line.first))])
        }
        #expect(history.past.count == TrailDraftHistory.depth)
    }

    /// A restored draft is a different drawing, so the steps behind the last
    /// one go with it — an undo that reached past a restore would offer a line
    /// from a session that has ended.
    @Test("restoring a draft from disk forgets what came before it")
    func restoringForgetsTheHistory() {
        let draft = Self.draft([Line.first, Line.second])

        draft.replace(
            with: [TrailWaypoint(coordinate: Self.coordinate(Line.third))],
            snapsToPaths: true
        )

        #expect(!draft.canUndo)
        #expect(!draft.canRedo)
    }

    // MARK: The geometry

    @Test("undoing a delete brings the resolved legs back, not straight ones")
    func undoRestoresTheGeometry() throws {
        let draft = Self.draft([Line.first, Line.second, Line.third])
        Self.resolveLegs(of: draft)
        #expect(draft.legs.allSatisfy { $0.snap == .snapped })

        draft.remove(atOffsets: IndexSet([1]))
        draft.undo()

        #expect(
            draft.legs.allSatisfy { $0.snap == .snapped },
            "the shapes this drawing was given are remembered, not re-fetched"
        )
        let first = try #require(draft.legs.first)
        #expect(first.coordinates.count == 3, "the bulge is back")
        #expect(first.distanceMeters == 4321)
    }

    /// The same memo, reached the other way round: a point dragged away and
    /// dropped back where it started finds the legs it had.
    @Test("moving a point back restores the legs it had")
    func movingBackRestoresTheGeometry() {
        let draft = Self.draft([Line.first, Line.second])
        Self.resolveLegs(of: draft)

        draft.move(waypointAt: 1, to: Self.coordinate(Line.third))
        #expect(draft.legs.first?.snap == .freehand, "a new adjacency has no shape yet")

        draft.move(waypointAt: 1, to: Self.coordinate(Line.second))

        #expect(draft.legs.first?.snap == .snapped)
    }

    /// The memo holds snapped legs, and a hiker who has turned path-following
    /// off has asked for straight ones. Handing a remembered shape back would
    /// put a path on a line they asked to be straight — silently, because a
    /// straightened leg and a straight one look identical.
    @Test("a remembered shape is not handed back while path-following is off")
    func rememberedShapesRespectTheToggle() {
        let draft = Self.draft([Line.first, Line.second, Line.third])
        Self.resolveLegs(of: draft)
        draft.setSnapsToPaths(false)

        draft.remove(atOffsets: IndexSet([1]))
        draft.undo()

        #expect(draft.legs.allSatisfy { $0.snap == .freehand })
    }
}
