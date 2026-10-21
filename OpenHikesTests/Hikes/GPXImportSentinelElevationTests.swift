//
//  GPXImportSentinelElevationTests.swift
//  OpenHikesTests
//
//  A height that is a number but not a height: the `-9999` and `-32768` void
//  markers of elevation models, the `0` a logger writes with no altitude fix.
//  One of them turned a 119 m climb into 11 177 m of gain.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("GPX import sentinel elevations")
struct GPXImportSentinelElevationTests {
    private func gpxFile(heights: [Double], pointElement: String = "trkpt") throws -> URL {
        let (opening, closing) = switch pointElement {
        case "trkpt": ("<trk><trkseg>", "</trkseg></trk>")
        case "rtept": ("<rte>", "</rte>")
        default: ("", "")
        }
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="OpenHikesTests" xmlns="http://www.topografix.com/GPX/1/1">
            \(opening)
        """
        for (step, height) in heights.enumerated() {
            let latitude = 47.55 + Double(step) * 0.0005
            xml += "<\(pointElement) lat=\"\(latitude)\" lon=\"12.86\"><ele>\(height)</ele></\(pointElement)>"
        }
        xml += "\(closing)</gpx>"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sentinel-\(UUID().uuidString)")
            .appendingPathExtension("gpx")
        try xml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 120 points about 55 m apart, climbing a metre each: 119 m of gain.
    private static let climb = (0..<120).map { 1000 + Double($0) }

    private func statistics(of track: GPXImport.Track) -> HikeRouteStatistics {
        HikeRouteStatistics(distanceMeters: track.distanceMeters, route: track.route)
    }

    /// The issue's table: every row read 119 m of gain once the one point is
    /// emptied, against 11 177, 33 946, 1 178 and 99 057 m before.
    @Test(
        "one placeholder height leaves the climb as it was, in every GPX format",
        arguments: [-9999, -32_768, 0, 99_999], ["trkpt", "rtept", "wpt"]
    )
    func onePlaceholderHeightIsEmptied(placeholder: Double, pointElement: String) throws {
        var heights = Self.climb
        heights[60] = placeholder
        let track = try GPXImport.load(from: try gpxFile(heights: heights, pointElement: pointElement))
        let stats = statistics(of: track)

        #expect(track.points.count == 120)
        #expect(track.points[60].elevation == nil)
        #expect(track.route[60].elevation == nil)
        #expect(stats.elevationGain?.value == 119)
        #expect(stats.elevationLoss?.value == 0)
        #expect(stats.minElevation?.value == 1000)
        #expect(stats.maxElevation?.value == 1119)
    }

    @Test("a void run longer than one point keeps the heights around it")
    func voidRunKeepsItsNeighbours() throws {
        var heights = Self.climb
        for index in 50..<56 { heights[index] = -9999 }
        let track = try GPXImport.load(from: try gpxFile(heights: heights))
        let stats = statistics(of: track)

        #expect(track.points[49].elevation == 1049)
        #expect(track.points[56].elevation == 1056)
        #expect(track.points[50..<56].allSatisfy { $0.elevation == nil })
        #expect(stats.elevationGain?.value == 119)
        #expect(stats.minElevation?.value == 1000)
    }

    @Test("a winding climb with missing heights keeps the real summit")
    func windingClimbKeepsItsSummit() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="OpenHikesTests" xmlns="http://www.topografix.com/GPX/1/1">
            <trk><trkseg>
                <trkpt lat="47.55" lon="12.86"><ele>1000</ele></trkpt>
                <trkpt lat="47.56" lon="12.86"/>
                <trkpt lat="47.5505" lon="12.86"><ele>1500</ele></trkpt>
                <trkpt lat="47.54" lon="12.86"/>
                <trkpt lat="47.551" lon="12.86"><ele>1000</ele></trkpt>
            </trkseg></trk>
        </gpx>
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("summit-\(UUID().uuidString).gpx")
        try xml.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let track = try GPXImport.load(from: url)
        let stats = statistics(of: track)

        #expect(track.points.map(\.elevation) == [1000, nil, 1500, nil, 1000])
        #expect(stats.elevationGain?.value == 500)
        #expect(stats.elevationLoss?.value == 500)
        #expect(stats.maxElevation?.value == 1500)
    }

    @Test("a photograph's placeholder height is emptied with the track's")
    func photographHeightIsChecked() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="OpenHikesTests" xmlns="http://www.topografix.com/GPX/1/1">
            <wpt lat="47.55" lon="12.86"><ele>-32768</ele><time>2026-07-01T09:00:00Z</time><sym>Photo</sym></wpt>
            <trk><trkseg>
                <trkpt lat="47.55" lon="12.86"><ele>1000</ele></trkpt>
                <trkpt lat="47.56" lon="12.86"><ele>1010</ele></trkpt>
            </trkseg></trk>
        </gpx>
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sentinel-\(UUID().uuidString)")
            .appendingPathExtension("gpx")
        try xml.write(to: url, atomically: true, encoding: .utf8)
        let track = try GPXImport.load(from: url)

        #expect(track.photographs.count == 1)
        #expect(track.photographs.first?.elevation == nil)
    }
}
