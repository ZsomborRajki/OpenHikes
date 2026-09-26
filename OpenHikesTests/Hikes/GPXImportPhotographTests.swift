//
//  GPXImportPhotographTests.swift
//  OpenHikesTests
//
//  The read-back half of #473: a `<wpt>` the file marked as a photograph
//  becomes a place on the trail, and every waypoint that is not one is left
//  exactly where it was.
//
//  A suite of its own rather than an extension on `GPXImportTests`, because
//  what it needs is not that suite's fixtures: almost every case here is a
//  file shaped wrong on purpose — a symbol that does not match, a waypoint
//  with no `<time>`, a file with no track at all — and those are the subject
//  rather than variations on a well-formed one.
//
//  The sharpest test in here is `ignoresWaypointsThatAreTheGeometry`. A file
//  whose `<wpt>`s are its only geometry has just had them read as the line,
//  and reading them a second time as photographs would pin one to every
//  vertex of the track it had drawn.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

@Suite("GPX photo waypoints on the way in")
struct GPXImportPhotographTests {
    // MARK: Fixtures

    private static let photographTime = "2026-06-01T08:10:00Z"
    private static let photographLatitude = 47.7100
    private static let photographLongitude = 12.9100

    private func gpxFile(_ xml: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("photo-wpt-\(UUID().uuidString)")
            .appendingPathExtension("gpx")
        try xml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A file with a real track and one waypoint, whose `<name>` and `<sym>`
    /// the caller chooses. The track's own points sit nowhere near the
    /// waypoint, so a coordinate appearing in the wrong place is visible.
    private static func file(
        waypoint: String?,
        name: String = GPXExport.photographName,
        symbol: String = GPXExport.photographSymbol,
        time: String? = photographTime
    ) -> String {
        let waypointXML = waypoint ?? """
            <wpt lat="\(photographLatitude)" lon="\(photographLongitude)">
                <ele>930.0</ele>
                \(time.map { "<time>\($0)</time>" } ?? "")
                <name>\(name)</name>
                <sym>\(symbol)</sym>
            </wpt>
        """
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="OpenHikesTests" xmlns="http://www.topografix.com/GPX/1/1">
        \(waypointXML)
            <trk>
            <name>Thumsee Loop</name>
            <trkseg>
                <trkpt lat="47.6300" lon="12.8600"><ele>600.0</ele><time>2026-06-01T08:05:00Z</time></trkpt>
                <trkpt lat="47.6310" lon="12.8600"><ele>620.0</ele><time>2026-06-01T08:06:00Z</time></trkpt>
            </trkseg>
            </trk>
        </gpx>
        """
    }

    private func imported(_ xml: String) throws -> GPXImport.Track {
        let url = try gpxFile(xml)
        defer { try? FileManager.default.removeItem(at: url) }
        return try GPXImport.load(from: url)
    }

    // MARK: What is read

    @Test("a photo waypoint beside a track comes back as a photograph")
    func readsPhotographBesideATrack() throws {
        let track = try imported(Self.file(waypoint: nil))

        #expect(track.photographs.count == 1)
        let photograph = try #require(track.photographs.first)
        #expect(
            photograph.coordinate.latitude.isApproximatelyEqual(to: Self.photographLatitude, absoluteTolerance: 1e-9)
        )
        #expect(
            photograph.coordinate.longitude.isApproximatelyEqual(to: Self.photographLongitude, absoluteTolerance: 1e-9)
        )
        #expect(photograph.elevation == 930.0)
    }

    /// The route is still the track's, which is the half `GPXExportTests`
    /// already pins from the other direction. Asserted again here because it
    /// is the thing this whole change could break.
    @Test("reading the waypoint leaves the route to the track")
    func leavesTheRouteAlone() throws {
        let track = try imported(Self.file(waypoint: nil))

        #expect(track.route.count == 2)
        #expect(!track.route.contains { $0.latitude == Self.photographLatitude })
    }

    @Test("the photograph's time is the one the file gave it")
    func readsTheCaptureTime() throws {
        let track = try imported(Self.file(waypoint: nil))

        let photograph = try #require(track.photographs.first)
        let expected = try #require(
            Date.ISO8601FormatStyle().parseStrategy.parse(Self.photographTime) as Date?
        )
        #expect(photograph.capturedAt == expected)
    }

    // MARK: What is not read

    /// The one that keeps the fallback honest. `GPXImport.track(from:)` reads
    /// `<wpt>` as track points for a file with no `<trk>` and no `<rte>`; a
    /// file like that must not then have the same elements read a second time
    /// as photographs.
    @Test("waypoints that are the file's only geometry are not also photographs")
    func ignoresWaypointsThatAreTheGeometry() throws {
        let onlyWaypoints = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="OpenHikesTests" xmlns="http://www.topografix.com/GPX/1/1">
            <wpt lat="47.6300" lon="12.8600">
                <time>2026-06-01T08:05:00Z</time>
                <name>\(GPXExport.photographName)</name>
                <sym>\(GPXExport.photographSymbol)</sym>
            </wpt>
            <wpt lat="47.6310" lon="12.8600">
                <time>2026-06-01T08:06:00Z</time>
                <name>\(GPXExport.photographName)</name>
                <sym>\(GPXExport.photographSymbol)</sym>
            </wpt>
        </gpx>
        """

        let track = try imported(onlyWaypoints)

        #expect(track.route.count == 2)
        #expect(track.photographs.isEmpty)
    }

    @Test("a waypoint that is not marked as a photograph is left alone")
    func ignoresOtherWaypoints() throws {
        let track = try imported(Self.file(waypoint: nil, name: "Summit", symbol: "Flag"))

        #expect(track.photographs.isEmpty)
        #expect(track.route.count == 2)
    }

    /// `HikePhoto.capturedAt` is not optional and every candidate substitute
    /// sorts wrongly in the gallery, so a photograph with no `<time>` is the
    /// one thing that is dropped rather than guessed at.
    @Test("a photo waypoint with no time is dropped rather than given one")
    func refusesAPhotographWithNoTime() throws {
        let track = try imported(Self.file(waypoint: nil, time: nil))

        #expect(track.photographs.isEmpty)
    }

    /// The same Web Mercator range check a track point gets. A photograph
    /// cannot be pinned somewhere a track point would have been refused.
    @Test("a photo waypoint outside the representable range is refused")
    func refusesAnUnprojectablePhotograph() throws {
        let unprojectable = """
            <wpt lat="89.9" lon="12.9100">
                <time>\(Self.photographTime)</time>
                <name>\(GPXExport.photographName)</name>
                <sym>\(GPXExport.photographSymbol)</sym>
            </wpt>
        """

        let track = try imported(Self.file(waypoint: unprojectable))

        #expect(track.photographs.isEmpty)
    }

    // MARK: How it is recognised

    /// `<sym>` is the reading intended, but a reader that drops a symbol it
    /// has no glyph for and keeps the label must not cost the round trip.
    @Test("the name alone is enough when the symbol has been dropped")
    func recognisesByNameAlone() throws {
        let noSymbol = """
            <wpt lat="\(Self.photographLatitude)" lon="\(Self.photographLongitude)">
                <time>\(Self.photographTime)</time>
                <name>\(GPXExport.photographName)</name>
            </wpt>
        """

        let track = try imported(Self.file(waypoint: noSymbol))

        #expect(track.photographs.count == 1)
    }

    @Test("the symbol alone is enough when the name has been dropped")
    func recognisesBySymbolAlone() throws {
        let noName = """
            <wpt lat="\(Self.photographLatitude)" lon="\(Self.photographLongitude)">
                <time>\(Self.photographTime)</time>
                <sym>\(GPXExport.photographSymbol)</sym>
            </wpt>
        """

        let track = try imported(Self.file(waypoint: noName))

        #expect(track.photographs.count == 1)
    }

    /// A symbol name is a lookup key in somebody else's table rather than text
    /// this app wrote, so the comparison does not care about its case.
    @Test("recognition does not depend on the case the writer used")
    func recognisesRegardlessOfCase() throws {
        let track = try imported(Self.file(waypoint: nil, name: "photo", symbol: "PHOTO"))

        #expect(track.photographs.count == 1)
    }
}
