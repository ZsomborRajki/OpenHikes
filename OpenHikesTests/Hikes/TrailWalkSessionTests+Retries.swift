import Foundation
@testable import OpenHikes
import SwiftData
import Testing

extension TrailWalkSessionTests {
    @Test("persistent save failures allow one prompt retry, then wait for the cadence", arguments: [false, true])
    func persistentFailuresAreThrottled(paused: Bool) throws {
        var refusing = false
        var attempts = 0
        let session = TrailWalkSession(context: context, clock: clock.read, save: { store in
            attempts += 1
            if refusing { throw CocoaError(.fileWriteUnknown) }
            try store.save()
        })
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        walk(session, hike: hike, profile: profile, from: 0, through: 2)
        if paused { #expect(session.pause()) }
        let written = try #require(hike.walkInProgress)
        let baseline = attempts

        refusing = true
        clock.advance(by: TrailWalkPolicy.persistInterval)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[2])
        #expect(attempts == baseline + 1)
        clock.advance(by: 1)
        session.recordBackgroundMatch(hikeID: hike.id, distance: profile.distances[2], at: clock.now)
        #expect(attempts == baseline + 2, "the first retry is prompt")
        for _ in 1..<Int(TrailWalkPolicy.persistInterval) {
            clock.advance(by: 1)
            session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[2])
            session.recordBackgroundMatch(hikeID: hike.id, distance: profile.distances[2], at: clock.now)
        }
        #expect(attempts == baseline + 2, "neither feed retries on every fix")
        #expect(hike.walkInProgress == written)

        clock.advance(by: 1)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[2])
        #expect(attempts == baseline + 3, "another attempt is due at the cadence boundary")
        refusing = false
        clock.advance(by: TrailWalkPolicy.persistInterval)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[3])
        #expect(attempts == baseline + 4)
        #expect(hike.walkInProgress == session.record, "the latest record becomes durable after recovery")
        clock.advance(by: 1)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[3])
        #expect(attempts == baseline + 4, "a successful write restores the normal cadence")

        refusing = true
        clock.advance(by: TrailWalkPolicy.persistInterval)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[3])
        clock.advance(by: 1)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[3])
        #expect(attempts == baseline + 6, "a new failure episode gets its own prompt retry")
    }

    @Test("a failed start retries on a later fix and explicit pauses bypass retry throttling")
    func failedStartAndExplicitMilestone() throws {
        var refusing = true
        var attempts = 0
        let session = TrailWalkSession(context: context, clock: clock.read, save: { store in
            attempts += 1
            if refusing { throw CocoaError(.fileWriteUnknown) }
            try store.save()
        })
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[0])
        #expect(attempts == 1, "start and match must not spend the retry on the same fix")
        #expect(hike.walkInProgress == nil)
        clock.advance(by: 1)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[1])
        #expect(attempts == 2)
        clock.advance(by: 1)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[2])
        #expect(attempts == 2)

        refusing = false
        #expect(session.pause(), "an explicit milestone can commit during the automatic retry wait")
        #expect(attempts == 3)
        #expect(hike.walkInProgress?.phase == .paused)
    }
}
