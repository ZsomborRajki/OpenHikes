//
//  TrailDraftRoutingTests.swift
//  OpenHikesTests
//
//  The controller's half of Phase 2: who gets asked, when, and what happens
//  to the answer.
//
//  ``TrailLegRouterTests`` owns the routing itself and ``TrailDraftLegTests``
//  owns what a leg is. What is only true of the controller is the policy
//  between them, and every claim below is one a hiker would notice as a bill
//  or as a stall rather than as a wrong line:
//
//  - **One question per leg, once.** A hiker putting down ten points must not
//    re-ask about the nine legs already answered, and must not ask twice
//    about the one that is in flight.
//  - **A refusal waits for *Retry*.** Otherwise every subsequent tap spends a
//    request against the server that has just said it is busy.
//  - **The toggle re-resolves rather than discards**, and turning it back on
//    costs nothing on the wire because the router remembers.
//  - **A launch with no graph provider draws straight lines and says so**, by
//    not offering a switch it could not honour.
//
//  Everything here waits on the effect rather than on a number of scheduler
//  turns — see `SettleSupport.swift` for what a fixed count of `Task.yield()`
//  cost this repository on CI.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Trail draft routing")
struct TrailDraftRoutingTests {
    private enum Line {
        static let longitude: Double = 12.8317
        static let south: Double = 47.7180
        static let middle: Double = 47.7190
        static let north: Double = 47.7200
    }

    private static func coordinate(_ latitude: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: Line.longitude)
    }

    /// A maker already open, drawing over `router`.
    private static func maker(_ router: StubTrailLegRouter) -> TrailDraftController {
        let maker = TrailDraftController(router: router)
        maker.setEditing(true)
        return maker
    }

    private static func draw(
        _ latitudes: [Double],
        on maker: TrailDraftController
    ) {
        for latitude in latitudes { maker.appendWaypoint(at: coordinate(latitude)) }
    }

    // MARK: Asking

    @Test("a leg is routed as soon as its second point goes down")
    func appendingRoutesTheNewLeg() async {
        let router = StubTrailLegRouter(answering: .snapped)
        let maker = Self.maker(router)

        Self.draw([Line.south, Line.north], on: maker)

        await settleDelegateHop(until: "the leg to be routed") {
            maker.draft.legs.first?.snap == .snapped
        }
        #expect(await router.askedCount() == 1)
    }

    /// Marked in the same turn the question is asked, so the line is never a
    /// settled straight one while an answer about it is on the wire.
    @Test("a leg being asked about is drawn as waiting straight away")
    func legsAreMarkedBeforeTheAnswer() {
        let router = StubTrailLegRouter(answering: .snapped, holding: true)
        let maker = Self.maker(router)

        Self.draw([Line.south, Line.north], on: maker)

        #expect(maker.draft.legs.first?.snap == .routing)
        #expect(maker.draft.isRouting)
    }

    /// Ten points is nine questions, not forty-five. The leg already answered
    /// is not asked about again by the tap that adds the next one.
    @Test("each leg is asked about once, however many points follow it")
    func eachLegIsAskedOnce() async {
        let router = StubTrailLegRouter(answering: .snapped)
        let maker = Self.maker(router)

        Self.draw([Line.south, Line.middle, Line.north], on: maker)

        await settleDelegateHop(until: "both legs to settle") {
            maker.draft.legs.count == 2
                && maker.draft.legs.allSatisfy { leg in leg.snap == .snapped }
        }
        #expect(await router.askedCount() == 2)
    }

    /// A tap arriving while the first leg is still out must not start a
    /// second question about it.
    @Test("a leg already in flight is not asked about twice")
    func inFlightLegsAreNotReasked() async {
        let router = StubTrailLegRouter(answering: .snapped, holding: true)
        let maker = Self.maker(router)
        Self.draw([Line.south, Line.middle], on: maker)

        Self.draw([Line.north], on: maker)
        await router.release()

        await settleDelegateHop(until: "both legs to settle") {
            maker.draft.legs.allSatisfy { leg in leg.snap == .snapped }
        }
        #expect(await router.askedCount() == 2, "two legs, two questions")
    }

    // MARK: A refusal

    /// The field case: Overpass is busy, and the line is still there.
    @Test("a refused leg stays drawn and reports the refusal")
    func refusedLegsStayDrawn() async throws {
        let router = StubTrailLegRouter(answering: .refused(.busy))
        let maker = Self.maker(router)

        Self.draw([Line.south, Line.north], on: maker)

        await settleDelegateHop(until: "the refusal to land") {
            maker.draft.legs.first?.snap == .refused(.busy)
        }
        let leg = try #require(maker.draft.legs.first)
        #expect(leg.coordinates == leg.ends.straightCoordinates)
        #expect(maker.draft.canBeSaved, "a busy server must not stop a trail being saved")
        #expect(maker.draft.hasRetryableLegs)
    }

    /// Putting down more points does not quietly re-ask about the refused
    /// leg, which is one request per tap aimed at a server that is already
    /// refusing.
    @Test("a refused leg is not asked about again by the next tap")
    func refusalsAreNotReaskedByTaps() async {
        let router = StubTrailLegRouter(answering: .refused(.busy))
        let maker = Self.maker(router)
        Self.draw([Line.south, Line.middle], on: maker)
        await settleDelegateHop(until: "the first refusal") {
            maker.draft.legs.first?.snap == .refused(.busy)
        }

        Self.draw([Line.north], on: maker)
        await settleDelegateHop(until: "the second refusal") {
            maker.draft.legs.count == 2 && maker.draft.legs[1].snap == .refused(.busy)
        }

        #expect(await router.askedCount() == 2, "one question per leg, not one per tap")
    }

    /// And *Retry* is the one thing that does ask again.
    @Test("Retry asks again about the legs that were refused")
    func retryAsksAgain() async {
        let router = StubTrailLegRouter(answering: .refused(.busy))
        let maker = Self.maker(router)
        Self.draw([Line.south, Line.north], on: maker)
        await settleDelegateHop(until: "the refusal") {
            maker.draft.legs.first?.snap == .refused(.busy)
        }

        await router.answer(with: .snapped)
        maker.retryRefusedLegs()

        await settleDelegateHop(until: "the retry to settle") {
            maker.draft.legs.first?.snap == .snapped
        }
        #expect(await router.askedCount() == 2)
        #expect(!maker.draft.hasRetryableLegs)
    }

    /// A cancelled question is not a failure and is not drawn as one — but
    /// the leg cannot be left waiting either. A leg still marked as waiting
    /// is never asked about again, so it would stay dashed for the rest of
    /// the drawing.
    @Test("a cancelled question gives the leg back rather than leaving it waiting")
    func cancelledQuestionsReleaseTheLeg() async {
        let router = StubTrailLegRouter(answering: nil)
        let maker = Self.maker(router)

        Self.draw([Line.south, Line.north], on: maker)

        await settleDelegateHop(until: "the leg to stop waiting") {
            maker.draft.legs.first?.snap == .freehand
        }
        #expect(!maker.draft.isRouting)
        #expect(
            maker.draft.legsAwaitingRoutes(retryingRefusals: false).count == 1,
            "and it is asked about again by the next pass"
        )
    }

    // MARK: The toggle

    @Test("turning path-following off straightens the line and asks nothing")
    func togglingOffStopsAsking() async {
        let router = StubTrailLegRouter(answering: .snapped)
        let maker = Self.maker(router)
        Self.draw([Line.south, Line.north], on: maker)
        await settleDelegateHop(until: "the leg to settle") {
            maker.draft.legs.first?.snap == .snapped
        }

        maker.setSnapsToPaths(false)

        #expect(!maker.draft.snapsToPaths)
        #expect(maker.draft.legs.first?.snap == .freehand)
        #expect(await router.askedCount() == 1, "turning it off is not a question")
    }

    /// **Re-resolve, don't discard.** The points are all still there and the
    /// line comes back.
    @Test("turning it back on re-resolves what was already drawn")
    func togglingBackOnReResolves() async {
        let router = StubTrailLegRouter(answering: .snapped)
        let maker = Self.maker(router)
        Self.draw([Line.south, Line.middle, Line.north], on: maker)
        await settleDelegateHop(until: "both legs to settle") {
            maker.draft.legs.allSatisfy { leg in leg.snap == .snapped }
        }
        maker.setSnapsToPaths(false)

        maker.setSnapsToPaths(true)

        await settleDelegateHop(until: "both legs to be followed again") {
            maker.draft.legs.allSatisfy { leg in leg.snap == .snapped }
        }
        #expect(maker.draft.waypoints.count == 3)
    }

    // MARK: A launch that cannot ask

    /// No trail graph, no switch. A control that cannot change the line is
    /// worse than none.
    @Test("a maker with no router draws straight lines and offers no switch")
    func noRouterMeansNoSwitch() async {
        let maker = TrailDraftController()
        maker.setEditing(true)

        Self.draw([Line.south, Line.north], on: maker)

        #expect(!maker.canSnapToPaths)
        await settleDelegateHop()
        #expect(maker.draft.legs.first?.snap == .freehand)
        #expect(!maker.draft.isRouting)
    }

    @Test("a maker with a router offers the switch")
    func aRouterMeansASwitch() {
        #expect(Self.maker(StubTrailLegRouter(answering: .snapped)).canSnapToPaths)
    }

    // MARK: Opening and closing

    /// A tap that arrives as the screen leaves adds nothing, and neither does
    /// it ask anything.
    @Test("nothing is asked while the maker is closed")
    func closedMakersAskNothing() async {
        let router = StubTrailLegRouter(answering: .snapped)
        let maker = TrailDraftController(router: router)

        maker.appendWaypoint(at: Self.coordinate(Line.south))
        maker.appendWaypoint(at: Self.coordinate(Line.north))

        await settleDelegateHop()
        #expect(await router.askedCount() == 0)
    }

    /// Closing leaves nothing dashed behind, so a draft picked up later does
    /// not come back mid-question.
    @Test("closing the maker settles whatever was still being asked about")
    func closingSettlesTheLine() async {
        let router = StubTrailLegRouter(answering: .snapped, holding: true)
        let maker = Self.maker(router)
        Self.draw([Line.south, Line.north], on: maker)
        #expect(maker.draft.isRouting)

        maker.setEditing(false)

        #expect(!maker.draft.isRouting)
        await router.release()
        await settleDelegateHop()
        #expect(
            maker.draft.legs.first?.snap == .freehand,
            "an answer nobody is waiting for is dropped"
        )
    }

    /// A restored draft comes back as points and a setting, so the line has
    /// to be asked about again — otherwise it would sit straight until the
    /// hiker touched it.
    @Test("a restored draft is routed when the maker opens")
    func restoredDraftsAreRouted() async throws {
        let router = StubTrailLegRouter(answering: .snapped)
        let store = TrailDraftStore(context: try Fixture.modelContext())
        store.save(
            waypoints: [
                TrailWaypoint(coordinate: Self.coordinate(Line.south)),
                TrailWaypoint(coordinate: Self.coordinate(Line.north)),
            ],
            snapsToPaths: true
        )
        let maker = TrailDraftController(store: store, router: router)

        maker.setEditing(true)

        await settleDelegateHop(until: "the restored leg to be routed") {
            maker.draft.legs.first?.snap == .snapped
        }
    }

    /// The setting is part of the drawing, so a draft put down with straight
    /// lines comes back with straight lines — and asks nothing on the way.
    @Test("a draft saved with path-following off comes back with it off")
    func restoredDraftsKeepTheirSetting() async throws {
        let router = StubTrailLegRouter(answering: .snapped)
        let store = TrailDraftStore(context: try Fixture.modelContext())
        store.save(
            waypoints: [
                TrailWaypoint(coordinate: Self.coordinate(Line.south)),
                TrailWaypoint(coordinate: Self.coordinate(Line.north)),
            ],
            snapsToPaths: false
        )
        let maker = TrailDraftController(store: store, router: router)

        maker.setEditing(true)

        #expect(!maker.draft.snapsToPaths)
        await settleDelegateHop()
        #expect(await router.askedCount() == 0)
    }

    /// The toggle is written down as it moves, like a point going down — so
    /// the disk is never one gesture behind.
    @Test("moving the switch is written down with the points")
    func theSwitchIsPersisted() throws {
        let store = TrailDraftStore(context: try Fixture.modelContext())
        let maker = TrailDraftController(
            store: store,
            router: StubTrailLegRouter(answering: .snapped)
        )
        maker.setEditing(true)
        Self.draw([Line.south, Line.north], on: maker)

        maker.setSnapsToPaths(false)

        #expect(!store.load().snapsToPaths)
    }
}
