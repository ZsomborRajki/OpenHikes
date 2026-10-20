//
//  GPXImportPlaceholderTests.swift
//  OpenHikesTests
//
//  A "no fix" point a logger writes as (0, 0), or any other lone point far
//  from a track that is otherwise continuous. Either one made a 7 km hike
//  thousands of kilometres long.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("GPX import placeholder fixes")
struct GPXImportPlaceholderTests {
    private func gpxFile(points: [(Double, Double)]) throws -> URL {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="OpenHikesTests" xmlns="http://www.topografix.com/GPX/1/1">
            <trk><trkseg>
        """
        for (latitude, longitude) in points {
            xml += "<trkpt lat=\"\(latitude)\" lon=\"\(longitude)\"></trkpt>"
        }
        xml += "</trkseg></trk></gpx>"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("placeholder-\(UUID().uuidString)")
            .appendingPathExtension("gpx")
        try xml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 120 points walking north from the Königssee, about 7 km.
    private static let walk: [(Double, Double)] = (0..<120).map { (47.55 + Double($0) * 0.0005, 12.86) }

    @Test("a (0, 0) fix in the middle is dropped and the walk keeps its length")
    func dropsOrigin() throws {
        var points = Self.walk
        points[60] = (0, 0)
        let track = try GPXImport.load(from: try gpxFile(points: points))

        #expect(track.points.count == 119)
        #expect(track.distanceMeters < 8000)
    }

    @Test("a lone far-off point between two close ones is dropped")
    func dropsIsolatedOutlier() throws {
        var points = Self.walk
        points[60] = (10, 40)
        let track = try GPXImport.load(from: try gpxFile(points: points))

        #expect(track.points.count == 119)
        #expect(track.distanceMeters < 8000)
    }

    @Test("a genuine long leg between far-apart points is untouched")
    func keepsRealLeg() throws {
        let points = Self.walk.prefix(10) + [(48.5, 13.5), (48.5, 13.5005)]
        let track = try GPXImport.load(from: try gpxFile(points: Array(points)))

        #expect(track.points.count == 12)
    }
}
