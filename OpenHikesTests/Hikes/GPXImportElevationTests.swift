//
//  GPXImportElevationTests.swift
//  OpenHikesTests
//
//  What happens to a `<ele>` that isn't a number.
//
//  A height is the one field in a GPX point that reaches arithmetic without
//  passing through a projection first — a coordinate is checked against Web
//  Mercator's range on the way in, and an elevation used to be taken at its
//  word. `Double.init` accepts "nan", "inf" and "1e400" from ordinary text, so
//  a single such point put the whole hike detail screen a tap away from a
//  precondition failure.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("GPX import elevations")
struct GPXImportElevationTests {
    private func gpxFile(_ xml: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ele-\(UUID().uuidString)")
            .appendingPathExtension("gpx")
        try xml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func track(heights: [String]) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="OpenHikesTests" xmlns="http://www.topografix.com/GPX/1/1">
            <trk><trkseg>
        """
        for (step, height) in heights.enumerated() {
            let latitude = 47.63 + Double(step) * 0.001
            xml += "<trkpt lat=\"\(latitude)\" lon=\"12.86\"><ele>\(height)</ele></trkpt>"
        }
        xml += "</trkseg></trk></gpx>"
        return xml
    }

    /// The regression this suite exists for. NaN loses every comparison, so a
    /// leading one survives both `min()` and `max()` — `RouteProfile`'s
    /// elevation bounds became `nan...nan`, which is a `ClosedRange`
    /// precondition failure the moment the chart asks for its y-domain rather
    /// than an axis that merely looks wrong. An infinity took the quieter
    /// route and rendered "∞ m" as the hike's climb.
    @Test("a height that isn't a number is dropped while its point survives", arguments: [
        "nan", "NaN", "-nan", "inf", "infinity", "1e400", "-1e400",
    ])
    func dropsNonFiniteElevation(height: String) throws {
        let track = try GPXImport.load(
            from: try gpxFile(Self.track(heights: [height, "620.0", "640.0"]))
        )

        // The coordinate was never in question, so the route keeps its shape.
        #expect(track.points.count == 3)
        #expect(track.points.map(\.elevation) == [nil, 620, 640])
        #expect(track.route.map(\.elevation) == [nil, 620, 640])

        let range = try #require(RouteProfile(route: track.route).elevationRange)
        #expect(range == 620...640)
    }

    /// A point whose height was refused is still a point. Dropping the whole
    /// point instead would tear a hole in geometry that was perfectly fine and
    /// silently shorten the route, which is a worse answer than a gap in the
    /// elevation profile.
    @Test("the refused height costs the route neither its length nor its shape")
    func keepsTheGeometryOfAPointWithABadHeight() throws {
        let good = try GPXImport.load(
            from: try gpxFile(Self.track(heights: ["600.0", "620.0", "640.0"]))
        )
        let bad = try GPXImport.load(
            from: try gpxFile(Self.track(heights: ["nan", "620.0", "640.0"]))
        )

        #expect(bad.route.map(\.latitude) == good.route.map(\.latitude))
        #expect(bad.distanceMeters == good.distanceMeters)
    }

    /// Every total the stats grid draws is derived from these heights, and a
    /// non-finite one reaching them doesn't corrupt its own reading — it makes
    /// the sum, the gain and the loss all NaN, and `HikeFormat` renders that
    /// as text on a tile.
    @Test("a track of nothing but bad heights reports no elevation at all")
    func aTrackWithNoUsableHeightsHasNoProfile() throws {
        let track = try GPXImport.load(
            from: try gpxFile(Self.track(heights: ["nan", "inf", "-inf"]))
        )

        #expect(track.route.allSatisfy { $0.elevation == nil })
        #expect(RouteProfile(route: track.route).elevationRange == nil)
    }
}
