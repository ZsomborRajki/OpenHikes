import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Trail maker travel modes")
struct TrailTravelModeTests {
    private static func draw(on maker: TrailDraftController) {
        maker.appendWaypoint(at: CLLocationCoordinate2D(latitude: 47.50, longitude: 19.04))
        maker.appendWaypoint(at: CLLocationCoordinate2D(latitude: 47.51, longitude: 19.05))
    }

    @Test("a cancelled provider cannot overwrite a newer mode's answer")
    func lateAnswer() async throws {
        let hiking = StubTrailLegRouter(answering: .snapped, holding: true)
        let walking = StubTrailLegRouter(answering: .unmapped(.noDirections))
        let maker = TrailDraftController(router: hiking, travelRouters: [.walking: walking])
        maker.setEditing(true)
        Self.draw(on: maker)
        let previous = try #require(maker.routingTask)
        await hiking.waitUntilAsked()
        maker.setTravelMode(.walking)
        await settleDelegateHop(until: "the newer walking answer") {
            maker.draft.legs.first?.snap == .unmapped(.noDirections)
        }
        await hiking.release()
        await previous.value
        #expect(maker.draft.travelMode == .walking)
        #expect(maker.draft.legs.first?.snap == .unmapped(.noDirections))
    }

    @Test("queued legs added on another tap wait for the running request")
    func requestsAreSerial() async throws {
        let router = StubTrailLegRouter(answering: .snapped, holding: true)
        let maker = TrailDraftController(router: router)
        maker.setEditing(true)
        Self.draw(on: maker)
        let pass = try #require(maker.routingTask)
        await router.waitUntilAsked()
        maker.appendWaypoint(at: CLLocationCoordinate2D(latitude: 47.52, longitude: 19.06))
        #expect(maker.routingTask == pass)
        #expect(await router.askedCount() == 1)
        await router.release()
        await pass.value
        #expect(await router.askedCount() == 2)
        #expect(maker.draft.legs.allSatisfy { $0.snap == .snapped })
    }

    @Test("changing mode replaces the line without changing its stops or undo history")
    func changesMode() async {
        let hike = StubTrailLegRouter(answering: .snapped)
        let city = StubTrailLegRouter(answering: .unmapped(.noDirections))
        let maker = TrailDraftController(router: hike, travelRouters: [.walking: city])
        maker.setEditing(true)
        Self.draw(on: maker)
        await settleDelegateHop(until: "the hiking route") { maker.draft.legs.first?.snap == .snapped }
        let before = maker.draft.contents
        #expect(maker.draft.travelMode == .hiking)
        maker.setTravelMode(.walking)
        await settleDelegateHop(until: "the walking answer") {
            maker.draft.legs.first?.snap == .unmapped(.noDirections)
        }
        #expect(maker.draft.contents == before)
        maker.undo()
        #expect(maker.draft.waypoints.count == 1)
        #expect(maker.draft.travelMode == .walking)
        maker.redo()
        #expect(maker.draft.legs.first?.snap == .unmapped(.noDirections))
        maker.setTravelMode(.hiking)
        await settleDelegateHop(until: "hiking again") { maker.draft.legs.first?.snap == .snapped }
    }

    @Test("reversing city routes asks about the reverse journey", arguments: [
        TrailTravelMode.walking, .cycling, .driving,
    ])
    func reverse(_ mode: TrailTravelMode) async throws {
        let router = StubTrailLegRouter(answering: .snapped)
        let maker = TrailDraftController(travelRouters: [mode: router])
        maker.setEditing(true)
        maker.setTravelMode(mode)
        Self.draw(on: maker)
        await settleDelegateHop(until: "the forward route") { maker.draft.legs.first?.snap == .snapped }
        let forward = try #require(maker.draft.legs.first?.ends)
        maker.reverse()
        await settleDelegateHop(until: "the reverse route") { maker.draft.legs.first?.snap == .snapped }
        #expect(await router.askedEnds() == [forward, forward.flipped])
    }

    @Test("reversing while city directions are in flight starts the reverse journey")
    func reverseInFlight() async throws {
        let router = StubTrailLegRouter(answering: .snapped, holding: true)
        let maker = TrailDraftController(travelRouters: [.walking: router])
        maker.setEditing(true)
        maker.setTravelMode(.walking)
        Self.draw(on: maker)
        let forwardPass = try #require(maker.routingTask)
        await router.waitUntilAsked()
        let forward = try #require(await router.askedEnds().first)

        maker.reverse()
        let reversePass = try #require(maker.routingTask)
        await router.waitUntilAsked(2)
        await router.release()
        await forwardPass.value
        await reversePass.value

        #expect(await router.askedEnds() == [forward, forward.flipped])
        #expect(maker.draft.legs.first?.ends == forward.flipped)
        #expect(maker.draft.legs.first?.snap == .snapped)
    }

    @Test("the mode resumes with the draft", arguments: TrailTravelMode.allCases)
    func persistence(_ mode: TrailTravelMode) throws {
        let store = TrailDraftStore(context: try Fixture.modelContext())
        let maker = TrailDraftController(store: store)
        maker.setEditing(true)
        Self.draw(on: maker)
        maker.setTravelMode(mode)
        let resumed = TrailDraftController(store: store)
        resumed.setEditing(true)
        #expect(resumed.draft.travelMode == mode)
        #expect(resumed.draft.waypoints.count == 2)
    }

    @Test("freehand remains freehand after a mode change")
    func freehand() async {
        let router = StubTrailLegRouter(answering: .snapped)
        let maker = TrailDraftController(travelRouters: [.driving: router])
        maker.setEditing(true)
        maker.setSnapsToPaths(false)
        Self.draw(on: maker)
        maker.setTravelMode(.driving)
        #expect(maker.draft.legs.first?.snap == .freehand)
        #expect(await router.askedCount() == 0)
        maker.setSnapsToPaths(true)
        await settleDelegateHop(until: "driving directions") { maker.draft.legs.first?.snap == .snapped }
        #expect(await router.askedCount() == 1)
    }
}
