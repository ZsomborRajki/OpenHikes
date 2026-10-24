//
//  GPXMultiTrackPlaceCapTests.swift
//  OpenHikesTests
//
//  A multi-track file's place cap is spent on the waypoints that lie on a
//  track, after they are shared out, and whatever it cuts is counted (#1037).
//
//  The cap used to take the file's first ``GPXImport/maximumPlaces`` places
//  before the split asked which track each lay on. Waypoints on no track used
//  up the slots, so a later track could arrive with none of the places lying
//  on it — and those were in neither the places nor the count the
//  confirmation reports.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("GPX multi-track place cap")
struct GPXMultiTrackPlaceCapTests {
    private func imported(_ xml: String) throws -> GPXImport.Contents {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "place-cap-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "place-cap.gpx")
        try Data(xml.utf8).write(to: url)
        return try GPXImport.loadAll(from: url)
    }

    /// About 4.4 m of latitude, so even a few hundred waypoints in a row
    /// stay within a track's 1.1 km.
    private static let step = 0.00004

    /// Track A runs north from 47.00° and track B from 47.05°, both on the
    /// 12° meridian and about 1.1 km long; 12.5° is some 38 km east of both.
    private static func file(offTrack: Int, onA: Int, onB: Int) -> String {
        var waypoints = ""
        for index in 0..<offTrack {
            waypoints += #"<wpt lat="\#(47 + 0.0001 * Double(index))" lon="12.5"><name>Hut \#(index)</name></wpt>"#
        }
        for index in 0..<onA {
            waypoints += #"<wpt lat="\#(47 + Self.step * Double(index))" lon="12"><name>A \#(index)</name></wpt>"#
        }
        for index in 0..<onB {
            waypoints += #"<wpt lat="\#(47.05 + Self.step * Double(index))" lon="12"><name>B \#(index)</name></wpt>"#
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="OpenHikesTests" xmlns="http://www.topografix.com/GPX/1/1">
        \(waypoints)
        <trk><name>A</name><trkseg>
            <trkpt lat="47.0000" lon="12.0000"/><trkpt lat="47.0100" lon="12.0000"/>
        </trkseg></trk>
        <trk><name>B</name><trkseg>
            <trkpt lat="47.0500" lon="12.0000"/><trkpt lat="47.0600" lon="12.0000"/>
        </trkseg></trk>
        </gpx>
        """
    }

    /// The issue's own file: 180 huts on neither track come first, then 20
    /// on A and 50 on B. Only the 70 on a track compete for the cap, and all
    /// of them fit.
    @Test("waypoints on no track do not spend the cap")
    func offTrackWaypointsSpendNothing() throws {
        let contents = try imported(Self.file(offTrack: 180, onA: 20, onB: 50))

        #expect(contents.tracks.map(\.places.count) == [20, 50])
        #expect(contents.tracks[1].places.first?.name == "B 0")
        #expect(contents.leftOut == .init(offTrack: 180))
    }

    /// Past the cap on a track, the file's first places on a track are kept,
    /// wherever the off-track ones fall, and the rest are counted as cut
    /// rather than as lying on no track.
    @Test("past the cap, the first places on a track are kept and the rest counted")
    func pastTheCapIsCounted() throws {
        let limit = GPXImport.maximumPlaces
        let contents = try imported(Self.file(offTrack: 30, onA: limit - 20, onB: 70))

        #expect(contents.tracks.map(\.places.count) == [limit - 20, 20])
        #expect(contents.tracks[1].places.map(\.name) == (0..<20).map { "B \($0)" })
        #expect(contents.leftOut == .init(offTrack: 30, pastPlaceLimit: 50))
    }

    /// One track alone over the cap: the other keeps none, and the count says
    /// how many of the first one's were cut.
    @Test("one track past the cap on its own is cut and counted")
    func oneTrackPastTheCap() throws {
        let limit = GPXImport.maximumPlaces
        let contents = try imported(Self.file(offTrack: 0, onA: limit + 5, onB: 0))

        #expect(contents.tracks.map(\.places.count) == [limit, 0])
        #expect(contents.tracks[0].places.last?.name == "A \(limit - 1)")
        #expect(contents.leftOut == .init(pastPlaceLimit: 5))
    }

    /// The split keeps the items' own order within each route, and cuts by
    /// the order they were given in, not by route.
    @Test("the capped split cuts in the order the items were given")
    func cappedSplitCutsInGivenOrder() {
        let routeA = [RouteCoordinate(latitude: 47, longitude: 12), RouteCoordinate(latitude: 47.01, longitude: 12)]
        let routeB = [RouteCoordinate(latitude: 47.05, longitude: 12), RouteCoordinate(latitude: 47.06, longitude: 12)]
        let onB = { (index: Int) in CLLocationCoordinate2D(latitude: 47.05 + 0.001 * Double(index), longitude: 12) }
        let onA = { (index: Int) in CLLocationCoordinate2D(latitude: 47 + 0.001 * Double(index), longitude: 12) }
        let nowhere = CLLocationCoordinate2D(latitude: 46, longitude: 12)
        let items = [onB(0), nowhere, onA(0), onB(1), onA(1)]

        let split = GPXTrackSplit.assign(items, at: { $0 }, to: [routeA, routeB], keepingAtMost: 3)

        #expect(split.assigned.map { $0.map(\.latitude) } == [[onA(0).latitude], [onB(0).latitude, onB(1).latitude]])
        #expect(split.pastLimit == 1)
    }
}
