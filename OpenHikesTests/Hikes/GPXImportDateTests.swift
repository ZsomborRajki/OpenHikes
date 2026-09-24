//
//  GPXImportDateTests.swift
//  OpenHikesTests
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("GPX import dates")
struct GPXImportDateTests {
    private static let timestampedTrack = """
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx version="1.1" creator="OpenHikesTests" xmlns="http://www.topografix.com/GPX/1/1">
        <metadata><time>2026-06-01T10:00:00.250+02:00</time></metadata>
        <trk><trkseg>
        <trkpt lat="47.6300" lon="12.8600"><time>2026-06-01T10:05:00.125+02:00</time></trkpt>
        <trkpt lat="47.6310" lon="12.8600"><time>2026-06-01T10:06:00.875+02:00</time></trkpt>
        </trkseg></trk>
    </gpx>
    """

    /// The same track written the way a good many real exporters write it:
    /// an ISO-looking `<time>` with no `Z` and no offset. Not conformant —
    /// GPX 1.1 says UTC with a designator — but common enough that refusing
    /// it costs the hike its date, its duration and both of its speeds.
    private static let designatorlessTrack = """
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx version="1.1" creator="OpenHikesTests" xmlns="http://www.topografix.com/GPX/1/1">
        <metadata><time>2020-01-01T09:30:00</time></metadata>
        <trk><trkseg>
        <trkpt lat="47.6300" lon="12.8600"><time>2020-01-01T10:00:00</time></trkpt>
        <trkpt lat="47.6310" lon="12.8600"><time>2020-01-01T10:30:00.500</time></trkpt>
        </trkseg></trk>
    </gpx>
    """

    /// What the device would call the given wall-clock instant, built through
    /// the calendar rather than through the importer's own format style.
    private static func localInstant(
        hour: Int,
        minute: Int,
        second: Int = 0
    ) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return try #require(
            calendar.date(
                from: DateComponents(
                    year: 2020,
                    month: 1,
                    day: 1,
                    hour: hour,
                    minute: minute,
                    second: second
                )
            )
        )
    }

    private func gpxFile() throws -> URL {
        try write(Self.timestampedTrack)
    }

    private func write(_ xml: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("date-\(UUID().uuidString)")
            .appendingPathExtension("gpx")
        try xml.write(
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

    /// The regression this exists for: before the local fallback, every one of
    /// these returned `nil` and the whole track came back untimed — no date on
    /// the row, no duration, no speeds — over a missing letter.
    @Test("a timestamp with no zone designator is read as the device's own time")
    func designatorlessTimestampsAreLocal() throws {
        let track = try GPXImport.load(from: try write(Self.designatorlessTrack))

        #expect(track.startTime == (try Self.localInstant(hour: 9, minute: 30)))
        #expect(track.points[0].time == (try Self.localInstant(hour: 10, minute: 0)))
        #expect(
            track.points[1].time
                == (try Self.localInstant(hour: 10, minute: 30))
                    .addingTimeInterval(0.5)
        )
    }

    /// The fallback is a fallback. A string that does carry a designator has
    /// to keep being read by it, because the lenient grammar accepts one too
    /// and would silently drop the offset — which is the same bug as the one
    /// above, pointing the other way.
    @Test("an explicit designator still wins over the local fallback")
    func explicitDesignatorIsNotReadAsLocal() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="OpenHikesTests" xmlns="http://www.topografix.com/GPX/1/1">
            <trk><trkseg>
            <trkpt lat="47.6300" lon="12.8600"><time>2020-01-01T10:00:00Z</time></trkpt>
            <trkpt lat="47.6310" lon="12.8600"><time>2020-01-01T13:00:00+03:00</time></trkpt>
            </trkseg></trk>
        </gpx>
        """
        let track = try GPXImport.load(from: try write(xml))
        let utc = try Date.ISO8601FormatStyle().parse("2020-01-01T10:00:00Z")

        #expect(track.points[0].time == utc)
        #expect(track.points[1].time == utc)
    }

    /// Leniency has an edge. A `<time>` that isn't a full date and time is
    /// still nothing, rather than a date invented out of whichever fields it
    /// happened to carry.
    @Test("a partial or nonsense timestamp is still no timestamp", arguments: [
        "2020-01-01", "10:00:00", "2020-01-01T10:00", "20200101T100000", "sometime tuesday",
    ])
    func unparsableTimestampsStayAbsent(value: String) throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="OpenHikesTests" xmlns="http://www.topografix.com/GPX/1/1">
            <trk><trkseg>
            <trkpt lat="47.6300" lon="12.8600"><time>\(value)</time></trkpt>
            <trkpt lat="47.6310" lon="12.8600"/>
            </trkseg></trk>
        </gpx>
        """
        let track = try GPXImport.load(from: try write(xml))

        #expect(track.points[0].time == nil)
        #expect(track.startTime == nil)
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
