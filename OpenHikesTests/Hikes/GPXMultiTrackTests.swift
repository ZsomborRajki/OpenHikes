//
//  GPXMultiTrackTests.swift
//  OpenHikesTests
//
//  A file with several tracks becomes several hikes — the answer the refusal
//  it used to get already stated, and then left to the hiker on a device with
//  no way to split a file.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@Suite("GPX multi-track import")
struct GPXMultiTrackTests {
    /// Three days of a trip, a track each. The second is unnamed. A hut sits
    /// on day one's line, a spring on day three's, and a viewpoint on
    /// nobody's.
    private static let tripGPX = """
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx version="1.1" creator="OpenHikesTests" xmlns="http://www.topografix.com/GPX/1/1">
        <metadata><name>Alps Week</name><time>2026-07-01T06:00:00Z</time></metadata>
        <wpt lat="47.6310" lon="12.8600"><name>Hut</name></wpt>
        <wpt lat="47.8010" lon="12.9000"><name>Spring</name></wpt>
        <wpt lat="46.0000" lon="10.0000"><name>Far viewpoint</name></wpt>
        <trk><name>Day 1</name><desc>Up to the hut</desc><trkseg>
            <trkpt lat="47.6300" lon="12.8600"><time>2026-07-01T07:00:00Z</time></trkpt>
            <trkpt lat="47.6320" lon="12.8600"><time>2026-07-01T08:00:00Z</time></trkpt>
        </trkseg></trk>
        <trk><trkseg>
            <trkpt lat="47.7000" lon="12.8800"><time>2026-07-02T07:00:00Z</time></trkpt>
            <trkpt lat="47.7020" lon="12.8800"><time>2026-07-02T08:00:00Z</time></trkpt>
        </trkseg></trk>
        <trk><name>Day 3</name><trkseg>
            <trkpt lat="47.8000" lon="12.9000"><time>2026-07-03T07:00:00Z</time></trkpt>
            <trkpt lat="47.8020" lon="12.9000"><time>2026-07-03T08:00:00Z</time></trkpt>
        </trkseg></trk>
    </gpx>
    """

    private func write(_ xml: String, named name: String = "alps-week") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "multitrack-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(name).gpx")
        try Data(xml.utf8).write(to: url)
        return url
    }

    private func openStore(in directory: URL) throws -> ModelContext {
        ModelContext(
            try ModelContainer.openHikes(
                url: directory.appending(path: "OpenHikes.store"),
                localURL: directory.appending(path: "OpenHikesLocal.store")
            )
        )
    }

    // MARK: The parse

    @Test("each track becomes its own, with its own name, notes and start")
    func eachTrackIsItsOwn() throws {
        let contents = try GPXImport.loadAll(from: try write(Self.tripGPX))

        #expect(contents.tracks.count == 3)
        #expect(contents.tracks.map(\.name) == ["Day 1", nil, "Day 3"])
        #expect(contents.tracks.first?.trackDescription == "Up to the hut")
        // The file's <time> is when the first began, not when each did.
        #expect(contents.tracks.map(\.startTime) == [
            ISO8601DateFormatter().date(from: "2026-07-01T07:00:00Z"),
            ISO8601DateFormatter().date(from: "2026-07-02T07:00:00Z"),
            ISO8601DateFormatter().date(from: "2026-07-03T07:00:00Z"),
        ])
        // Never joined: each is only as long as its own two points.
        #expect(contents.tracks.allSatisfy { $0.distanceMeters < 300 })
    }

    /// A `<wpt>` is the file's, not a track's, so the line decides.
    @Test("a waypoint goes to the track it lies on, and one on none is counted and left out")
    func waypointsGoToTheirTrack() throws {
        let contents = try GPXImport.loadAll(from: try write(Self.tripGPX))

        #expect(contents.tracks[0].places.map(\.name) == ["Hut"])
        #expect(contents.tracks[1].places.isEmpty)
        #expect(contents.tracks[2].places.map(\.name) == ["Spring"])
        #expect(contents.unplacedWaypoints == 1)
    }

    /// A route's number counts `<rte>`s, so its words are read from them —
    /// not from an empty `<trk>` that shares the number.
    @Test("a file of routes names each from its own <rte>")
    func routesAreNamedByTheirOwnWords() throws {
        let routes = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
            <trk><name>An empty track</name></trk>
            <rte><name>North loop</name><desc>The long one</desc>
                <rtept lat="47.6300" lon="12.8600"><name>Turn</name></rtept>
                <rtept lat="47.6320" lon="12.8600"/>
            </rte>
            <rte><name>South loop</name>
                <rtept lat="47.5300" lon="12.8600"/><rtept lat="47.5320" lon="12.8600"/>
            </rte>
        </gpx>
        """
        let contents = try GPXImport.loadAll(from: try write(routes))
        #expect(contents.tracks.map(\.name) == ["North loop", "South loop"])
        #expect(contents.tracks.first?.trackDescription == "The long one")
    }

    /// Each route's box is checked before the route is measured. A waypoint
    /// just inside the touching distance must still be kept, including
    /// east-west, where a degree is shortest.
    @Test("the box a route is checked against first keeps every waypoint the line would")
    func boxKeepsWhatTheLineWould() {
        let route = [
            RouteCoordinate(latitude: 60, longitude: 10),
            RouteCoordinate(latitude: 60.01, longitude: 10),
        ]
        // 45 m and 80 m east of the line at 60°N, where a degree of longitude
        // is about 55.8 km.
        let near = CLLocationCoordinate2D(latitude: 60.005, longitude: 10 + 45 / 55_800)
        let far = CLLocationCoordinate2D(latitude: 60.005, longitude: 10 + 80 / 55_800)
        let assigned = GPXTrackSplit.assign([near, far], at: { $0 }, to: [route])
        #expect(assigned[0].map(\.longitude) == [near.longitude])
    }

    /// A line across ±180° is a few hundred metres long, not a span that
    /// stops short of the antimeridian it runs through. Either way round, a
    /// waypoint on it at +180° or -180° is kept, and one beyond the touching
    /// distance on either side is not.
    @Test(
        "a route across the antimeridian keeps the waypoints on it",
        arguments: [(179.99, -179.99), (-179.99, 179.99)]
    )
    func antimeridianKeepsWhatTheLineWould(from west: Double, to east: Double) {
        let route = [
            RouteCoordinate(latitude: 0, longitude: west),
            RouteCoordinate(latitude: 0, longitude: east),
        ]
        let onTheLine = [180.0, -180.0, 179.995, -179.995]
            .map { CLLocationCoordinate2D(latitude: 0, longitude: $0) }
        // 80 m past each end, where a degree of longitude is about 111.3 km.
        let beyond = [179.99 - 80 / 111_300, -179.99 + 80 / 111_300]
            .map { CLLocationCoordinate2D(latitude: 0, longitude: $0) }
        let assigned = GPXTrackSplit.assign(onTheLine + beyond, at: { $0 }, to: [route])
        #expect(assigned[0].map(\.longitude) == onTheLine.map(\.longitude))
    }

    /// A route that ends just short of the antimeridian touches a waypoint
    /// just past it, on the far side of ±180°.
    @Test("a waypoint across the antimeridian from a route's end is still kept")
    func waypointAcrossTheAntimeridianIsKept() {
        let route = [
            RouteCoordinate(latitude: 0, longitude: 179.98),
            RouteCoordinate(latitude: 0, longitude: 179.9998),
        ]
        // 30 m east of the end, past -180°.
        let across = CLLocationCoordinate2D(latitude: 0, longitude: -180 + 30 / 111_300 - 0.0002)
        let assigned = GPXTrackSplit.assign([across], at: { $0 }, to: [route])
        #expect(assigned[0].count == 1)
    }

    /// Two tracks either side of the antimeridian, and a waypoint on each:
    /// the nearer one still wins, so the box does not send everything to the
    /// first route that spans ±180°.
    @Test("across the antimeridian a waypoint still goes to the nearer track")
    func antimeridianKeepsNearestTrack() {
        let crossing = [
            RouteCoordinate(latitude: 10, longitude: 179.99),
            RouteCoordinate(latitude: 10, longitude: -179.99),
        ]
        let elsewhere = [
            RouteCoordinate(latitude: 10.01, longitude: 179.99),
            RouteCoordinate(latitude: 10.01, longitude: -179.99),
        ]
        let onCrossing = CLLocationCoordinate2D(latitude: 10, longitude: 180)
        let onElsewhere = CLLocationCoordinate2D(latitude: 10.01, longitude: -180)
        let assigned = GPXTrackSplit.assign(
            [onCrossing, onElsewhere], at: { $0 }, to: [crossing, elsewhere]
        )
        #expect(assigned[0].map(\.latitude) == [10])
        #expect(assigned[1].map(\.latitude) == [10.01])
    }

    /// The one-track answer is unchanged, `load` included.
    @Test("a one-track file is exactly what it always was")
    func oneTrackIsUnchanged() throws {
        let single = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
            <metadata><name>From the metadata</name></metadata>
            <wpt lat="46.0000" lon="10.0000"><name>Anywhere</name></wpt>
            <trk><trkseg>
                <trkpt lat="47.6300" lon="12.8600"/><trkpt lat="47.6320" lon="12.8600"/>
            </trkseg></trk>
        </gpx>
        """
        let contents = try GPXImport.loadAll(from: try write(single))
        #expect(contents.tracks.count == 1)
        #expect(contents.tracks.first?.name == "From the metadata")
        #expect(contents.tracks.first?.places.count == 1, "a lone track keeps every place, near it or not")
        #expect(contents.unplacedWaypoints == 0)
    }

    @Test("past the track cap, the file is refused as too large")
    func tooManyTracksIsTooLarge() throws {
        var limits = GPXImport.Limits.standard
        limits.maximumTrackCount = 2
        let url = try write(Self.tripGPX)
        #expect(throws: GPXImport.ImportFailure.tooLarge) {
            try GPXImport.loadAll(from: url, limits: limits)
        }
    }

    // MARK: The import

    @Test("the tracks chosen become hikes, named, and committed together")
    func chosenTracksBecomeHikes() async throws {
        let url = try write(Self.tripGPX)
        let context = try openStore(in: url.deletingLastPathComponent())
        var asked: (count: Int, unplaced: Int)?

        let hikes = try await HikeImport.hikes(from: url, into: context) { tracks, unplaced in
            asked = (tracks.count, unplaced)
            return [2, 1]
        }

        #expect(asked?.count == 3)
        #expect(asked?.unplaced == 1)
        // In the file's order, whatever order they were answered in; the
        // unnamed one named for the file and its place in it.
        #expect(hikes.map(\.title) == ["alps-week, Track 2", "Day 3"])
        let stored = try openStore(in: url.deletingLastPathComponent()).fetch(FetchDescriptor<Hike>())
        #expect(stored.count == 2)
    }

    /// Cancelling is the one thing ``GPXImport/ImportFailure/multipleTracks``
    /// still means.
    @Test("choosing none imports nothing")
    func choosingNoneImportsNothing() async throws {
        let url = try write(Self.tripGPX)
        let context = try openStore(in: url.deletingLastPathComponent())

        await #expect(throws: HikeImportFailure.file(.multipleTracks)) {
            _ = try await HikeImport.hikes(from: url, into: context) { _, _ in [] }
        }
        let stored = try openStore(in: url.deletingLastPathComponent()).fetch(FetchDescriptor<Hike>())
        #expect(stored.isEmpty)
    }

    @Test("a one-track file is never asked about")
    func oneTrackIsNotAsked() async throws {
        let single = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
            <trk><name>Thumsee</name><trkseg>
                <trkpt lat="47.6300" lon="12.8600"/><trkpt lat="47.6320" lon="12.8600"/>
            </trkseg></trk>
        </gpx>
        """
        let url = try write(single)
        let context = try openStore(in: url.deletingLastPathComponent())
        var asked = false

        let hikes = try await HikeImport.hikes(from: url, into: context) { _, _ in
            asked = true
            return []
        }

        #expect(!asked)
        #expect(hikes.map(\.title) == ["Thumsee"])
    }

    @Test("several failed files are one sentence naming each")
    func severalFailuresAreOneAlert() {
        let failure = HikeImportFailure.several([
            .init(fileName: "a.gpx", reason: "This file couldn't be read."),
            .init(fileName: "b.gpx", reason: "This GPX file is too large to import."),
        ])
        #expect(failure.errorDescription == "2 files couldn't be imported.")
        #expect(failure.recoverySuggestion?.contains("a.gpx: This file couldn't be read.") == true)
        #expect(failure.recoverySuggestion?.contains("b.gpx") == true)
        let one = HikeImportFailure.several([.init(fileName: "a.gpx", reason: "This file couldn't be read.")])
        #expect(one.errorDescription == "1 file couldn't be imported.")
    }
}
