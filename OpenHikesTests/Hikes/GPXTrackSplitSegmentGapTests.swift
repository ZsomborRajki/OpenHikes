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
//  The fixes either side of the join are still the track's, though, a
//  one-point segment's included.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

@Suite("GPX track split across segment gaps")
struct GPXTrackSplitSegmentGapTests {
    /// `xml` written to a file of its own, read back as a multi-track
    /// import, and the file removed again.
    private func imported(_ xml: String) throws -> GPXImport.Contents {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "track-split-gap-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "segment-gap.gpx")
        try Data(xml.utf8).write(to: url)
        return try GPXImport.loadAll(from: url)
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

    /// A track far from everything else here, so that the file holds several.
    private static let elsewhereTrack = """
    <trk><name>Elsewhere</name><trkseg>
        <trkpt lat="48.0000" lon="12.0000"/><trkpt lat="48.0010" lon="12.0000"/>
    </trkseg></trk>
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
        let contents = try imported(file(
            waypoints: """
            <wpt lat="47.0500" lon="12.0000"><name>Halfway</name></wpt>
            <wpt lat="47.0500" lon="12.0000"><time>2026-07-01T09:00:00Z</time><sym>Photo</sym></wpt>
            <wpt lat="47.1005" lon="12.0000"><name>On the second piece</name></wpt>
            """,
            tracks: [Self.pausedTrack, Self.elsewhereTrack]
        ))

        try #require(contents.tracks.count == 2)
        #expect(contents.tracks[0].places.map(\.name) == ["On the second piece"])
        #expect(contents.tracks[0].photographs.isEmpty)
        #expect(contents.tracks[1].places.isEmpty)
        #expect(contents.leftOut == .init(offTrack: 2))
    }

    /// Another track crosses the gap about 22 m from a waypoint lying exactly
    /// on the paused track's join. The join is not trail, so the track that
    /// really passes the waypoint is the one it belongs to.
    @Test("a track that really passes a waypoint beats another track's segment gap")
    func realTrackBeatsAGap() throws {
        let contents = try imported(file(
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
        ))

        try #require(contents.tracks.count == 2)
        #expect(contents.tracks[0].places.isEmpty)
        #expect(contents.tracks[1].places.map(\.name) == ["Bridge"])
        #expect(contents.leftOut == .init())
    }

    /// A `<trkseg>` of one fix has no walked leg on either side, and is still
    /// a place the track was. A hut and a photograph on it go to that track,
    /// and so does one on a track made of nothing but such segments.
    @Test("a waypoint on a one-point segment's fix lies on its track")
    func waypointOnALoneFixIsPlaced() throws {
        let contents = try imported(file(
            waypoints: """
            <wpt lat="47.0500" lon="12.0000"><name>Hut</name></wpt>
            <wpt lat="47.0500" lon="12.0000"><time>2026-07-01T09:00:00Z</time><sym>Photo</sym></wpt>
            <wpt lat="48.5000" lon="12.0000"><name>Spring</name></wpt>
            """,
            tracks: [
                """
                <trk><name>Resumed once</name>
                    <trkseg><trkpt lat="47.0000" lon="12.0000"/><trkpt lat="47.0010" lon="12.0000"/></trkseg>
                    <trkseg><trkpt lat="47.0500" lon="12.0000"/></trkseg>
                    <trkseg><trkpt lat="47.1000" lon="12.0000"/><trkpt lat="47.1010" lon="12.0000"/></trkseg>
                </trk>
                """,
                """
                <trk><name>Only fixes</name>
                    <trkseg><trkpt lat="48.5000" lon="12.0000"/></trkseg>
                    <trkseg><trkpt lat="48.6000" lon="12.0000"/></trkseg>
                </trk>
                """,
            ]
        ))

        try #require(contents.tracks.count == 2)
        #expect(contents.tracks[0].places.map(\.name) == ["Hut"])
        #expect(contents.tracks[0].photographs.count == 1)
        #expect(contents.tracks[1].places.map(\.name) == ["Spring"])
        #expect(contents.leftOut == .init())
    }

    /// The rule on its own: a route's paused legs are not measured, their
    /// ends are, and a single point is no route.
    @Test("a paused leg is never measured, and the fixes either side of it are")
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
        // Nothing but a pause: no line, and still two fixes to be near.
        let pauseOnly = [route[1], route[2]]
        let acrossThePause = try #require(GPXTrackSplit.offRouteMeters(of: halfway, along: pauseOnly))
        #expect(acrossThePause > 5000)
        let onAFix = try #require(GPXTrackSplit.offRouteMeters(of: route[2].clCoordinate, along: pauseOnly))
        #expect(onAFix.isApproximatelyEqual(to: 0, absoluteTolerance: 0.001))
        #expect(GPXTrackSplit.offRouteMeters(of: route[0].clCoordinate, along: [route[0]]) == nil)
    }
}
