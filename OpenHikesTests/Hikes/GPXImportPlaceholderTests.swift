//
//  GPXImportPlaceholderTests.swift
//  OpenHikesTests
//
//  A "no fix" point a logger writes as (0, 0), or any other lone point far
//  from a track that is otherwise continuous. Either one made a 7 km hike
//  thousands of kilometres long.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

@Suite("GPX import placeholder fixes")
struct GPXImportPlaceholderTests {
    private func gpxFile(points: [(Double, Double)], pointElement: String = "trkpt") throws -> URL {
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
        for (latitude, longitude) in points {
            xml += "<\(pointElement) lat=\"\(latitude)\" lon=\"\(longitude)\"/>"
        }
        xml += "\(closing)</gpx>"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("placeholder-\(UUID().uuidString)")
            .appendingPathExtension("gpx")
        try xml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 120 points walking north from the Königssee, about 7 km.
    private static let walk: [(Double, Double)] = (0..<120).map { (47.55 + Double($0) * 0.0005, 12.86) }

    @Test("a (0, 0) fix is dropped in every GPX format", arguments: ["trkpt", "rtept", "wpt"])
    func dropsOrigin(pointElement: String) throws {
        var points = Self.walk
        points[60] = (0, 0)
        let track = try GPXImport.load(from: try gpxFile(points: points, pointElement: pointElement))

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

    /// The first and last fixes have one neighbour each, so the rule cannot
    /// judge them, and two bad points in a row vouch for each other: all of
    /// these are kept, in order.
    @Test("far-off points at either end, or two in a row, are kept")
    func keepsEndsAndPairs() throws {
        var points = Self.walk
        points[0] = (10, 40)
        points[119] = (10, 40)
        points[60] = (10, 40)
        points[61] = (10, 40.0005)
        let track = try GPXImport.load(from: try gpxFile(points: points))

        #expect(track.points.count == 120)
        #expect(track.points.first?.coordinate.latitude == 10)
        #expect(track.points.last?.coordinate.latitude == 10)
        #expect(track.points[60].coordinate.longitude == 40)
    }

    @Test("a genuine long leg between far-apart points is untouched")
    func keepsRealLeg() throws {
        let points = Self.walk.prefix(10) + [(48.5, 13.5), (48.5, 13.5005)]
        let track = try GPXImport.load(from: try gpxFile(points: Array(points)))

        #expect(track.points.count == 12)
    }

    @Test("a sparse planned out-and-back keeps its turnaround", arguments: ["rtept", "wpt"])
    func keepsPlannedTurnaround(pointElement: String) throws {
        let points = [(47.55, 12.86), (48.55, 12.86), (47.55, 12.86)]
        let track = try GPXImport.load(from: try gpxFile(points: points, pointElement: pointElement))

        #expect(track.points.count == 3)
        #expect(track.distanceMeters.isApproximatelyEqual(to: 222_390, absoluteTolerance: 10))
    }
}
