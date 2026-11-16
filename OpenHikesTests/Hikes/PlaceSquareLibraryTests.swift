//
//  PlaceSquareLibraryTests.swift
//  OpenHikesTests
//
//  What the places' pre-built squares answer a search with — and, as much,
//  when they decline to answer.
//
//  The contract is the day hikes' (see `TrailCellLibraryTests`): an answer is
//  complete or it is not given. ``TrailPointSource`` takes an empty answer to
//  mean nothing of those kinds is mapped there, and no answer to mean *ask
//  Overpass*. So the cases worth having are the ones on that line, and what is
//  kept on the device on either side of it, which is also what *Add Place*
//  offers with no signal.
//
//  The database is the day hikes' stub and the directory is the case's own,
//  for the reason the repository's *Deliberate test seams* section gives.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

@Suite("Place square library")
struct PlaceSquareLibraryTests {
    // MARK: - Fixtures

    /// The map above a half-height sheet over the Berchtesgaden valley's
    /// western half: one square, the degree it stands in, which ends at 13°E.
    static let valley = CuratedTrailQuery.BoundingBox(south: 47.598, west: 12.86675, north: 47.642, east: 12.93325)
    static let valleyArea = CommunitySearchArea(
        coordinate: CLLocationCoordinate2D(latitude: 47.62, longitude: 12.90),
        radiusMeters: 3000
    )
    /// A map that straddles 13°E, and so two squares.
    static let straddling = CuratedTrailQuery.BoundingBox(south: 47.6, west: 12.85, north: 47.65, east: 13.05)
    static let valleySquare = "places1_137_192"
    static let eastSquare = "places1_137_193"

    static func node(
        _ id: Int64,
        _ latitude: Double,
        _ longitude: Double,
        _ tags: [String: String]
    ) -> PlaceSquareFile.Place {
        place(.node, id, latitude, longitude, tags)
    }

    static func place(
        _ element: PlaceSquareFile.Element,
        _ id: Int64,
        _ latitude: Double,
        _ longitude: Double,
        _ tags: [String: String]
    ) -> PlaceSquareFile.Place {
        let scale = Double(PlaceSquareFile.standardCoordinateScale)
        return PlaceSquareFile.Place(
            element: element,
            id: id,
            point: PlaceSquareFile.Point(
                latitude: Int32((latitude * scale).rounded()),
                longitude: Int32((longitude * scale).rounded())
            ),
            tags: tags
        )
    }

    /// In the valley: a named summit, an unnamed spring, a hut mapped as a
    /// building, and a car park.
    static let summit = node(1, 47.60, 12.88, ["natural": "peak", "name": "Watzmann", "ele": "2713"])
    static let spring = node(2, 47.61, 12.89, ["natural": "spring"])
    static let hut = place(.way, 3, 47.62, 12.90, ["tourism": "alpine_hut", "name": "Kärlingerhaus"])
    static let carPark = node(4, 47.635, 12.915, ["amenity": "parking"])
    /// In the valley's square, and north of the map.
    static let farFall = node(5, 47.9, 12.5, ["waterway": "waterfall"])
    /// East of 13°E.
    static let eastViewpoint = node(6, 47.62, 13.02, ["tourism": "viewpoint"])

    /// A way covering the box from `southWest` to `northEast`, as the tool
    /// files one.
    static func area(
        _ id: Int64,
        from southWest: (latitude: Double, longitude: Double),
        to northEast: (latitude: Double, longitude: Double),
        _ tags: [String: String]
    ) -> PlaceSquareFile.Place {
        let scale = Double(PlaceSquareFile.standardCoordinateScale)
        return PlaceSquareFile.Place(
            element: .way,
            id: id,
            box: PlaceSquareFile.Box(
                south: Int32((southWest.latitude * scale).rounded()),
                west: Int32((southWest.longitude * scale).rounded()),
                north: Int32((northEast.latitude * scale).rounded()),
                east: Int32((northEast.longitude * scale).rounded())
            ),
            tags: tags
        )
    }

    /// A campsite whose fence crosses 13°E, so the tool files it under the
    /// valley's square and the one east of it.
    static let acrossCampsite = area(
        9,
        from: (latitude: 47.70, longitude: 12.99),
        to: (latitude: 47.71, longitude: 13.01),
        ["tourism": "camp_site"]
    )

    static func found(_ places: [PlaceSquareFile.Place]) -> TrailCellFetch.Cell {
        .found(PlaceSquareFile(places: places).encoded())
    }

    static func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("place-squares-\(UUID().uuidString)")
    }

    /// - Parameter directory: Where the library keeps squares. `nil`, the
    ///   default, keeps none, so every search is a request.
    static func makeLibrary(_ database: StubTrailCellDatabase, directory: URL? = nil) -> PlaceSquareLibrary {
        PlaceSquareLibrary(database: database, directory: directory, clock: TestClock().read)
    }

    /// The OpenStreetMap ids an answer offers, in id order, or a recorded
    /// issue when it is not an answer at all.
    static func offered(_ answer: PlaceSquareAnswer, sourceLocation: SourceLocation = #_sourceLocation) -> [Int64] {
        guard case .places(let places) = answer else {
            Issue.record("the squares gave no answer: \(answer)", sourceLocation: sourceLocation)
            return []
        }
        return places.compactMap(\.osm?.elementID).sorted()
    }

    static let everything = Set(TrailPlaceSymbol.allCases)

    // MARK: - An answer

    @Test("a search asks once, for the squares its map touches, and offers the places on the map")
    func aSearchIsAnswered() async throws {
        let database = StubTrailCellDatabase(cells: [
            Self.valleySquare: Self.found([Self.summit, Self.spring, Self.hut, Self.carPark, Self.farFall]),
        ])

        let answer = try await Self.makeLibrary(database).places(in: [Self.valley], showing: Self.everything)

        #expect(database.requests == [[Self.valleySquare]])
        #expect(Self.offered(answer) == [1, 2, 3, 4], "the waterfall is in the square, and not on the map")
        guard case .places(let places) = answer,
              let watzmann = places.first(where: { $0.osm?.elementID == 1 })
        else { return }
        #expect(watzmann.name == "Watzmann")
        #expect(watzmann.symbol == .summit)
        #expect(watzmann.osm?.elementType == "node")
        #expect(watzmann.osm?.facts == [TrailPlaceFact(kind: .elevation, value: "2713")])
        #expect(watzmann.longitude.isApproximatelyEqual(to: 12.88, absoluteTolerance: 1e-9))
        #expect(places.first { $0.osm?.elementID == 3 }?.osm?.elementType == "way")
    }

    @Test("a map across two squares reads both, in one request")
    func twoSquaresAreOneRequest() async throws {
        let database = StubTrailCellDatabase(cells: [
            Self.valleySquare: Self.found([Self.spring, Self.hut]),
            Self.eastSquare: Self.found([Self.eastViewpoint]),
        ])

        let answer = try await Self.makeLibrary(database).places(in: [Self.straddling], showing: Self.everything)

        #expect(database.requests == [[Self.valleySquare, Self.eastSquare]])
        #expect(Self.offered(answer) == [2, 3, 6])
    }

    /// Two boxes can touch the same square: two parts of one map, or the two
    /// halves of a search the date line splits, both of which touch the
    /// square east of it, since 180° is where that square starts.
    @Test("a square two boxes touch is asked for once, where the first one put it")
    func aSharedSquareIsAskedForOnce() async throws {
        let eastOfTheLine = CuratedTrailQuery.BoundingBox(south: 47.6, west: 13.01, north: 47.65, east: 13.05)
        // On Taveuni, which the date line crosses.
        let taveuni = CommunitySearchArea(
            coordinate: CLLocationCoordinate2D(latitude: -16.8, longitude: 179.99),
            radiusMeters: 3000
        )
        let halves = TrailPointQuery.searchBoxes(for: taveuni)
        let database = StubTrailCellDatabase()
        let library = Self.makeLibrary(database)

        _ = try await library.places(in: [eastOfTheLine, Self.straddling], showing: Self.everything)
        _ = try await library.places(in: halves, showing: Self.everything)

        #expect(halves.count == 2)
        #expect(database.requests == [
            [Self.eastSquare, Self.valleySquare],
            ["places1_73_359", "places1_73_0"],
        ])
    }

    /// Overpass finds a way by its nodes, so a campsite reaching into the
    /// corner of a small map is in its answer though its middle, where the
    /// pin stands, is off the map. Only the middle, and the squares would
    /// leave it out of an answer Overpass is then never asked to correct.
    @Test("a place reaching into the map is offered, though its pin is off it")
    func aPlaceReachingInIsOffered() async throws {
        let campsite = Self.area(
            8,
            from: (latitude: 47.620, longitude: 12.900),
            to: (latitude: 47.622, longitude: 12.902),
            ["tourism": "camp_site"]
        )
        let corner = CommunitySearchArea(
            coordinate: CLLocationCoordinate2D(latitude: 47.620, longitude: 12.900),
            radiusMeters: 100,
            visibleSpan: CommunitySearchArea.Span(latitudeDelta: 0.001, longitudeDelta: 0.001)
        )
        let database = StubTrailCellDatabase(cells: [Self.valleySquare: Self.found([campsite])])

        let answer = try await Self.makeLibrary(database).places(
            in: TrailPointQuery.searchBoxes(for: corner),
            showing: Self.everything
        )

        #expect(Self.offered(answer) == [8])
        guard case .places(let places) = answer, let offered = places.first else { return }
        #expect(offered.latitude.isApproximatelyEqual(to: 47.621, absoluteTolerance: 1e-9), "its middle, off the map")
    }

    /// The tool files a place under every square its box touches, so a map
    /// on either side of the line finds it — and a map across the line,
    /// reading both squares, finds it once.
    @Test("a place filed under two squares is found from either, and offered once")
    func aPlaceAcrossSquaresIsOfferedOnce() async throws {
        let directory = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let eastOfTheLine = CuratedTrailQuery.BoundingBox(south: 47.69, west: 13.005, north: 47.72, east: 13.05)
        let acrossTheLine = CuratedTrailQuery.BoundingBox(south: 47.69, west: 12.95, north: 47.72, east: 13.05)
        let database = StubTrailCellDatabase(cells: [
            Self.valleySquare: Self.found([Self.spring, Self.acrossCampsite]),
            Self.eastSquare: Self.found([Self.acrossCampsite, Self.eastViewpoint]),
        ])
        let library = Self.makeLibrary(database, directory: directory)

        let east = try await library.places(in: [eastOfTheLine], showing: Self.everything)
        let across = try await library.places(in: [acrossTheLine], showing: Self.everything)
        let kept = await library.keptPlaces(
            near: CommunitySearchArea(
                coordinate: CLLocationCoordinate2D(latitude: 47.705, longitude: 13.0),
                radiusMeters: 3000
            ),
            limit: 10
        )

        #expect(database.requests == [[Self.eastSquare], [Self.valleySquare]])
        #expect(Self.offered(east) == [9])
        #expect(Self.offered(across) == [9])
        #expect(kept.compactMap(\.osm?.elementID) == [9])
    }

    /// What a maker's switch turned off means, as it does in the Overpass
    /// request: the kind is not offered.
    @Test("a kind switched off is not offered")
    func aSwitchedOffKindIsLeftOut() async throws {
        let database = StubTrailCellDatabase(cells: [
            Self.valleySquare: Self.found([Self.summit, Self.spring, Self.hut, Self.carPark]),
        ])

        let answer = try await Self.makeLibrary(database).places(in: [Self.valley], showing: [.summit, .shelter])

        #expect(Self.offered(answer) == [1, 3])
    }

    /// The Overpass request asks for car parks and springs as nodes alone, so
    /// a way is only ever there as a kind mapped as an area — and a square
    /// read the same way gives the same answer.
    @Test("a way is a place only as a kind mapped as an area")
    func aWayIsOnlyAnArea() async throws {
        let parkingLot = Self.place(.way, 7, 47.62, 12.90, ["amenity": "parking"])
        let roofOverSpring = Self.place(.way, 8, 47.62, 12.90, ["natural": "spring", "amenity": "shelter"])
        let database = StubTrailCellDatabase(cells: [Self.valleySquare: Self.found([parkingLot, roofOverSpring])])

        let answer = try await Self.makeLibrary(database).places(in: [Self.valley], showing: Self.everything)

        guard case .places(let places) = answer else {
            Issue.record("the squares gave no answer: \(answer)")
            return
        }
        #expect(places.map(\.osm?.elementID) == [8])
        #expect(places.first?.symbol == .shelter, "a spring is asked for as a node, and a shelter as an area too")
    }

    /// No waterfalls in the valley is something the squares can say, and
    /// asking Overpass to confirm it would bring the wait back.
    @Test("a square with no record, in squares that are the whole world, is ground with no places")
    func anAbsentSquareIsEmptyGround() async throws {
        let directory = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = StubTrailCellDatabase()
        let library = Self.makeLibrary(database, directory: directory)

        let first = try await library.places(in: [Self.valley], showing: Self.everything)
        let second = try await library.places(in: [Self.valley], showing: Self.everything)

        #expect(Self.offered(first).isEmpty)
        #expect(Self.offered(second).isEmpty)
        #expect(database.requests.count == 1, "the empty square is kept as one")
    }

    @Test("a square kept on the device is read from it, and nothing is asked")
    func aKeptSquareIsNotAskedAgain() async throws {
        let directory = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = StubTrailCellDatabase(cells: [Self.valleySquare: Self.found([Self.summit])])
        let library = Self.makeLibrary(database, directory: directory)

        _ = try await library.places(in: [Self.valley], showing: Self.everything)
        let again = try await library.places(in: [Self.valley], showing: [.summit])

        #expect(database.requests == [[Self.valleySquare]])
        #expect(Self.offered(again) == [1])
    }

    // MARK: - No answer

    @Test("squares that are not the whole world give no answer, and none is kept", arguments: [
        TrailCellFetch.Manifest.absent, .partial,
    ])
    func partOfTheWorldIsNoAnswer(manifest: TrailCellFetch.Manifest) async throws {
        let directory = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = StubTrailCellDatabase(manifest: manifest, cells: [Self.valleySquare: Self.found([Self.summit])])
        let library = Self.makeLibrary(database, directory: directory)

        let first = try await library.places(in: [Self.valley], showing: Self.everything)
        _ = try await library.places(in: [Self.valley], showing: Self.everything)
        let kept = await library.keptPlaces(near: Self.valleyArea, limit: 10)

        guard case .uncovered = first else {
            Issue.record("a set that is part of the world answered: \(first)")
            return
        }
        #expect(database.requests.count == 2, "nothing of a set that is part of the world is kept")
        #expect(kept.isEmpty)
    }

    @Test("a manifest that could not be read gives no answer")
    func anUnreadManifestIsUnreachable() async throws {
        let database = StubTrailCellDatabase(manifest: .unread, cells: [Self.valleySquare: Self.found([Self.summit])])

        let answer = try await Self.makeLibrary(database).places(in: [Self.valley], showing: Self.everything)

        guard case .unreachable = answer else {
            Issue.record("an unread manifest answered: \(answer)")
            return
        }
    }

    /// The four squares that did arrive are no answer, and they are four the
    /// next search does not fetch.
    @Test("a square that could not be read gives no answer, and the one that arrived is kept")
    func anUnreadSquareKeepsTheRest() async throws {
        let directory = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = StubTrailCellDatabase(cells: [
            Self.valleySquare: Self.found([Self.spring]),
            Self.eastSquare: .failed,
        ])
        let library = Self.makeLibrary(database, directory: directory)

        let first = try await library.places(in: [Self.straddling], showing: Self.everything)
        database.hold(Self.found([Self.eastViewpoint]), as: Self.eastSquare)
        let second = try await library.places(in: [Self.straddling], showing: Self.everything)

        guard case .unreachable = first else {
            Issue.record("a search with a square missing answered: \(first)")
            return
        }
        #expect(database.requests == [[Self.valleySquare, Self.eastSquare], [Self.eastSquare]])
        #expect(Self.offered(second) == [2, 6])
    }

    @Test("a request that fails as a whole gives no answer")
    func aFailedRequestIsUnreachable() async throws {
        let database = StubTrailCellDatabase(cells: [Self.valleySquare: Self.found([Self.summit])])
        database.fail(with: URLError(.notConnectedToInternet))

        let answer = try await Self.makeLibrary(database).places(in: [Self.valley], showing: Self.everything)

        guard case .unreachable = answer else {
            Issue.record("a failed request answered: \(answer)")
            return
        }
    }

    /// A search superseded mid-fetch is not an unreachable square: reported
    /// as one, it would send a request to Overpass for nobody.
    @Test("a cancelled search throws rather than giving no answer")
    func aCancelledSearchThrows() async {
        let database = StubTrailCellDatabase(cells: [Self.valleySquare: Self.found([Self.summit])])
        database.cancelCallers()
        let library = Self.makeLibrary(database)

        // A task of its own, because it is the one the stub cancels: the
        // case's own would end cancelled, and be reported as skipped.
        let search = Task { try await library.places(in: [Self.valley], showing: Self.everything) }

        await #expect(throws: CancellationError.self) {
            _ = try await search.value
        }
    }

    @Test("a search that would need more squares than one request names asks nothing")
    func tooManySquaresIsUncovered() async throws {
        let database = StubTrailCellDatabase()
        let wide = CuratedTrailQuery.BoundingBox(south: 40, west: 0, north: 50, east: 10)

        let answer = try await Self.makeLibrary(database).places(in: [wide], showing: Self.everything)

        guard case .uncovered = answer else {
            Issue.record("a search past the limit answered: \(answer)")
            return
        }
        #expect(database.requests.isEmpty)
    }
}

// MARK: - What is kept

extension PlaceSquareLibraryTests {
    /// What *Add Place* offers before its search answers, and with no signal
    /// at all: every kind, nearest first, and no request.
    @Test("the places of a kept square are offered nearest first, asking nothing")
    func keptPlacesAreOfferedNearestFirst() async throws {
        let directory = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = StubTrailCellDatabase(cells: [
            Self.valleySquare: Self.found([Self.summit, Self.spring, Self.hut, Self.carPark, Self.farFall]),
        ])
        let library = Self.makeLibrary(database, directory: directory)
        let nothingYet = await library.keptPlaces(near: Self.valleyArea, limit: 10)
        _ = try await library.places(in: [Self.valley], showing: [.summit])

        let kept = await library.keptPlaces(near: Self.valleyArea, limit: 2)

        #expect(nothingYet.isEmpty)
        #expect(
            kept.compactMap(\.osm?.elementID) == [3, 2],
            "the hut in the middle, then the spring: a switch is no filter here"
        )
        #expect(database.requests.count == 1)
    }
}
