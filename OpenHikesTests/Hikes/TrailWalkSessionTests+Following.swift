//
//  TrailWalkSessionTests+Following.swift
//  OpenHikesTests
//
//  Follow This Trail controls the display and permission to auto-start.
//  A walk already under way has its own Pause / Resume / End controls.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

extension TrailWalkSessionTests {
    @Test("turning following off and on preserves an active walk without a phase write")
    func followingTogglePreservesTheWalk() throws {
        var saves = 0
        let session = TrailWalkSession(context: context, clock: clock.read, save: { context in
            try context.save()
            saves += 1
        })
        let hike = hike()
        let other = self.hike(title: "Other")
        let profile = RouteProfile(route: hike.route)
        walk(session, hike: hike, profile: profile, from: 0, through: 3)
        let before = try #require(session.record)
        let written = hike.walkInProgress
        let savesBefore = saves
        #expect(savesBefore > 0)

        session.autoFollowDidChange(hikeID: other.id, enabled: false)
        hike.autoFollowEnabled = false
        session.autoFollowDidChange(hikeID: hike.id, enabled: false)
        #expect(session.phase == .following)
        #expect(session.record == before)
        #expect(hike.walkInProgress == written)
        #expect(saves == savesBefore, "a display change needs no durable phase transition")

        // Both feeds keep extending the same walk while its live marker is off.
        walk(session, hike: hike, profile: profile, from: 4, through: 5)
        clock.advance(by: 60)
        session.recordBackgroundMatch(hikeID: hike.id, distance: profile.distances[6], at: clock.read())
        #expect(session.coveredFraction > before.coveredFraction)
        #expect(session.activeSeconds() == before.activeSeconds(at: clock.read()))
        #expect(session.publishes(hikeID: hike.id))

        let extended = session.record
        let extendedSaves = saves
        hike.autoFollowEnabled = true
        session.autoFollowDidChange(hikeID: hike.id, enabled: true)
        #expect(session.phase == .following)
        #expect(session.record == extended)
        #expect(saves == extendedSaves)
    }

    @Test("the follow toggle leaves a paused walk paused and Resume leaves following off")
    func resumePreservesFollowingPreference() throws {
        let session = session()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        walk(session, hike: hike, profile: profile, from: 0, through: 3)
        session.pause()
        let paused = try #require(session.record)

        for enabled in [false, true, false] {
            hike.autoFollowEnabled = enabled
            session.autoFollowDidChange(hikeID: hike.id, enabled: enabled)
            #expect(session.phase == .paused)
            #expect(session.record == paused)
        }
        clock.advance(by: 1800)
        session.resume()

        #expect(session.phase == .following)
        #expect(!hike.autoFollowEnabled)
        #expect(session.activeSeconds() == paused.bankedActiveSeconds)
        walk(session, hike: hike, profile: profile, from: 4, through: 6)
        #expect(session.coveredFraction > paused.coveredFraction)
        #expect(session.activeSeconds() == paused.bankedActiveSeconds + 180)
    }
}
