//
//  SelectedLineTests+FailedReads.swift
//  OpenHikesTests
//
//  A fetch that fails says nothing about the row, so its read is neither kept
//  as the hike's line nor handed out over the line the readers hold: see
//  *A read that fails* in `SelectedLine.swift` (#1333). A real store does not
//  fail a fetch on demand, so the fetch seam fails the calls a test names
//  (`FailingLineFetch`).
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
import SwiftData
import Testing

extension WidgetFeedSuites.SelectedLineTests {
    /// A saved hike on the ridge, the line its four readers share, and them.
    private struct Selection {
        let hike: Hike
        let lines: SelectedLine
        let readers: Readers
    }

    /// A ``Selection`` read through `fetch`, with every reader's work landed.
    private func selection(fetching fetch: FailingLineFetch) async throws -> Selection {
        let hike = Fixture.hike(in: context)
        try context.save()
        let lines = SelectedLine(fetch: fetch.fetch)
        let readers = readers(reading: lines)
        await select(hike, into: readers, from: lines)
        return Selection(hike: hike, lines: lines, readers: readers)
    }

    /// Saves the moved line through a context of its own, as an edit
    /// mirrored in from another device is saved: the main context's hike is
    /// never told, and only a read of the store finds it.
    private func saveMovedLineElsewhere(of hike: Hike) throws {
        let sibling = ModelContext(container)
        let id = hike.id
        let stored = try #require(try sibling.fetch(FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })).first)
        stored.replaceRoute(with: Self.movedRoute)
        try sibling.save()
    }

    /// Whether the map, its colours and the widget all draw the moved line,
    /// or all the ridge, as far as each one's first point tells.
    private static func everyReaderDraws(_ hike: Hike, onMovedRoute: Bool, in readers: Readers) -> Bool {
        let isOnRoute = { (coordinate: CLLocationCoordinate2D?) in
            guard let coordinate else { return false }
            return isOnMovedRoute(coordinate) == onMovedRoute
        }
        return isOnRoute(readers.cache.drawnRoute(for: hike)?.coordinates.first)
            && !readers.shading.stretches.isEmpty
            && readers.shading.stretches.allSatisfy { isOnRoute($0.coordinates.first) }
            && isOnRoute(start(of: SharedStore.load()))
    }

    /// The first failure asks for one more read at once, as a library line's
    /// does, because the selection it was read for may be the last ask. That
    /// read is held until every reader has done its work with the one that
    /// failed, so the line reaches readers that drew, coloured, built and
    /// published nothing for it, and none of them may have stood down.
    @Test("a read that fails is read again at once, and its line reaches all four readers")
    func aFailedReadIsReadAgainAtOnce() async throws {
        let fetch = FailingLineFetch(failing: [1], holding: 2)
        defer { fetch.open() }
        let selected = try await selection(fetching: fetch)
        let (hike, readers) = (selected.hike, selected.readers)
        #expect(readers.cache.drawnRoute(for: hike)?.coordinates.isEmpty == true, "the premise: nothing drawn yet")

        fetch.open()
        await settleDelegateHop(until: "the line is drawn, coloured and on the widget") {
            Self.everyReaderDraws(hike, onMovedRoute: false, in: readers)
        }
        await readers.tracker.waitForSelectionPublish()
        await readers.autoSave.waitForActivation()

        #expect(fetch.count == 2, "the read that failed and the one it asked for")
        #expect(
            try await claims(Fixture.ridgeRoute[2], for: hike, key: "selected-line/17/failed-once@2.0"),
            "the corridor, from a hike auto-save kept up"
        )
    }

    /// The case #1333 reported first: the read that failed was kept, so the
    /// hike asked about again was handed a line with nothing in it, and
    /// nothing was read. A failure that holds asks for one more read and no
    /// more, and the next ask reads the line for every reader.
    @Test("a read that keeps failing waits for the next ask, which reads the line for every reader")
    func aFailureThatHoldsWaitsForTheNextAsk() async throws {
        let fetch = FailingLineFetch(failing: [1, 2])
        let selected = try await selection(fetching: fetch)
        let (hike, lines, readers) = (selected.hike, selected.lines, selected.readers)
        await settleDelegateHop(until: "the read and the one it asked for have both failed") {
            fetch.count == 2 && lines.refreshing == nil
        }
        #expect(readers.cache.drawnRoute(for: hike)?.coordinates.isEmpty == true, "nothing to draw yet")

        // Asked again, as the hike's screen asks after a save to the store,
        // by one reader: the line reaches the other three as well.
        _ = lines.read(of: hike)
        await settleDelegateHop(until: "the line is drawn, coloured and on the widget") {
            Self.everyReaderDraws(hike, onMovedRoute: false, in: readers)
        }
        #expect(fetch.count == 3)
    }

    /// The save that asked for the refresh may be the last, so the first
    /// failure asks for one more read at once, and that finds the new line.
    @Test("a refresh that fails is read again at once, and finds the line another context saved")
    func aFailedRefreshIsReadAgainAtOnce() async throws {
        let fetch = FailingLineFetch(failing: [2])
        let selected = try await selection(fetching: fetch)
        let (hike, lines, readers) = (selected.hike, selected.lines, selected.readers)
        try saveMovedLineElsewhere(of: hike)

        lines.refresh()
        await lines.refreshing?.value
        await settleDelegateHop(until: "the store's line is drawn, coloured and on the widget") {
            Self.everyReaderDraws(hike, onMovedRoute: true, in: readers)
        }
        #expect(fetch.count == 3, "the selection, the refresh that failed and the one it asked for")
    }

    /// The case #1333 reported second: a refresh whose fetch failed handed
    /// every reader a line with nothing in it, over the line they held. They
    /// keep that line, and the line saved elsewhere is still owed: the next
    /// ask reads it.
    @Test("a refresh that keeps failing keeps the line every reader holds, and the next ask reads the new one")
    func aFailedRefreshKeepsTheLine() async throws {
        let fetch = FailingLineFetch(failing: [2, 3])
        let selected = try await selection(fetching: fetch)
        let (hike, lines, readers) = (selected.hike, selected.lines, selected.readers)
        let read = lines.read(of: hike)
        try saveMovedLineElsewhere(of: hike)

        lines.refresh()
        await lines.refreshing?.value
        #expect(fetch.count == 3, "the refresh and the one more read it asked for")
        #expect(!read.isReplaced, "the read every reader holds is still the line")
        #expect(Self.everyReaderDraws(hike, onMovedRoute: false, in: readers))

        _ = lines.read(of: hike)
        await settleDelegateHop(until: "the store's line is drawn, coloured and on the widget") {
            Self.everyReaderDraws(hike, onMovedRoute: true, in: readers)
        }
        #expect(read.isReplaced)
        #expect(fetch.count == 4)
    }

    /// A row the store no longer holds is not a failure. It reads as the
    /// empty line it always has, and owes nothing, so asking again reads
    /// nothing.
    @Test("a hike the store no longer holds is owed nothing")
    func aDeletedRowIsOwedNothing() async throws {
        let hike = Fixture.hike(in: context)
        try context.save()
        let sibling = ModelContext(container)
        let id = hike.id
        let stored = try #require(try sibling.fetch(FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })).first)
        sibling.delete(stored)
        try sibling.save()
        let fetch = FailingLineFetch(failing: [])
        let lines = SelectedLine(fetch: fetch.fetch)

        let read = lines.read(of: hike)
        #expect(await read.route.isEmpty)
        await lines.landing?.value
        #expect(lines.read(of: hike) === read)
        #expect(lines.refreshing == nil, "no refresh asked for")
        #expect(fetch.count == 1)
    }
}
