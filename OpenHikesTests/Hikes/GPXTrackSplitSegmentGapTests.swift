//
//  GPXTrackSplitSegmentGapTests.swift
//  OpenHikesTests
//
//  A multi-track file's waypoints are shared out along the ground each track
//  walked, never along the leg between two of its `<trkseg>`s (#991).
//
//  A segment break is a pause, and a paused leg is not trail (#962): the
//  saved hike's `RouteProfile` never matches onto it. The split used to
//  measure each track as one flat line, so a waypoint on the straight join
//  between two segments — kilometres from either — was pinned to that track
//  and counted as placed, and it beat another track that really passed it.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("GPX track split across segment gaps")
struct GPXTrackSplitSegmentGapTests {
    private func write(_ xml: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "track-split-gap-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "segment-gap.gpx")
        try Data(xml.utf8).write(to: url)
        return url
    }

    /// Two short walks on one meridian, about eleven kilometres apart and one
    /// `<trk>`: the file's own pause between them.
    private static let pausedTrack = """
    <trk><name>Paused</name>
        <trkseg>
            <trkpt lat="47.0000" lon="12.0000"/><trkpt lat="47.0010" lon="12.0000"/>
        </trkseg>
        <trkseg>
            <trkpt lat="47.1000" lon="12.0000"/><trkpt lat="47.1010" lon="12.0000"/>
        </trkseg>
    </trk>
    """

    private func file(waypoints: String, tracks: [String]) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="OpenHikesTests" xmlns="http://www.topografix.com/GPX/1/1">
            \(waypoints)
            \(tracks.joined(separator: "\n"))
        </gpx>
        """
    }

    /// A place and a photograph halfway along the join, over five kilometres
    /// from either walked piece, lie on no track: both are left out and
    /// counted. A place on the second piece still goes to the track, so the
    /// pieces themselves are still measured.
    @Test("a waypoint on the leg between two segments lies on no track")
    func waypointOnTheGapIsUnplaced() throws {
        let xml = file(
            waypoints: """
            <wpt lat="47.0500" lon="12.0000"><name>Halfway</name></wpt>
            <wpt lat="47.0500" lon="12.0000"><time>2026-07-01T09:00:00Z</time><sym>Photo</sym></wpt>
            <wpt lat="47.1005" lon="12.0000"><name>On the second piece</name></wpt>
            """,
            tracks: [
                Self.pausedTrack,
                """
                <trk><name>Elsewhere</name><trkseg>
                    <trkpt lat="48.0000" lon="12.0000"/><trkpt lat="48.0010" lon="12.0000"/>
                </trkseg></trk>
                """,
            ]
        )

        let contents = try GPXImport.loadAll(from: try write(xml))

        try #require(contents.tracks.count == 2)
        #expect(contents.tracks[0].places.map(\.name) == ["On the second piece"])
        #expect(contents.tracks[0].photographs.isEmpty)
        #expect(contents.tracks[1].places.isEmpty)
        #expect(contents.unplacedWaypoints == 2)
    }

    /// Another track crosses the gap about 22 m from a waypoint lying exactly
    /// on the paused track's join. The join is not trail, so the track that
    /// really passes the waypoint is the one it belongs to.
    @Test("a track that really passes a waypoint beats another track's segment gap")
    func realTrackBeatsAGap() throws {
        let xml = file(
            waypoints: """
            <wpt lat="47.0500" lon="12.0000"><name>Bridge</name></wpt>
            """,
            tracks: [
                Self.pausedTrack,
                """
                <trk><name>Crossing</name><trkseg>
                    <trkpt lat="47.0502" lon="11.9900"/><trkpt lat="47.0502" lon="12.0100"/>
                </trkseg></trk>
                """,
            ]
        )

        let contents = try GPXImport.loadAll(from: try write(xml))

        try #require(contents.tracks.count == 2)
        #expect(contents.tracks[0].places.isEmpty)
        #expect(contents.tracks[1].places.map(\.name) == ["Bridge"])
        #expect(contents.unplacedWaypoints == 0)
    }

    /// The rule on its own: a route's paused legs are not measured, and a
    /// route made only of them has no line to be near.
    @Test("a paused leg is never measured")
    func pausedLegIsNotMeasured() throws {
        let route = [
            RouteCoordinate(latitude: 47, longitude: 12),
            RouteCoordinate(latitude: 47.001, longitude: 12),
            RouteCoordinate(latitude: 47.1, longitude: 12, boundary: .paused),
            RouteCoordinate(latitude: 47.101, longitude: 12),
        ]
        let halfway = CLLocationCoordinate2D(latitude: 47.05, longitude: 12)

        let offRoute = try #require(GPXTrackSplit.offRouteMeters(of: halfway, along: route))
        #expect(offRoute > 5000)
        #expect(GPXTrackSplit.offRouteMeters(of: halfway, along: [route[1], route[2]]) == nil)
    }
}
