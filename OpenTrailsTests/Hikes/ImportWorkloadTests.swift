//
//  ImportWorkloadTests.swift
//  OpenTrailsTests
//
//  `GPXImportTests` covers what the parser accepts and refuses. This covers
//  what importing costs, because the parse, distance calculation, and route
//  preparation are all proportional to the picked file's point count.
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

@Suite("Import workload", .serialized)
struct ImportWorkloadTests {
    private struct ObservedParse: Sendable {
        let track: GPXImport.Track
        let ranOnMainThread: Bool
    }

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
    func longImportStaysOffTheMainThread() async throws {
        let url = try writeGPX(pointCount: 18_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let observed = try await GPXImport.runOffMain { () throws(GPXImport.ImportFailure) -> ObservedParse in
            ObservedParse(
                track: try GPXImport.load(from: url),
                ranOnMainThread: Thread.isMainThread
            )
        }

        #expect(observed.track.points.count == 18_000, "precondition: the whole file was read")
        #expect(!observed.ranOnMainThread, "the picked file must be parsed on the detached import executor")
    }

    /// Derived route data is prepared once during parsing. Repeated reads must
    /// not re-walk an arbitrarily large imported recording.
    @Test("the imported track's derived length is cheap to ask for twice")
    func derivedLengthIsNotRecomputedPerAccess() async throws {
        let url = try writeGPX(pointCount: 18_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let track = try await GPXImport.loadOffMain(from: url)

        var checksum = 0.0
        let repeatedReadMs = milliseconds {
            for _ in 0..<100 {
                checksum += track.distanceMeters
            }
        }
        #expect(checksum > 0)
        #expect(repeatedReadMs < 5, "cached distance reads should be constant-time")
    }

    /// The route survives the trip through the importer's own remapping —
    /// the assertion the workload tests above are only worth having alongside.
    @Test("a long import still produces a usable route")
    func longImportIsCorrect() async throws {
        let url = try writeGPX(pointCount: 5_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let track = try await GPXImport.loadOffMain(from: url)

        let profile = RouteProfile(route: track.route)
        #expect(profile.coordinates.count == 5_000)
        #expect(try #require(profile.distances.last) > 0)
        #expect(profile.samples.count <= RouteProfile.plottedSampleBudget)
        #expect(abs(try #require(profile.distances.last) - track.distanceMeters) < 1)
    }
}
