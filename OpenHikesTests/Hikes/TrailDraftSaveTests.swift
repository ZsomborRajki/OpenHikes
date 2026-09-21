//
//  TrailDraftSaveTests.swift
//  OpenHikesTests
//
//  What a drawn trail becomes.
//
//  The decision this defends is that it becomes **nothing new**: an ordinary
//  ``Hike``, indistinguishable from an imported one, so the map, the library,
//  the widget, GPX export and community publishing all go on working with
//  nothing added to them. A test that asserted a drawn trail was *special* in
//  any way would be a test against that decision — so what is asserted here is
//  that the row is complete and ordinary.
//
//  The refusals are the other half, and they are not interchangeable. One says
//  the drawing is not a trail yet and the other says the disk refused; only
//  the second leaves a drawing worth keeping.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import SwiftData
import Testing

@MainActor
@Suite("Trail draft save")
struct TrailDraftSaveTests {
    private enum Line {
        static let longitude: Double = 12.86
        static let south: Double = 47.6300
        static let north: Double = 47.6340
    }

    private static func draft(_ latitudes: [Double], named name: String = "") -> TrailDraft {
        let draft = TrailDraft()
        for latitude in latitudes {
            draft.append(CLLocationCoordinate2D(latitude: latitude, longitude: Line.longitude))
        }
        draft.name = name
        return draft
    }

    private func context() throws -> ModelContext {
        try Fixture.modelContext()
    }

    @Test("a drawn trail is saved as an ordinary hike")
    func savesAnOrdinaryHike() throws {
        let context = try context()
        let draft = Self.draft([Line.south, Line.north], named: "Ridge Loop")
        let madeOn = Date(timeIntervalSince1970: 1_750_000_000)

        let outcome = TrailDraftSave.hike(from: draft, into: context, madeOn: madeOn)
        let hike = try #require(outcome.hike)

        #expect(hike.title == "Ridge Loop")
        #expect(hike.route.count == 2)
        #expect(hike.date == madeOn)
        #expect(abs(hike.distanceMeters - draft.distanceMeters) < 0.001)
        // Everything a hike from anywhere else has, and nothing a hike from
        // anywhere else lacks: the row is drawable and walkable the moment it
        // lands.
        #expect(!hike.isRecording)
        #expect(hike.rawRoute.isEmpty)
        #expect(hike.tintHex.hasPrefix("#"))
        #expect(try context.fetch(FetchDescriptor<Hike>()).count == 1)
    }

    /// The geometry that reaches the row is exactly the points that were put
    /// down — no elevations invented, no timestamps invented. A drawn trail is
    /// a line, and the chart and the walk figures both read what is here.
    @Test("the saved route is the points, with nothing added to them")
    func routeCarriesOnlyThePoints() throws {
        let context = try context()
        let draft = Self.draft([Line.south, Line.north])

        let hike = try #require(TrailDraftSave.hike(from: draft, into: context).hike)

        #expect(hike.route.map(\.latitude) == [Line.south, Line.north])
        #expect(hike.route.allSatisfy { $0.elevation == nil })
        #expect(hike.route.allSatisfy { $0.timestamp == nil })
    }

    /// The bound is spent here because this is where a typed name starts
    /// reaching payloads with ceilings — see ``HikeTitle``.
    @Test("an unnamed trail is named after the day it was drawn")
    func unnamedTrailTakesTheDate() throws {
        let context = try context()
        let madeOn = Date(timeIntervalSince1970: 1_750_000_000)
        let draft = Self.draft([Line.south, Line.north], named: "   ")

        let hike = try #require(
            TrailDraftSave.hike(from: draft, into: context, madeOn: madeOn).hike
        )

        #expect(!hike.title.isEmpty, "two unnamed trails have to be tellable apart")
        #expect(hike.title == HikeTitle.drawn(name: "   ", madeOn: madeOn))
    }

    @Test("a name longer than a title is bounded on the way in")
    func longNameIsBounded() throws {
        let context = try context()
        let draft = Self.draft(
            [Line.south, Line.north],
            named: String(repeating: "a", count: HikeTitle.maximumCharacters + 40)
        )

        let hike = try #require(TrailDraftSave.hike(from: draft, into: context).hike)

        #expect(hike.title.count == HikeTitle.maximumCharacters)
        #expect(hike.title.utf8.count <= HikeTitle.maximumUTF8Bytes)
    }

    @Test("one point is refused, and nothing is written")
    func onePointIsRefused() throws {
        let context = try context()
        let draft = Self.draft([Line.south])

        guard case .refused(let refusal) = TrailDraftSave.hike(from: draft, into: context) else {
            Issue.record("a single point should not become a hike")
            return
        }
        #expect(refusal == .tooShort)
        #expect(try context.fetch(FetchDescriptor<Hike>()).isEmpty)
    }

    @Test("an empty draft is refused, and nothing is written")
    func emptyDraftIsRefused() throws {
        let context = try context()

        guard case .refused(let refusal) = TrailDraftSave.hike(from: TrailDraft(), into: context)
        else {
            Issue.record("an empty draft should not become a hike")
            return
        }
        #expect(refusal == .tooShort)
        #expect(try context.fetch(FetchDescriptor<Hike>()).isEmpty)
    }

    /// The failure whose whole point is what it does *not* leave behind. A
    /// pending insert the next save accepted would put the hike on the list a
    /// moment after the hiker was told it was not there.
    @Test("a store that refuses leaves no row behind")
    func refusedSaveLeavesNothing() throws {
        let context = try context()
        let draft = Self.draft([Line.south, Line.north], named: "Ridge")

        struct Refused: Error {}
        let outcome = TrailDraftSave.hike(from: draft, into: context) { _ in throw Refused() }

        guard case .refused(let refusal) = outcome else {
            Issue.record("a refused commit should not produce a hike")
            return
        }
        #expect(refusal == .notSaved)
        try context.save()
        #expect(try context.fetch(FetchDescriptor<Hike>()).isEmpty)
    }

    /// The drawing itself is untouched by a save, refused or not: clearing it
    /// is the screen's move and only on the way through a success, which is
    /// what makes *save it again* the right next thing to try.
    @Test("saving does not empty the draft")
    func savingLeavesTheDraftAlone() throws {
        let context = try context()
        let draft = Self.draft([Line.south, Line.north], named: "Ridge")

        _ = TrailDraftSave.hike(from: draft, into: context)

        #expect(draft.waypoints.count == 2)
        #expect(draft.name == "Ridge")
    }
}
