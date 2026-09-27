//
//  PlacesNearbyTests.swift
//  OpenHikesTests
//
//  *Places Nearby*, the recording's look around: where the map is pointed
//  when it opens, that the first search asks about exactly that frame rather
//  than waiting for the camera, and the order the list is read in — see
//  ``HikePlacesNearbyView``.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import OpenHikesData
import Synchronization
import Testing

@MainActor
@Suite("Places nearby")
struct PlacesNearbyTests {
    /// Answers with what it was built with and remembers every area asked.
    private final class AreaRecordingSource: TrailPointSourcing, Sendable {
        let answer: [TrailPlace]
        private let asked = Mutex<[CommunitySearchArea]>([])

        init(answer: [TrailPlace]) {
            self.answer = answer
        }

        var areas: [CommunitySearchArea] { asked.withLock { $0 } }

        func places(near area: CommunitySearchArea, showing _: Set<TrailPlaceSymbol>) -> [TrailPlace] {
            asked.withLock { $0.append(area) }
            return answer
        }
    }

    private static let here = CLLocationCoordinate2D(latitude: 47.60, longitude: 12.90)

    /// MapKit turns metres into degrees on its own model of the Earth, and
    /// ``spanMeters(_:)`` turns them back on a sphere, so a span is only
    /// expected back to within a couple of percent.
    private static let projectionSlack = 0.98

    private static func metres(east meters: Double, of origin: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: origin.latitude,
            longitude: origin.longitude
                + meters / (RouteGeometry.metersPerDegreeLatitude * cos(origin.latitude * .pi / 180))
        )
    }

    private static func spanMeters(_ region: MKCoordinateRegion) -> (latitude: Double, longitude: Double) {
        let perDegree = RouteGeometry.metersPerDegreeLatitude
        return (
            region.span.latitudeDelta * perDegree,
            region.span.longitudeDelta * perDegree * cos(region.center.latitude * .pi / 180)
        )
    }

    // MARK: - The frame

    @Test("with neither a walk nor a fix there is nothing to frame")
    func nothingToFrame() {
        #expect(PlacesNearbyFrame.region(line: [], position: nil) == nil)
    }

    /// The first minutes of a walk are a few hundred metres of line, and a
    /// look around that is only that wide shows the car park.
    @Test("a short walk is framed at least two kilometres across, around the hiker")
    func shortWalkGetsTheMinimum() throws {
        let line = [Self.here, Self.metres(east: 150, of: Self.here)]
        let region = try #require(PlacesNearbyFrame.region(line: line, position: Self.metres(east: 300, of: Self.here)))
        let span = Self.spanMeters(region)

        #expect(span.latitude >= PlacesNearbyFrame.minimumSpanMeters * Self.projectionSlack)
        #expect(span.longitude >= PlacesNearbyFrame.minimumSpanMeters * Self.projectionSlack)
        #expect(abs(region.center.latitude - Self.here.latitude) < 0.01)
    }

    /// Framed whole and padded, so both ends are inside the frame rather than
    /// on its edge.
    @Test("a walk of a few kilometres is framed whole, with room around it")
    func walkIsFramedWhole() throws {
        let end = Self.metres(east: 6000, of: Self.here)
        let region = try #require(PlacesNearbyFrame.region(line: [Self.here, end], position: end))
        let span = Self.spanMeters(region)

        #expect(span.longitude > 6000 * 1.3)
        #expect(span.longitude < 6000 * 1.5)
        #expect(PlacesNearbyFrame.area(of: region).radiusMeters <= TrailPointQuery.maximumRadiusMeters)
    }

    /// A day's walk is wider than one search may ask about; the hiker's own
    /// surroundings are the question the screen exists for.
    @Test("a walk too long to search in one go gives way to the hiker's surroundings")
    func longWalkFallsBackToTheHiker() throws {
        let start = Self.metres(east: -25_000, of: Self.here)
        let region = try #require(PlacesNearbyFrame.region(line: [start, Self.here], position: Self.here))

        #expect(abs(region.center.longitude - Self.here.longitude) < 0.0001)
        #expect(Self.spanMeters(region).longitude < PlacesNearbyFrame.minimumSpanMeters / Self.projectionSlack)
    }

    @Test("without a fix the frame is the walk's own last stretch")
    func noFixFramesTheLine() throws {
        let region = try #require(PlacesNearbyFrame.region(line: [Self.here], position: nil))
        #expect(abs(region.center.latitude - Self.here.latitude) < 0.0001)
    }

    // MARK: - The first search

    /// The screen asks the map to show the frame and asks about it at once:
    /// the map has not settled on it yet, so the settled area would be the
    /// wrong one — or none.
    @Test("a search of a given area asks about that area, with no settled map")
    func searchesTheGivenArea() async throws {
        let spring = TrailPlace(latitude: 47.601, longitude: 12.901, name: "Spring", symbol: .water)
        let source = AreaRecordingSource(answer: [spring])
        let finder = TrailPointFinder(source: source)
        var delivered: [TrailPlace] = []
        finder.onFound { delivered = $0 }
        let region = try #require(PlacesNearbyFrame.region(line: [], position: Self.here))
        let area = PlacesNearbyFrame.area(of: region)

        #expect(finder.searchableArea == nil)
        #expect(finder.search(in: area, along: [], avoiding: []))
        #expect(finder.isSearching)
        #expect(!finder.search(in: area, along: [], avoiding: []), "one request out at a time")
        while finder.isSearching {
            await Task.yield()
        }

        #expect(source.areas == [area])
        #expect(delivered.map(\.name) == ["Spring"])
    }

    @Test("an area past the query's ceiling is not asked about")
    func refusesTooWideAnArea() {
        let source = AreaRecordingSource(answer: [])
        let finder = TrailPointFinder(source: source)

        let isTaken = finder.search(
            in: CommunitySearchArea(coordinate: Self.here, radiusMeters: TrailPointQuery.maximumRadiusMeters + 1),
            along: [],
            avoiding: []
        )

        #expect(!isTaken)
        #expect(!finder.isSearching)
        #expect(source.areas.isEmpty)
    }

    // MARK: - Asking again

    private static let askedArea = CommunitySearchArea(coordinate: here, radiusMeters: 1500)

    /// The first search goes out as the screen opens, so a chip tapped a
    /// second later is refused by the finder — and must still be asked for
    /// once that search lands.
    @Test("a kind switched on while a search is out is asked for after it lands")
    func refusedKindIsAskedLater() {
        var asked = PlacesNearbySearch()
        asked.ask(Self.askedArea, for: [.water], isTaken: true)
        asked.ask(Self.askedArea, for: [.water, .shelter], isTaken: false)

        #expect(asked.widened(showing: [.water, .shelter]) == Self.askedArea)
        asked.answer(keeping: [.water, .shelter])
        #expect(asked.widened(showing: [.water, .shelter]) == Self.askedArea, "the answer was for water alone")

        asked.ask(Self.askedArea, for: [.water, .shelter], isTaken: true)
        #expect(asked.widened(showing: [.water, .shelter]) == nil)
        #expect(asked.widened(showing: [.water]) == nil, "narrowing only filters")
    }

    /// The finder drops a kind switched off while its request is out, so
    /// that kind was never answered for.
    @Test("a kind switched off while a search is out is asked for when it comes back")
    func kindDroppedAtLandingIsAskedAgain() {
        var asked = PlacesNearbySearch()
        asked.ask(Self.askedArea, for: [.water, .shelter], isTaken: true)
        asked.answer(keeping: [.water])

        #expect(asked.widened(showing: [.water, .shelter]) == Self.askedArea)
    }

    /// Returning from *Add Place* or a photograph must not move the map or
    /// spend a request — only a search that screen's arrival cut off is
    /// asked again.
    @Test("coming back asks again only a search that never answered")
    func onlyAnInterruptedSearchIsAskedAgain() {
        var asked = PlacesNearbySearch()
        #expect(!asked.hasAsked)
        #expect(asked.interrupted == nil)

        asked.ask(Self.askedArea, for: [.water], isTaken: true)
        #expect(asked.hasAsked)
        #expect(asked.interrupted == Self.askedArea)

        asked.answer(keeping: [.water])
        #expect(asked.interrupted == nil)
    }

    // MARK: - The list

    /// Nearest first, the walk's own places among the found ones — the order
    /// a hiker looking around reads.
    @Test("rows are nearest the hiker first, the walk's own among them")
    func rowsAreNearestFirst() {
        let far = TrailPlace(coordinate: Self.metres(east: 900, of: Self.here), name: "Hut")
        let near = TrailPlace(coordinate: Self.metres(east: 100, of: Self.here), name: "Spring")
        let held = TrailPlace(coordinate: Self.metres(east: 400, of: Self.here), name: "Bench")

        let entries = PlacesNearbyEntry.sorted(
            held: [TrailPlaceRow(place: held, anchor: nil)],
            candidates: [TrailPlaceRow(place: far, anchor: nil), TrailPlaceRow(place: near, anchor: nil)],
            from: Self.here
        )

        #expect(entries.map(\.entry.row.place.name) == ["Spring", "Bench", "Hut"])
        #expect(entries.map(\.entry.isAdded) == [false, true, false])
        #expect(abs((entries.first?.meters ?? 0) - 100) < 1)
    }
}
