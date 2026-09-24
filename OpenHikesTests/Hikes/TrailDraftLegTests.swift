//
//  TrailDraftLegTests.swift
//  OpenHikesTests
//
//  The legs between the points: what they are made of, what they measure, and
//  what survives a change to the list around them.
//
//  ``TrailDraftTests`` next door owns the arithmetic of a straight draft.
//  What is worth asserting here is everything Phase 2 added underneath those
//  numbers, and the two claims the phases after this one will lean on:
//
//  - **A resolved leg survives a change to the list.** Reuse is keyed on the
//    two *places* rather than on the two waypoints, so appending a point
//    re-asks about one leg rather than all of them. Phase 3's reorder is the
//    same claim with the points shuffled.
//  - **An answer is applied to the leg that asked, or to nothing.** Matching
//    by ends rather than by index is what makes a late answer safe, and it is
//    invisible until the day a hiker taps twice while a route is in flight.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@MainActor
@Suite("Trail draft legs")
struct TrailDraftLegTests {
    private enum Line {
        static let longitude: Double = 12.8317
        static let south: Double = 47.7180
        static let middle: Double = 47.7190
        static let north: Double = 47.7200
    }

    private static func coordinate(_ latitude: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: Line.longitude)
    }

    private static func draft(_ latitudes: [Double]) -> TrailDraft {
        let draft = TrailDraft()
        for latitude in latitudes { draft.append(coordinate(latitude)) }
        return draft
    }

    /// A route that pretends to have followed a path: the same two ends with
    /// a detour through a third point, so it is longer than the straight line
    /// and distinguishable from it.
    private static func detour(along ends: TrailLegEnds) -> TrailLegRoute {
        let bulge = RouteCoordinate(
            latitude: (ends.start.latitude + ends.end.latitude) / 2,
            longitude: Line.longitude + 0.01
        )
        let coordinates = [ends.start, bulge, ends.end]
        return TrailLegRoute(
            coordinates: coordinates,
            distanceMeters: ends.straightDistanceMeters * 2,
            snap: .snapped
        )
    }

    // MARK: Shape

    @Test("a draft has one leg per point after the first")
    func oneLegPerGap() {
        #expect(Self.draft([]).legs.isEmpty)
        #expect(Self.draft([Line.south]).legs.isEmpty)
        #expect(Self.draft([Line.south, Line.north]).legs.count == 1)
        #expect(Self.draft([Line.south, Line.middle, Line.north]).legs.count == 2)
    }

    /// The row that shows how far along point *n* sits is the row the leg
    /// into point *n* belongs on, which is the whole reason a leg is named
    /// after the point it arrives at.
    @Test("a leg is named after the point it arrives at")
    func legsArriveAtTheirPoint() throws {
        let draft = Self.draft([Line.south, Line.middle, Line.north])

        #expect(draft.leg(arrivingAtWaypointAt: 0) == nil, "nothing arrives at the first point")
        let second = try #require(draft.leg(arrivingAtWaypointAt: 1))
        #expect(second.id == draft.waypoints[1].id)
        let third = try #require(draft.leg(arrivingAtWaypointAt: 2))
        #expect(third.id == draft.waypoints[2].id)
    }

    @Test("a new leg is a straight freehand line between its two points")
    func newLegsAreStraight() throws {
        let draft = Self.draft([Line.south, Line.north])
        let leg = try #require(draft.legs.first)

        #expect(leg.snap == .freehand)
        #expect(leg.coordinates == leg.ends.straightCoordinates)
        #expect(abs(leg.distanceMeters - leg.ends.straightDistanceMeters) < 0.001)
    }

    // MARK: What the legs measure

    /// The header and the library both read this, so a snapped leg has to
    /// lengthen the whole line rather than only its own row.
    @Test("a snapped leg lengthens the line by what it drew")
    func snappedLegsChangeTheLength() throws {
        let draft = Self.draft([Line.south, Line.north])
        let ends = try #require(draft.legs.first).ends
        let straight = draft.distanceMeters

        draft.beginRouting([ends])
        draft.apply(Self.detour(along: ends), to: ends)

        #expect(abs(draft.distanceMeters - straight * 2) < 0.001)
        #expect(draft.distanceAlongLine(toWaypointAt: 1) == draft.distanceMeters)
    }

    /// What a save writes. The joins appear once, not twice, which is the one
    /// way a flattened route can be quietly wrong — a duplicated coordinate
    /// adds nothing to the length and is invisible on the map.
    @Test("the flattened route joins the legs without repeating their ends")
    func flattenedRouteHasNoDuplicateJoins() {
        let draft = Self.draft([Line.south, Line.middle, Line.north])

        let route = draft.routeCoordinates

        #expect(route.count == 3)
        #expect(route.map(\.latitude) == [Line.south, Line.middle, Line.north])
    }

    @Test("a snapped leg's own points reach the flattened route")
    func flattenedRouteCarriesResolvedShapes() throws {
        let draft = Self.draft([Line.south, Line.middle, Line.north])
        let ends = try #require(draft.legs.first).ends

        draft.beginRouting([ends])
        draft.apply(Self.detour(along: ends), to: ends)

        #expect(draft.routeCoordinates.count == 4, "the detour's middle point joins the line")
    }

    // MARK: Reuse

    /// The claim appending rests on: one new question per point put down,
    /// not one per leg on the screen.
    @Test("appending a point leaves the legs before it alone")
    func appendingKeepsResolvedLegs() throws {
        let draft = Self.draft([Line.south, Line.middle])
        let first = try #require(draft.legs.first).ends
        draft.beginRouting([first])
        draft.apply(Self.detour(along: first), to: first)

        draft.append(Self.coordinate(Line.north))

        #expect(draft.legs.count == 2)
        #expect(draft.legs[0].snap == .snapped, "the leg that was already answered stays answered")
        #expect(draft.legs[1].snap == .freehand)
        #expect(draft.legsAwaitingRoutes(retryingRefusals: false) == [draft.legs[1].ends])
    }

    // MARK: Applying an answer

    /// A leg that is no longer waiting must not take an answer. That is what
    /// keeps a hiker who turned snapping off from watching the line bend
    /// anyway a moment later.
    @Test("an answer is ignored by a leg that is not waiting for one")
    func answersOnlyLandOnRoutingLegs() throws {
        let draft = Self.draft([Line.south, Line.north])
        let ends = try #require(draft.legs.first).ends

        draft.apply(Self.detour(along: ends), to: ends)

        #expect(draft.legs[0].snap == .freehand, "nobody asked")
        #expect(draft.legs[0].coordinates == ends.straightCoordinates)
    }

    @Test("an answer about a leg that is no longer there changes nothing")
    func answersForVanishedLegsAreDropped() throws {
        let draft = Self.draft([Line.south, Line.north])
        let ends = try #require(draft.legs.first).ends
        draft.beginRouting([ends])
        draft.clear()

        draft.apply(Self.detour(along: ends), to: ends)

        #expect(draft.legs.isEmpty)
    }

    // MARK: The toggle

    @Test("a new draft follows paths")
    func snappingIsOnByDefault() {
        #expect(TrailDraft().snapsToPaths)
    }

    /// Turning it off straightens what is drawn, and the length goes back to
    /// what the hiker can see.
    @Test("turning path-following off straightens the legs")
    func turningItOffStraightens() throws {
        let draft = Self.draft([Line.south, Line.north])
        let ends = try #require(draft.legs.first).ends
        draft.beginRouting([ends])
        draft.apply(Self.detour(along: ends), to: ends)

        draft.setSnapsToPaths(false)

        #expect(draft.legs[0].snap == .freehand)
        #expect(draft.legs[0].coordinates == ends.straightCoordinates)
        #expect(abs(draft.distanceMeters - ends.straightDistanceMeters) < 0.001)
    }

    /// **Re-resolve, don't discard.** The points survive, so turning it back
    /// on has something to ask about.
    @Test("turning path-following off keeps every point")
    func turningItOffKeepsThePoints() {
        let draft = Self.draft([Line.south, Line.middle, Line.north])

        draft.setSnapsToPaths(false)

        #expect(draft.waypoints.count == 3)
        #expect(draft.legs.count == 2)
    }

    /// Nothing is asked while it is off, which is what makes it a way to stop
    /// spending requests as well as a way to draw a straight line.
    @Test("no leg is asked about while path-following is off")
    func nothingIsAskedWhileOff() {
        let draft = Self.draft([Line.south, Line.middle, Line.north])

        draft.setSnapsToPaths(false)

        #expect(draft.legsAwaitingRoutes(retryingRefusals: false).isEmpty)
        #expect(draft.legsAwaitingRoutes(retryingRefusals: true).isEmpty)
    }

    // MARK: What the screen reads

    /// A refusal is left alone by an ordinary pass and picked up by *Retry* —
    /// otherwise every subsequent tap would spend one more request against
    /// the server that has just said it is busy.
    @Test("a refused leg is only asked about again on Retry")
    func refusalsWaitForRetry() throws {
        let draft = Self.draft([Line.south, Line.north])
        let ends = try #require(draft.legs.first).ends
        draft.beginRouting([ends])
        draft.apply(.straight(along: ends, .refused(.busy)), to: ends)

        #expect(draft.legsAwaitingRoutes(retryingRefusals: false).isEmpty)
        #expect(draft.legsAwaitingRoutes(retryingRefusals: true) == [ends])
        #expect(draft.hasRetryableLegs)
    }

    /// An area with nothing mapped in it is an answer. Asking again would
    /// spend a request to be told the same thing, and the button that would
    /// spend it is not offered.
    @Test("a leg with nothing mapped under it is not offered a retry")
    func gapsAreNotRetried() throws {
        let draft = Self.draft([Line.south, Line.north])
        let ends = try #require(draft.legs.first).ends
        draft.beginRouting([ends])
        draft.apply(.straight(along: ends, .unmapped(.noPathBetween)), to: ends)

        #expect(!draft.hasRetryableLegs)
        #expect(draft.legsAwaitingRoutes(retryingRefusals: true).isEmpty)
        #expect(draft.notice?.isWarning == false, "nothing is broken")
    }

    /// One line for a whole trail, and it has to be the one a tap can fix.
    @Test("the line's notice reports the refusal ahead of the gap")
    func noticePrefersTheActionableFailure() {
        let draft = Self.draft([Line.south, Line.middle, Line.north])
        let first = draft.legs[0].ends
        let second = draft.legs[1].ends
        draft.beginRouting([first, second])
        draft.apply(.straight(along: first, .unmapped(.noPathBetween)), to: first)
        draft.apply(.straight(along: second, .refused(.busy)), to: second)

        #expect(draft.notice == TrailLegSnap.refused(.busy).notice)
    }

    /// A line that is doing what it was asked to do says nothing at all.
    @Test("a settled line has nothing to report")
    func settledLineIsQuiet() throws {
        let draft = Self.draft([Line.south, Line.north])
        let ends = try #require(draft.legs.first).ends
        draft.beginRouting([ends])
        draft.apply(Self.detour(along: ends), to: ends)

        #expect(draft.notice == nil)
        #expect(!draft.isRouting)
    }

    @Test("a line still being routed says so")
    func routingLineSaysSo() throws {
        let draft = Self.draft([Line.south, Line.north])
        let ends = try #require(draft.legs.first).ends

        draft.beginRouting([ends])

        #expect(draft.isRouting)
        #expect(draft.notice?.isWarning == false)
    }

    /// Closing the maker leaves nothing dashed behind it, so a draft picked
    /// up tomorrow does not come back mid-question.
    @Test("giving up on a route leaves the straight line it already was")
    func stoppingRoutingSettles() throws {
        let draft = Self.draft([Line.south, Line.north])
        let ends = try #require(draft.legs.first).ends
        draft.beginRouting([ends])

        draft.stopRouting()

        #expect(!draft.isRouting)
        #expect(draft.legs[0].snap == .freehand)
    }
}
