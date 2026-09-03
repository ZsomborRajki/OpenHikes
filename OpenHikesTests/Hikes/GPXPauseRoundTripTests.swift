//
//  GPXPauseRoundTripTests.swift
//  OpenHikesTests
//
//  The `<trkseg>` boundary, exported and read back.
//
//  A pause is the one fact about a walk that GPX can carry and a flat list of
//  points cannot, so it is the one part of the round trip that has to be
//  argued in both directions: written as a segment break on the way out, read
//  as a pause on the way back in. Its own suite because ``GPXExportTests`` is
//  at the size limit and because the two halves belong together.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("GPX pause round trip")
struct GPXPauseRoundTripTests {
    private static let date = Date(timeIntervalSince1970: 1_780_000_000)

    private func track(route: [RouteCoordinate]) -> GPXExport.Track {
        GPXExport.Track(
            name: "Thumsee Loop",
            trackDescription: nil,
            author: nil,
            keywords: nil,
            date: Self.date,
            route: route
        )
    }

    /// Written to a file and read back the way a picked document is, rather
    /// than compared against the writer's own strings: ``GPXImport`` is a real
    /// reader written against other people's files, so agreeing with it is
    /// evidence the pause travels.
    private func reimported(_ track: GPXExport.Track) throws -> GPXImport.Track {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-\(UUID().uuidString)")
            .appendingPathExtension("gpx")
        try GPXExport.data(for: track).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        return try GPXImport.load(from: url)
    }

    /// Asserted through the importer, and against a count of the segments in
    /// the text. The two readings together are what say the pause travelled as
    /// a *boundary* rather than as a lucky coincidence of point order.
    @Test("a pause is written as a segment break and comes back as a pause")
    func roundTripsPauses() throws {
        let route: [RouteCoordinate] = [
            RouteCoordinate(latitude: 47.63, longitude: 12.86, timestamp: Self.date),
            RouteCoordinate(
                latitude: 47.631,
                longitude: 12.86,
                timestamp: Self.date.addingTimeInterval(60)
            ),
            RouteCoordinate(
                latitude: 47.64,
                longitude: 12.86,
                timestamp: Self.date.addingTimeInterval(3660),
                boundary: .paused
            ),
            RouteCoordinate(
                latitude: 47.641,
                longitude: 12.86,
                timestamp: Self.date.addingTimeInterval(3720)
            ),
        ]
        let exported = track(route: route)

        let xml = GPXExport.xml(for: exported)
        #expect(xml.components(separatedBy: "<trkseg>").count - 1 == 2)
        #expect(xml.components(separatedBy: "</trkseg>").count - 1 == 2)

        let imported = try reimported(exported)
        #expect(imported.route.count == route.count)
        #expect(imported.route.map(\.isPauseBoundary) == [false, false, true, false])
    }

    /// The single-segment document is what an unpaused walk has always
    /// written, and what most readers expect to find.
    @Test("a walk with no pause is still written as one segment")
    func unpausedRouteWritesOneSegment() {
        let xml = GPXExport.xml(for: track(route: Fixture.ridgeRoute))

        #expect(xml.components(separatedBy: "<trkseg>").count - 1 == 1)
    }
}
