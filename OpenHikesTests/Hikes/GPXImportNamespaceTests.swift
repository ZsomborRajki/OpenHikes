//
//  GPXImportNamespaceTests.swift
//  OpenHikesTests
//
//  An exporter's extensions are its own namespace, and may reuse GPX's own
//  element names: a vendor `<…:trkpt>` inside `<extensions>` is the vendor's
//  data, not a point of the track. The import reads only the elements in
//  the file's own namespace, its root's, and nothing inside an element of
//  another, so GPX 1.0, 1.1 and a file that names no namespace all read as
//  they did.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("GPX import namespaces")
struct GPXImportNamespaceTests {
    private static let vendor = #"xmlns:vendor="https://example.com/vendor/1""#
    /// A vendor's point between the track's two, so nothing but its
    /// namespace keeps it off the line: one far off is dropped as a logger's
    /// teleport whatever its namespace.
    private static let vendorPoint = #"lat="47.6305" lon="12.8600""#

    private func load(_ xml: String) throws -> GPXImport.Track {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("namespace-\(UUID().uuidString)")
            .appendingPathExtension("gpx")
        try xml.write(to: url, atomically: true, encoding: .utf8)
        return try GPXImport.load(from: url)
    }

    /// The latitudes of `track`'s points, to the ten-thousandth of a degree.
    private func latitudes(_ track: GPXImport.Track) -> [Double] {
        track.points.map { ($0.coordinate.latitude * 1e4).rounded() }
    }

    @Test("a vendor extension's own trkpt is not a point of the track")
    func aVendorTrackPointIsNotAPoint() throws {
        let track = try load("""
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1" \(Self.vendor)>
            <trk><trkseg>
            <trkpt lat="47.6300" lon="12.8600"/>
            <trkpt lat="47.6310" lon="12.8600"/>
            <extensions><vendor:trkpt lat="48.2" lon="11.2"/></extensions>
            </trkseg></trk>
        </gpx>
        """)

        #expect(latitudes(track) == [476_300, 476_310])
    }

    /// GPX's own names inside a vendor's element are the vendor's too,
    /// whatever namespace they inherit.
    @Test("nothing inside a vendor's element is read, a GPX name included")
    func insideAVendorElement() throws {
        let track = try load("""
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1" \(Self.vendor)>
            <trk><name>Ridge</name><vendor:route><name>Not the name</name></vendor:route><trkseg>
            <trkpt lat="47.6300" lon="12.8600"><ele>100</ele><vendor:ele>9999</vendor:ele></trkpt>
            <trkpt lat="47.6310" lon="12.8600"><ele>110</ele></trkpt>
            <extensions><vendor:copy><trkpt \(Self.vendorPoint)/></vendor:copy></extensions>
            </trkseg></trk>
        </gpx>
        """)

        #expect(latitudes(track) == [476_300, 476_310])
        #expect(track.points.map(\.elevation) == [100, 110], "the vendor's height is not the point's")
        #expect(track.name == "Ridge")
    }

    @Test("a GPX 1.0 file reads its own elements and not a vendor's")
    func gpx10() throws {
        let track = try load("""
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.0" xmlns="http://www.topografix.com/GPX/1/0" \(Self.vendor)>
            <trk><trkseg>
            <trkpt lat="47.6300" lon="12.8600"/>
            <vendor:trkpt \(Self.vendorPoint)/>
            <trkpt lat="47.6310" lon="12.8600"/>
            </trkseg></trk>
        </gpx>
        """)

        #expect(latitudes(track) == [476_300, 476_310])
    }

    /// A file that names no namespace has its elements in none, and a
    /// vendor's prefixed element is still another namespace's. Its points
    /// written with no `<trkseg>` still belong to the track.
    @Test("a file with no namespace, and no trkseg, reads its points and not a vendor's")
    func noNamespaceNoSegment() throws {
        let track = try load("""
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" \(Self.vendor)>
            <trk>
            <trkpt lat="47.6300" lon="12.8600"/>
            <vendor:trkpt \(Self.vendorPoint)/>
            <trkpt lat="47.6310" lon="12.8600"/>
            </trk>
        </gpx>
        """)

        #expect(latitudes(track) == [476_300, 476_310])
    }

    /// A prefix bound to the file's own namespace is the file's own.
    @Test("GPX elements written with a prefix bound to GPX's namespace are read")
    func prefixedGPX() throws {
        let track = try load("""
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx:gpx version="1.1" xmlns:gpx="http://www.topografix.com/GPX/1/1">
            <gpx:trk><gpx:trkseg>
            <gpx:trkpt lat="47.6300" lon="12.8600"/>
            <gpx:trkpt lat="47.6310" lon="12.8600"/>
            </gpx:trkseg></gpx:trk>
        </gpx:gpx>
        """)

        #expect(latitudes(track) == [476_300, 476_310])
    }
}
