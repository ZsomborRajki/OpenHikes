//
//  GPXImportDateTests.swift
//  OpenTrailsTests
//

import Foundation
@testable import OpenTrails
import Testing

@Suite("GPX import dates")
struct GPXImportDateTests {
    private static let timestampedTrack = """
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx version="1.1" creator="OpenTrailsTests" xmlns="http://www.topografix.com/GPX/1/1">
        <metadata><time>2026-06-01T10:00:00.250+02:00</time></metadata>
        <trk><trkseg>
        <trkpt lat="47.6300" lon="12.8600"><time>2026-06-01T10:05:00.125+02:00</time></trkpt>
        <trkpt lat="47.6310" lon="12.8600"><time>2026-06-01T10:06:00.875+02:00</time></trkpt>
        </trkseg></trk>
    </gpx>
    """

    private func gpxFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("date-\(UUID().uuidString)")
            .appendingPathExtension("gpx")
        try Self.timestampedTrack.write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
        return url
    }

    @Test("timestamps preserve explicit offsets and fractional seconds")
    func timestampOffsetsAndFractions() throws {
        let track = try GPXImport.load(from: try gpxFile())
        let strategy = Date.ISO8601FormatStyle(
            includingFractionalSeconds: true
        )

        #expect(
            track.startTime
                == (try strategy.parse("2026-06-01T08:00:00.250Z"))
        )
        #expect(
            track.points[0].time
                == (try strategy.parse("2026-06-01T08:05:00.125Z"))
        )
        #expect(
            track.points[1].time
                == (try strategy.parse("2026-06-01T08:06:00.875Z"))
        )
    }

    @Test("parallel imports keep every timestamp")
    func parallelImportsPreserveTimestamps() async throws {
        let url = try gpxFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let tracks = try await withThrowingTaskGroup(
            of: GPXImport.Track.self,
            returning: [GPXImport.Track].self
        ) { group in
            for _ in 0..<24 {
                group.addTask {
                    try GPXImport.load(from: url)
                }
            }
            var results: [GPXImport.Track] = []
            for try await track in group {
                results.append(track)
            }
            return results
        }

        #expect(tracks.count == 24)
        #expect(
            tracks.allSatisfy { track in
                track.startTime != nil
                    && track.points.allSatisfy { $0.time != nil }
            }
        )
    }
}
