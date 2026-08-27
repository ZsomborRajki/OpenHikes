//
//  GPXImportLimitTests.swift
//  OpenHikesTests
//
//  The bounds that exist because nobody looked at the file. A GPX the walker
//  picked from Files at least passed under their eyes; one delivered through
//  `Documents/Inbox` — AirDrop, a mail attachment, a share extension — was
//  chosen by the sender and is read unattended, so nothing upstream of the
//  parser bounds what it costs.
//
//  Two things are checked here and they pull against each other: that an
//  absurd file is refused with something the walker can act on, and that the
//  shipping bounds are nowhere near a real day's walk. The second matters
//  more — a ceiling that turns away a genuine hike leaves its owner with no
//  way in at all.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("GPX import limits")
struct GPXImportLimitTests {
    private static let shipping = GPXImport.Limits.standard

    private func gpxFile(_ xml: String, name: String = "limits") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
            .appendingPathExtension("gpx")
        try xml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A track with `pointCount` points and nothing else in it — no
    /// whitespace, no elevations, no times — which is the shape that reaches
    /// the point ceiling long before the byte one.
    private static func terseTrack(pointCount: Int) -> String {
        var xml = #"<?xml version="1.0" encoding="UTF-8"?>"#
        xml += #"<gpx version="1.1" creator="OpenHikesTests"><trk><trkseg>"#
        for step in 0..<pointCount {
            xml += "<trkpt lat=\"\(47.63 + Double(step) * 1e-4)\" lon=\"12.86\"/>"
        }
        xml += "</trkseg></trk></gpx>"
        return xml
    }

    /// The shipping limits with one bound moved, so a test can reach the
    /// ceiling it is about with a fixture small enough to read.
    private static func limits(bytes: Int? = nil, points: Int? = nil) -> GPXImport.Limits {
        GPXImport.Limits(
            maximumFileSizeBytes: bytes ?? shipping.maximumFileSizeBytes,
            maximumPointCount: points ?? shipping.maximumPointCount
        )
    }

    @Test("a file past the byte ceiling is refused before it is read")
    func refusesAnOversizedFile() throws {
        let url = try gpxFile(Self.terseTrack(pointCount: 4))
        let size = try #require(
            try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )

        #expect(throws: GPXImport.ImportFailure.tooLarge) {
            try GPXImport.load(from: url, limits: Self.limits(bytes: size - 1))
        }
        // Exactly at the ceiling is inside it, or the boundary is off by a
        // byte in the direction that refuses a legitimate file.
        let admitted = try GPXImport.load(from: url, limits: Self.limits(bytes: size))
        #expect(admitted.points.count == 4)
    }

    /// Bytes alone can't bound the parse: a file with no whitespace, no
    /// elevations and no times spends everything it has on points, and it is
    /// the arrays those land in that grow.
    @Test("a file past the point ceiling is refused mid-parse")
    func refusesTooManyPoints() throws {
        let url = try gpxFile(Self.terseTrack(pointCount: 5))

        #expect(throws: GPXImport.ImportFailure.tooLarge) {
            try GPXImport.load(from: url, limits: Self.limits(points: 4))
        }
        let admitted = try GPXImport.load(from: url, limits: Self.limits(points: 5))
        #expect(admitted.points.count == 5)
    }

    /// The ceiling counts every flavour together, since memory doesn't care
    /// which array a point landed in and only one of them becomes the track.
    @Test("waypoints and route points count against the same ceiling")
    func everyFlavourCountsTowardsTheCeiling() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="OpenHikesTests" xmlns="http://www.topografix.com/GPX/1/1">
            <wpt lat="47.6300" lon="12.8600"/>
            <rte><rtept lat="47.6310" lon="12.8600"/></rte>
            <trk><trkseg>
            <trkpt lat="47.6320" lon="12.8600"/>
            <trkpt lat="47.6330" lon="12.8600"/>
            </trkseg></trk>
        </gpx>
        """
        let url = try gpxFile(xml)

        #expect(throws: GPXImport.ImportFailure.tooLarge) {
            try GPXImport.load(from: url, limits: Self.limits(points: 3))
        }
        let admitted = try GPXImport.load(from: url, limits: Self.limits(points: 4))
        #expect(admitted.points.count == 2)
    }

    /// An abandoned parse and a malformed document both come back `false`
    /// from `XMLParser`, and the two have to reach the walker as different
    /// sentences — "split the file" and "this isn't a GPX" are different
    /// instructions.
    @Test("a document that won't parse is unreadable rather than too large")
    func unparsableIsNotReportedAsTooLarge() throws {
        let url = try gpxFile("this is not a gpx file")

        #expect(throws: GPXImport.ImportFailure.unreadable) {
            try GPXImport.load(from: url, limits: Self.limits(points: 1))
        }
    }

    /// A day out recorded at 1 Hz is around 20,000 track points and a couple
    /// of megabytes. The shipping bounds have to swallow that without
    /// noticing, or the cap has failed in the direction that costs somebody
    /// their hike.
    @Test("the shipping limits leave a full day's recording alone")
    func shippingLimitsAdmitADaysRecording() throws {
        let pointCount = 20_000
        var xml = #"<?xml version="1.0" encoding="UTF-8"?>"#
        xml += #"<gpx version="1.1" creator="OpenHikesTests"><trk><trkseg>"#
        xml.reserveCapacity(pointCount * 128)
        for step in 0..<pointCount {
            let offset = Double(step)
            xml += "<trkpt lat=\"\(47.63 + offset * 1e-5)\" lon=\"\(12.86 + offset * 5e-6)\">"
            xml += "<ele>\(600 + offset * 0.01)</ele>"
            xml += "<time>2026-06-01T08:00:00Z</time></trkpt>"
        }
        xml += "</trkseg></trk></gpx>"
        let url = try gpxFile(xml, name: "a-days-walk")
        defer { try? FileManager.default.removeItem(at: url) }
        let size = try #require(
            try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )

        #expect(try GPXImport.load(from: url).points.count == pointCount)
        #expect(
            size * 4 < Self.shipping.maximumFileSizeBytes,
            "a day's walk should not be within sight of the byte ceiling"
        )
    }
}
