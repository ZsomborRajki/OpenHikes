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
import OpenHikesData
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

    private static func draft(_ latitudes: [Double]) -> TrailDraft {
        let draft = TrailDraft()
        for latitude in latitudes {
            draft.append(CLLocationCoordinate2D(latitude: latitude, longitude: Line.longitude))
        }
        return draft
    }

    private func context() throws -> ModelContext {
        try Fixture.modelContext()
    }

    private enum Heights {
        static let bottom: Double = 600
        static let top: Double = 900
        static let climb: [Double] = [bottom, top]
        static let gained: Double = 300
        /// Far enough to make a third point somewhere else.
        static let step: Double = 0.004
    }

    /// Heights read for exactly `draft`'s line, as the maker would have them.
    ///
    /// Built by hand rather than through a stubbed source, because what is
    /// under test here is what a *save* does with them — see
    /// ``TrailDraftElevationTests`` for how they are asked for.
    private static func heights(
        for draft: TrailDraft,
        of metres: [Double]
    ) -> RouteHeightSamples {
        let route = draft.routeCoordinates
        return RouteHeightSamples(
            routePointCount: route.count,
            indexes: Array(route.indices),
            coordinates: route,
            heights: metres
        )
    }

    // MARK: The places

    /// A drawn trail's places go with it, as ``TrailPoint`` rows — the one
    /// thing Phase 4 adds to what a save writes.
    @Test("a drawn trail's places are saved with it")
    func savesThePlaces() throws {
        let context = try context()
        let draft = Self.draft([Line.south, Line.north])
        draft.addPlaces([
            TrailPlace(
                latitude: (Line.south + Line.north) / 2,
                longitude: Line.longitude,
                name: "Spring",
                symbol: .water,
                note: "Runs all summer"
            ),
        ])

        let hike = try #require(
            TrailDraftSave.hike(from: draft, named: "Ridge", into: context).hike
        )

        #expect(hike.trailPoints?.count == 1)
        let point = try #require(hike.trailPoints?.first)
        #expect(point.hikeID == hike.id)
        #expect(point.name == "Spring")
        #expect(point.symbolID == TrailPlaceSymbol.water.rawValue)
        #expect(point.note == "Runs all summer")
        // And it is read back as the value everything outside the store works
        // in, ordered against the line it was saved beside.
        #expect(hike.orderedPlaces.map(\.place.name) == ["Spring"])
    }

    /// A search puts everything it found near the line onto the drawing, and
    /// the saved hike keeps only what the line passes. The drawing keeps the
    /// lot, because a refused save has to leave it exactly as it was.
    @Test("a save keeps only the places on the line")
    func savesOnlyThePlacesOnTheLine() throws {
        let context = try context()
        let draft = Self.draft([Line.south, Line.north])
        draft.addPlaces([
            TrailPlace(latitude: Line.south + 0.001, longitude: Line.longitude, name: "Spring"),
            // About 750 m east of the line: found by the search, not walked past.
            TrailPlace(latitude: Line.north, longitude: Line.longitude + 0.01, name: "Summit"),
        ])

        let hike = try #require(
            TrailDraftSave.hike(from: draft, named: "Ridge", into: context).hike
        )

        #expect(hike.trailPoints?.map(\.name) == ["Spring"])
        #expect(draft.places.map(\.name) == ["Spring", "Summit"])
    }

    /// The switch beside *Search This Area* turned off: the places were out of
    /// sight, so none is attached — and the drawing still holds them, since
    /// the switch hid them rather than removing them.
    @Test("a save with the places switched off attaches none of them")
    func savesNoPlacesWhenSwitchedOff() throws {
        let context = try context()
        let draft = Self.draft([Line.south, Line.north])
        draft.addPlaces([
            TrailPlace(latitude: Line.south + 0.001, longitude: Line.longitude, name: "Spring"),
        ])

        let hike = try #require(
            TrailDraftSave.hike(from: draft, named: "Ridge", into: context, keepingPlaces: false).hike
        )

        #expect(hike.places.isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<TrailPoint>()) == 0)
        #expect(draft.places.map(\.name) == ["Spring"])
    }

    /// A place is a spot beside a trail rather than part of one, so it does
    /// not lengthen the route and is not one of its coordinates.
    @Test("a place is not a point of the saved route")
    func placesAreNotRoutePoints() throws {
        let context = try context()
        let draft = Self.draft([Line.south, Line.north])
        let before = draft.distanceMeters
        draft.addPlaces([TrailPlace(latitude: Line.south, longitude: Line.longitude + 0.01)])

        let hike = try #require(
            TrailDraftSave.hike(from: draft, named: "Ridge", into: context).hike
        )

        #expect(hike.route.count == 2)
        #expect(hike.distanceMeters == before)
    }

    /// The floor is about the line, and a place cannot rescue a draft that is
    /// not a trail.
    @Test("a place does not make a one-point drawing saveable")
    func placesDoNotSatisfyTheFloor() throws {
        let context = try context()
        let draft = Self.draft([Line.south])
        draft.addPlaces([TrailPlace(latitude: Line.north, longitude: Line.longitude)])

        let outcome = TrailDraftSave.hike(from: draft, named: "Ridge", into: context)

        #expect(outcome.hike == nil)
        if case .refused(let refusal) = outcome {
            #expect(refusal == .tooShort)
        }
    }

    @Test("a drawn trail is saved as an ordinary hike")
    func savesAnOrdinaryHike() throws {
        let context = try context()
        let draft = Self.draft([Line.south, Line.north])
        let madeOn = Date(timeIntervalSince1970: 1_750_000_000)

        let outcome = TrailDraftSave.hike(
            from: draft,
            named: "Ridge Loop",
            into: context,
            madeOn: madeOn
        )
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

        let hike = try #require(TrailDraftSave.hike(from: draft, named: "", into: context).hike)

        #expect(hike.route.map(\.latitude) == [Line.south, Line.north])
        #expect(hike.route.allSatisfy { $0.elevation == nil })
        #expect(hike.route.allSatisfy { $0.timestamp == nil })
    }

    /// The bound is spent here because this is where a typed name starts
    /// reaching payloads with ceilings — see ``HikeTitle``.
    ///
    /// Three spaces rather than an empty string: what the alert hands over is
    /// whatever was in the field, and a hiker who left it blank and a hiker
    /// who leant on the space bar have both said *name it after today*.
    @Test("an unnamed trail is named after the day it was drawn")
    func unnamedTrailTakesTheDate() throws {
        let context = try context()
        let madeOn = Date(timeIntervalSince1970: 1_750_000_000)
        let draft = Self.draft([Line.south, Line.north])

        let hike = try #require(
            TrailDraftSave.hike(from: draft, named: "   ", into: context, madeOn: madeOn).hike
        )

        #expect(!hike.title.isEmpty, "two unnamed trails have to be tellable apart")
        #expect(hike.title == HikeTitle.drawn(name: "   ", madeOn: madeOn))
    }

    @Test("a name longer than a title is bounded on the way in")
    func longNameIsBounded() throws {
        let context = try context()
        let draft = Self.draft([Line.south, Line.north])
        let typed = String(repeating: "a", count: HikeTitle.maximumCharacters + 40)

        let hike = try #require(
            TrailDraftSave.hike(from: draft, named: typed, into: context).hike
        )

        #expect(hike.title.count == HikeTitle.maximumCharacters)
        #expect(hike.title.utf8.count <= HikeTitle.maximumUTF8Bytes)
    }

    @Test("one point is refused, and nothing is written")
    func onePointIsRefused() throws {
        let context = try context()
        let draft = Self.draft([Line.south])

        guard case .refused(let refusal) = TrailDraftSave.hike(
            from: draft,
            named: "Ridge",
            into: context
        ) else {
            Issue.record("a single point should not become a hike")
            return
        }
        #expect(refusal == .tooShort)
        #expect(try context.fetch(FetchDescriptor<Hike>()).isEmpty)
    }

    @Test("an empty draft is refused, and nothing is written")
    func emptyDraftIsRefused() throws {
        let context = try context()

        guard case .refused(let refusal) = TrailDraftSave.hike(
            from: TrailDraft(),
            named: "",
            into: context
        ) else {
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
        let draft = Self.draft([Line.south, Line.north])

        struct Refused: Error {}
        let outcome = TrailDraftSave.hike(from: draft, named: "Ridge", into: context) { _ in
            throw Refused()
        }

        guard case .refused(let refusal) = outcome else {
            Issue.record("a refused commit should not produce a hike")
            return
        }
        #expect(refusal == .notSaved)
        try context.save()
        #expect(try context.fetch(FetchDescriptor<Hike>()).isEmpty)
    }

    // MARK: The heights

    /// The heights read for the line are written on to it, on the points they
    /// were read at.
    ///
    /// This is the whole of what makes a drawn trail open with a profile: from
    /// here on nothing knows where a height came from, so the chart, the stat
    /// grid, GPX export and a published listing all draw it with nothing added
    /// to any of them.
    @Test("the heights are saved on the line")
    func savesTheHeights() throws {
        let context = try context()
        let draft = Self.draft([Line.south, Line.north])

        let hike = try #require(
            TrailDraftSave.hike(
                from: draft,
                named: "Ridge",
                into: context,
                heights: Self.heights(for: draft, of: Heights.climb)
            ).hike
        )

        #expect(hike.route.compactMap(\.elevation) == Heights.climb)
    }

    /// Heights read for a *different* line are refused rather than applied as
    /// far as they go.
    ///
    /// The failure this forbids is silent and plausible: a leg that snapped
    /// while the name alert was open lengthens the route, and a height read on
    /// a summit would be written on to a point in a valley. The saved trail
    /// simply has no profile, which is what it had a moment earlier.
    @Test("heights read for another line are not saved")
    func refusesHeightsForAnotherLine() throws {
        let context = try context()
        let drawn = Self.draft([Line.south, Line.north])
        let elsewhere = Self.draft([Line.south, Line.north, Line.north + Heights.step])

        let hike = try #require(
            TrailDraftSave.hike(
                from: drawn,
                named: "Ridge",
                into: context,
                heights: Self.heights(for: elsewhere, of: Heights.climb + [Heights.top])
            ).hike
        )

        #expect(hike.route.allSatisfy { $0.elevation == nil })
    }

    /// And the saved row is one the detail screen draws a profile and a climb
    /// from.
    ///
    /// ``HikeDetailPreparation`` is the single walk behind both the hike's own
    /// screen and a published listing's, so asserting on it is asserting on
    /// both — and it is the only thing that says the heights survive being a
    /// `Hike` rather than merely being handed to one.
    @Test("a saved drawn trail prepares into a profile and a climb")
    func preparesIntoAProfile() async throws {
        let context = try context()
        let draft = Self.draft([Line.south, Line.north])

        let hike = try #require(
            TrailDraftSave.hike(
                from: draft,
                named: "Ridge",
                into: context,
                heights: Self.heights(for: draft, of: Heights.climb)
            ).hike
        )
        let prepared = try await HikeDetailPreparation.prepare(
            route: hike.route,
            distanceMeters: hike.distanceMeters
        )

        #expect(prepared.profile.samples.count > 1, "a chart is drawn from more than one sample")
        #expect(prepared.profile.elevation.gainMeters == Heights.gained)
        #expect(prepared.stats.contains { $0.label == "Elevation Gain" })
    }

    /// The drawing itself is untouched by a save, refused or not: clearing it
    /// is the screen's move and only on the way through a success, which is
    /// what makes *save it again* the right next thing to try.
    @Test("saving does not empty the draft")
    func savingLeavesTheDraftAlone() throws {
        let context = try context()
        let draft = Self.draft([Line.south, Line.north])

        _ = TrailDraftSave.hike(from: draft, named: "Ridge", into: context)

        #expect(draft.waypoints.count == 2)
    }
}
