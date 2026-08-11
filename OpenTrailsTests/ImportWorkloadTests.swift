//
//  ImportWorkloadTests.swift
//  OpenTrailsTests
//
//  `GPXImportTests` covers what the parser accepts and refuses. This covers
//  what importing costs, because `ContentView.importGPX(from:)` is
//  `@MainActor` and does every part of it synchronously before returning:
//  security-scoped access, an XML parse of the whole document, an O(n)
//  distance sum with two `CLLocation` allocations per point, a full re-map of
//  the points into `RouteCoordinate`, and a SwiftData insert.
//
//  Nothing about that is bounded by anything the app controls — it's bounded
//  by the size of the file the user picked. A GPX is not a small format: a
//  5-hour recording at 1 Hz is 18,000 track points, and Komoot/Strava exports
//  of multi-day routes are larger still.
//

import CoreLocation
import Foundation
import SwiftData
import Testing
@testable import OpenTrails

@MainActor
@Suite("Import workload")
struct ImportWorkloadTests {
    /// Writes a real GPX file with `pointCount` track points, so the parser
    /// does the work it would do on a picked file rather than on a fixture
    /// that was never serialized.
    private func writeGPX(pointCount: Int) throws -> URL {
        var xml = #"<?xml version="1.0" encoding="UTF-8"?>"#
        xml += #"<gpx version="1.1" creator="OpenTrailsTests"><trk><name>Long walk</name><trkseg>"#
        xml.reserveCapacity(pointCount * 80)
        for step in 0..<pointCount {
            let t = Double(step)
            xml += "<trkpt lat=\"\(47.63 + t * 1e-5)\" lon=\"\(12.86 + t * 5e-6)\">"
            xml += "<ele>\(600 + t * 0.01)</ele></trkpt>"
        }
        xml += "</trkseg></trk></gpx>"

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-workload-\(UUID().uuidString).gpx")
        try xml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func milliseconds(_ work: () throws -> Void) rethrows -> Double {
        let start = ContinuousClock.now
        try work()
        return Double((ContinuousClock.now - start).components.attoseconds) / 1e15
    }

    /// The headline. Measured on the Simulator, a 18,000-point file:
    ///
    ///     GPXImport.load ..........  60 ms
    ///     Track.distanceMeters ....   5 ms
    ///
    /// Both on the main thread, both while the document picker is dismissing,
    /// which is when SwiftUI is already busy. 60 ms is four dropped frames at
    /// 60 Hz; iOS's own watchdog starts caring an order of magnitude above
    /// that, and a 100,000-point multi-day export is within an order of
    /// magnitude of it.
    ///
    /// The fix is structural rather than clever: `GPXImport` is already
    /// `nonisolated` and takes a `URL`, so the parse can happen in a detached
    /// task and only the `Hike` construction and insert need the main actor.
    @Test("importing a long recording doesn't block the main thread")
    func longImportStaysOffTheMainThread() throws {
        let url = try writeGPX(pointCount: 18_000)
        defer { try? FileManager.default.removeItem(at: url) }

        var track: GPXImport.Track?
        let parseMs = try milliseconds { track = try GPXImport.load(from: url) }
        let parsed = try #require(track)
        #expect(parsed.points.count == 18_000, "precondition: the whole file was read")

        withKnownIssue("ContentView.importGPX parses on the main actor, synchronously") {
            #expect(parseMs < 16, "one frame; measured ~60 ms at 18,000 points")
        }
    }

    /// `Track.distanceMeters` is a computed property, not a stored one — every
    /// access re-walks the route and allocates two `CLLocation`s per point.
    /// `ContentView.importGPX` reads it once today, which is the only reason
    /// this isn't already a multiple of its own cost; nothing in the type says
    /// so, and `coordinates` next to it has exactly the same shape.
    @Test("the imported track's derived length is cheap to ask for twice")
    func derivedLengthIsNotRecomputedPerAccess() throws {
        let url = try writeGPX(pointCount: 18_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let track = try GPXImport.load(from: url)

        let first = milliseconds { _ = track.distanceMeters }
        let second = milliseconds { _ = track.distanceMeters }

        withKnownIssue("distanceMeters is computed, so each read is a fresh O(n) pass") {
            #expect(second < first / 4, "a second read of the same value should be free")
        }
    }

    /// The route survives the trip through the importer's own remapping —
    /// the assertion the workload tests above are only worth having alongside.
    @Test("a long import still produces a usable route")
    func longImportIsCorrect() throws {
        let url = try writeGPX(pointCount: 5_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let track = try GPXImport.load(from: url)

        let route = track.points.map {
            RouteCoordinate(
                latitude: $0.coordinate.latitude,
                longitude: $0.coordinate.longitude,
                elevation: $0.elevation,
                timestamp: $0.time
            )
        }
        let profile = RouteProfile(route: route)
        #expect(profile.coordinates.count == 5_000)
        #expect(try #require(profile.distances.last) > 0)
        #expect(profile.samples.count <= RouteProfile.plottedSampleBudget)
        #expect(abs(try #require(profile.distances.last) - track.distanceMeters) < 1)
    }
}
