//
//  TrailWalkIsolationTests.swift
//  OpenHikesTests
//
//  A matched fix that extends a walk redraws the progress row and nothing
//  above it. `TrailWalkSession` splits its properties by rate for exactly
//  this — the phase and the walked hike change on a tap, the coverage per
//  fix — and these are the pins: an observer of the coarse properties is
//  not woken by a coverage write, and an observer of the coverage is.
//
//  The same shape as `RenderIsolationTests`, with the same counter. Both
//  sides are asserted for the reason that file gives: a zero on its own is
//  evidence only beside the one that went up.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

@Suite("Trail walk observation isolation")
struct TrailWalkIsolationTests {
    private let container: ModelContainer
    private let context: ModelContext
    private let session: TrailWalkSession
    private let hike: Hike
    private let profile: RouteProfile

    init() throws {
        container = try Fixture.modelContainer()
        context = ModelContext(container)
        session = TrailWalkSession(context: context)
        hike = Fixture.hike(in: context)
        profile = RouteProfile(route: hike.route)
    }

    private func match(at index: Int) {
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[index])
    }

    /// The sheet's row and the walk controls read `walkedHikeID` and `phase`;
    /// a fix extending coverage must not reach them.
    @Test("coverage writes wake the progress row and not the controls")
    func coverageWakesOnlyTheFineObservers() async {
        match(at: 0)
        let coarse = ObservationCounter {
            _ = session.walkedHikeID
            _ = session.phase
            _ = session.walkedHikeTitle
        }
        let fine = ObservationCounter { _ = session.coveredFraction }
        await coarse.settle()

        // Precondition for the zero below: the writes really happened.
        let before = session.coveredFraction
        match(at: 1)
        match(at: 2)
        await fine.settle()
        #expect(session.coveredFraction > before, "the walk did extend")

        #expect(fine.count >= 1, "the progress row is told")
        #expect(coarse.count == 0, "the controls and the sheet's row are not")
    }

    /// The other direction: a tap changes the phase and the controls redraw,
    /// while a body that only draws the bar is left alone.
    @Test("a pause wakes the controls and not the bar")
    func pauseWakesOnlyTheCoarseObservers() async {
        match(at: 0)
        match(at: 1)
        let coarse = ObservationCounter { _ = session.phase }
        let fine = ObservationCounter { _ = session.coveredFraction }
        await coarse.settle()

        session.pause()
        await coarse.settle()
        #expect(session.phase == .paused)

        #expect(coarse.count == 1)
        #expect(fine.count == 0)
    }

    /// A match that lands where the last one did changes no number, and so
    /// wakes nobody — the same guard `TrackerState`'s writers keep.
    @Test("a repeated match wakes nothing")
    func repeatedMatchIsSilent() async {
        match(at: 0)
        match(at: 1)
        let fine = ObservationCounter { _ = session.coveredFraction }
        await fine.settle()

        match(at: 1)
        await fine.settle()
        #expect(fine.count == 0)
    }
}
