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
        let previous = try #require(maker.routingReader)
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
        let reader = try #require(maker.routingReader)
        await router.waitUntilAsked()
        maker.appendWaypoint(at: CLLocationCoordinate2D(latitude: 47.52, longitude: 19.06))
        #expect(maker.routingReader == reader, "the same reader, not a second beside it")
        #expect(await router.askedCount() == 1)
        await router.release()
        await settleDelegateHop(until: "both legs to be answered, one after the other") {
            maker.draft.legs.count == 2 && maker.draft.legs.allSatisfy { $0.snap == .snapped }
        }
        #expect(await router.askedCount() == 2)
        #expect(maker.draft.legs.allSatisfy { $0.snap == .snapped })
    }

    @Test("changing mode replaces the line without changing its stops")
    func changesMode() async {
        let hike = StubTrailLegRouter(answering: .snapped)
        let city = StubTrailLegRouter(answering: .unmapped(.noDirections))
        let maker = TrailDraftController(router: hike, travelRouters: [.walking: city])
        maker.setEditing(true)
        Self.draw(on: maker)
        await settleDelegateHop(until: "the hiking route") { maker.draft.legs.first?.snap == .snapped }
        let stops = maker.draft.waypoints
        #expect(maker.draft.travelMode == .hiking)
        maker.setTravelMode(.walking)
        await settleDelegateHop(until: "the walking answer") {
            maker.draft.legs.first?.snap == .unmapped(.noDirections)
        }
        #expect(maker.draft.waypoints == stops)
        maker.setTravelMode(.hiking)
        await settleDelegateHop(until: "hiking again") { maker.draft.legs.first?.snap == .snapped }
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
