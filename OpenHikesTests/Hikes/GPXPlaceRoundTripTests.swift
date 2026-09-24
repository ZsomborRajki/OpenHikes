//
//  GPXPlaceRoundTripTests.swift
//  OpenHikesTests
//
//  A marked place, out through `<wpt>` and back.
//
//  Two files' worth of behaviour meets here, which is why it is its own suite
//  rather than an extension of either: `<wpt>` already means *photograph* to
//  this app, and Phase 4 gives the same element a second meaning. The rule
//  that keeps them apart is one predicate — a waypoint is a photograph, or it
//  is a place — and a round trip is the only thing that can show both halves
//  of it working at once.
//
//  The other new behaviour asserted here is about files this app did not
//  write. Before Phase 4 a `<wpt>` that was not one of our photographs was
//  dropped on the floor, so a GPX carrying somebody else's huts and springs
//  arrived as a bare line. They are kept now.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("GPX places")
struct GPXPlaceRoundTripTests {
    private enum Line {
        static let longitude = 12.98
        static let south = 47.60
        static let north = 47.62
    }

    private static func track(places: [TrailPlace]) -> GPXExport.Track {
        GPXExport.Track(
            name: "Ridge",
            trackDescription: nil,
            author: nil,
            keywords: nil,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            route: [
                RouteCoordinate(latitude: Line.south, longitude: Line.longitude),
                RouteCoordinate(latitude: Line.north, longitude: Line.longitude),
            ],
            places: places
        )
    }

    private static func reimported(_ track: GPXExport.Track) throws -> GPXImport.Track {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("places-\(UUID().uuidString).gpx")
        try GPXExport.data(for: track).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try GPXImport.load(from: url)
    }

    // MARK: Out and back

    @Test("a named place with a symbol and a note round-trips")
    func aFullPlaceRoundTrips() throws {
        let place = TrailPlace(
            latitude: Line.south + 0.005,
            longitude: Line.longitude,
            name: "Kühroint",
            symbol: .shelter,
            note: "Open in summer"
        )

        let read = try Self.reimported(Self.track(places: [place]))

        #expect(read.places.count == 1)
        let restored = try #require(read.places.first)
        #expect(restored.name == "Kühroint")
        #expect(restored.symbol == .shelter)
        #expect(restored.note == "Open in summer")
        #expect(abs(restored.latitude - place.latitude) < 0.000001)
        #expect(abs(restored.longitude - place.longitude) < 0.000001)
    }

    /// A place from OpenStreetMap keeps its element through a file, as the
    /// page link GPX has room for, so it comes back OpenStreetMap's rather
    /// than the hiker's own to rename.
    @Test("a place from OpenStreetMap round-trips its element")
    func openStreetMapElementRoundTrips() throws {
        let place = TrailPlace(
            latitude: Line.south + 0.005,
            longitude: Line.longitude,
            name: "Kärlingerhaus",
            symbol: .shelter,
            osm: TrailPlaceOSM(elementType: "way", elementID: 42)
        )

        let restored = try #require(try Self.reimported(Self.track(places: [place])).places.first)

        #expect(restored.osm?.elementType == "way")
        #expect(restored.osm?.elementID == 42)
        #expect(restored.isHikersOwn == false)
    }

    @Test("a link to anywhere but an OpenStreetMap element is not an element")
    func otherLinksAreIgnored() throws {
        func element(_ link: String) throws -> TrailPlaceOSM? {
            TrailPlaceOSM(url: try #require(URL(string: link)))
        }
        #expect(try element("https://example.com/node/1") == nil)
        #expect(try element("https://www.openstreetmap.org/area/1") == nil)
        #expect(try element("https://www.openstreetmap.org/node/0") == nil)
        #expect(try element("https://www.openstreetmap.org/node/7")?.elementID == 7)
    }

    /// Unnamed is the normal case, and a file full of blank `<name>`s would
    /// lose the only thing those places had — so the symbol's own word is
    /// written out and read back as the name.
    @Test("an unnamed place is written out under its symbol's word")
    func unnamedPlacesAreWrittenUnderTheirSymbol() throws {
        let place = TrailPlace(
            latitude: Line.south + 0.005,
            longitude: Line.longitude,
            symbol: .water
        )

        let xml = GPXExport.xml(for: Self.track(places: [place]))
        #expect(xml.contains("<name>Water</name>"))
        #expect(xml.contains("<sym>Water</sym>"))

        let read = try Self.reimported(Self.track(places: [place]))
        #expect(read.places.first?.name == "Water")
        #expect(read.places.first?.symbol == .water)
    }

    /// An unstated symbol is a real answer, and `<sym></sym>` would be a claim
    /// that it is a symbol nobody has.
    @Test("a place that claims nothing writes no symbol")
    func placesWithNoSymbolWriteNone() throws {
        let place = TrailPlace(latitude: Line.south + 0.005, longitude: Line.longitude)

        let xml = GPXExport.xml(for: Self.track(places: [place]))
        #expect(!xml.contains("<sym>"))
        #expect(xml.contains("<name>Place</name>"))

        let read = try Self.reimported(Self.track(places: [place]))
        #expect(read.places.first?.symbol == nil)
    }

    /// Every one of the eight has to survive, because the raw value is doing
    /// two jobs — the stored id and the `<sym>` — and a mismatch between them
    /// would be silent.
    @Test("every symbol survives the round trip")
    func everySymbolRoundTrips() throws {
        let places = TrailPlaceSymbol.allCases.enumerated().map { index, symbol in
            TrailPlace(
                latitude: Line.south + 0.001 * Double(index + 1),
                longitude: Line.longitude,
                symbol: symbol
            )
        }

        let read = try Self.reimported(Self.track(places: places))

        #expect(read.places.count == TrailPlaceSymbol.allCases.count)
        #expect(read.places.compactMap(\.symbol) == TrailPlaceSymbol.allCases)
    }

    /// The order the hiker will walk past them, which is what makes a file
    /// opened in another reader list them the way this app does.
    @Test("places are written in along-route order")
    func placesAreWrittenInAlongRouteOrder() throws {
        let far = TrailPlace(
            latitude: Line.north - 0.002,
            longitude: Line.longitude,
            name: "Far"
        )
        let near = TrailPlace(
            latitude: Line.south + 0.002,
            longitude: Line.longitude,
            name: "Near"
        )
        // Handed over in along-route order, which is what ``Hike/orderedPlaces``
        // produces and what `Track(hike:)` passes.
        let ordered = TrailPlaceOrder.ordered([far, near], along: Self.track(places: []).route)

        let read = try Self.reimported(Self.track(places: ordered.map(\.place)))

        #expect(read.places.map(\.name) == ["Near", "Far"])
    }

    // MARK: The two meanings of `<wpt>`

    /// One predicate keeps them apart, and this is the pair that says so: a
    /// photograph is not read as a place, and a place is not read as a
    /// photograph.
    @Test("a photograph waypoint is not read as a place")
    func photographsAreNotPlaces() throws {
        var track = Self.track(places: [
            TrailPlace(latitude: Line.south + 0.005, longitude: Line.longitude, symbol: .summit),
        ])
        track.photographs = [
            GPXExport.Photograph(
                coordinate: RouteCoordinate(latitude: Line.south + 0.008, longitude: Line.longitude),
                capturedAt: Date(timeIntervalSince1970: 1_700_000_500)
            ),
        ]

        let read = try Self.reimported(track)

        #expect(read.photographs.count == 1)
        #expect(read.places.count == 1)
        #expect(read.places.first?.symbol == .summit)
    }

    // MARK: Somebody else's file

    /// The point of reading `<wpt>`s at all: a file this app did not write
    /// arrives with its huts and its springs rather than as a bare line.
    @Test("a stranger's waypoints arrive as places")
    func strangersWaypointsBecomePlaces() throws {
        // Flat rather than indented: the linter reads the lines of a
        // multi-line literal as code, and GPX does not care.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="SomeoneElse" xmlns="http://www.topografix.com/GPX/1/1">
        <wpt lat="47.605" lon="12.98">
        <name>Wasserfall</name>
        <desc>Loud in spring</desc>
        <sym>Waterfall</sym>
        </wpt>
        <trk><trkseg>
        <trkpt lat="47.60" lon="12.98"></trkpt>
        <trkpt lat="47.62" lon="12.98"></trkpt>
        </trkseg></trk>
        </gpx>
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stranger-\(UUID().uuidString).gpx")
        try Data(xml.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let read = try GPXImport.load(from: url)

        #expect(read.places.count == 1)
        let place = try #require(read.places.first)
        #expect(place.name == "Wasserfall")
        #expect(place.note == "Loud in spring")
        // `Waterfall` is not one of the eight, and guessing at somebody else's
        // symbol table is the thing this deliberately does not do. The name
        // and the note are what it keeps.
        #expect(place.symbol == nil)
    }

    /// A file whose waypoints *are* its geometry has just had them read as the
    /// line, and reading them again would mark every vertex of the track it
    /// drew — the same guard the photographs already make.
    @Test("a file whose route is its waypoints marks nothing")
    func waypointOnlyFilesMarkNothing() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="SomeoneElse" xmlns="http://www.topografix.com/GPX/1/1">
        <wpt lat="47.60" lon="12.98"><name>One</name></wpt>
        <wpt lat="47.61" lon="12.98"><name>Two</name></wpt>
        <wpt lat="47.62" lon="12.98"><name>Three</name></wpt>
        </gpx>
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wptonly-\(UUID().uuidString).gpx")
        try Data(xml.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let read = try GPXImport.load(from: url)

        #expect(read.route.count == 3, "the waypoints are the line")
        #expect(read.places.isEmpty)
    }

    /// Every place is a CloudKit record, so an unattended file cannot be
    /// allowed to write ten thousand of them — and refusing the file instead
    /// would lose a route that is perfectly fine.
    @Test("a file with more waypoints than the ceiling is cut rather than refused")
    func tooManyWaypointsAreCut() throws {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="SomeoneElse" xmlns="http://www.topografix.com/GPX/1/1">

        """
        for index in 0..<(GPXImport.maximumPlaces + 20) {
            let latitude = Line.south + 0.00001 * Double(index)
            xml += "<wpt lat=\"\(latitude)\" lon=\"12.98\"><name>P\(index)</name></wpt>\n"
        }
        xml += """
        <trk><trkseg>
        <trkpt lat="47.60" lon="12.98"></trkpt>
        <trkpt lat="47.62" lon="12.98"></trkpt>
        </trkseg></trk>
        </gpx>
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("many-\(UUID().uuidString).gpx")
        try Data(xml.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let read = try GPXImport.load(from: url)

        #expect(read.places.count == GPXImport.maximumPlaces)
        #expect(read.route.count == 2, "the line is untouched")
    }
}
