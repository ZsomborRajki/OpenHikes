//
//  ShownLineTests+Landing.swift
//  OpenHikesTests
//
//  When the line on a hike's screen is set, which is when everything on the
//  screen that reads it is drawn again (#1252). A render trace of opening a
//  hike found the whole card drawn once more than on `main`. The preparation
//  wrote what it built from the line, and the line's own landing, which waits
//  for the same read and compares it off the main actor, set it a turn later.
//  So the preparation lands the line with its work, the read's own landing
//  then sets nothing, and a line read again that is the line on screen is
//  not set again.
//
//  Split from `ShownLineTests`, whose body is at its length limit.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

extension ShownLineTests {
    @Test("a line the screen's work has landed is not set again by its read")
    func aLandedLineIsNotSetAgain() async throws {
        let hike = try await saved("Landed")
        let late = LateFetch(holding: 1)
        defer { late.open() }
        let selection = Self.selection(fetch: late.fetch)
        try await select(hike, in: selection)
        let shown = ShownLine()
        let read = shown.show(hike, selection: selection.lines, followedBy: selection.watch)
        await settleDelegateHop(until: "the read is out") { late.isHolding }

        shown.land(SelectedLine.Line(route: Fixture.ridgeRoute, distanceMeters: hike.distanceMeters), from: read)
        #expect(shown.current?.route == Fixture.ridgeRoute, "landed with the work built from it")
        let changes = ObservationCounter {
            _ = shown.current
            _ = shown.revision
        }
        late.open()
        _ = await read.route
        await shown.landing?.value
        await changes.settle()

        #expect(changes.count == 0, "the read's own landing sets nothing")
        #expect(shown.revision == 0)
    }

    /// The preparation of a line can finish after a newer read has been
    /// installed, and must not put its older line back.
    @Test("a line landed from a read no longer in force is not shown")
    func aLandingFromAnOlderReadShowsNothing() async throws {
        let first = try await saved("First")
        let second = try await saved("Second", route: Self.movedRoute)
        let selection = Self.selection()
        let shown = ShownLine()
        let older = shown.show(first, selection: selection.lines, followedBy: selection.watch)
        shown.show(second, selection: selection.lines, followedBy: selection.watch)
        await shown.landing?.value

        shown.land(SelectedLine.Line(route: Fixture.ridgeRoute, distanceMeters: first.distanceMeters), from: older)

        #expect(shown.current?.route == Self.movedRoute)
    }

    /// Switching between the selection's reader and the screen's own reads
    /// the same line again, and so does a write of the same points. Neither
    /// is anything new to draw.
    @Test("a line read again that is the line on screen is not set again")
    func theSameLineReadAgainSetsNothing() async throws {
        let hike = try await saved("Same")
        let selection = Self.selection()
        try await select(hike, in: selection)
        let shown = ShownLine()
        let first = shown.show(hike, selection: selection.lines, followedBy: selection.watch)
        await shown.landing?.value
        let changes = ObservationCounter {
            _ = shown.current
            _ = shown.revision
        }

        hike.replaceRoute(with: Fixture.ridgeRoute)
        try container.mainContext.save()
        await settleDelegateHop(until: "the line is read again") { shown.read !== first }
        await shown.landing?.value
        await changes.settle()

        #expect(changes.count == 0, "the same line is not set again")
        #expect(shown.current?.route == Fixture.ridgeRoute)
    }
}
