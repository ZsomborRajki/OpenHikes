//
//  GPXImportContainerTests.swift
//  OpenHikesTests
//
//  What a GPX file's own containers mean, and what the import is allowed to do
//  with them.
//
//  A `<trk>` holds `<trkseg>` runs, and a file may hold several `<trk>`. The
//  parse used to pour all of it into one array, so two containers became one
//  line: a watch paused for lunch grew a straight leg across the valley, and a
//  file holding a week of walks became a single hike stitched between towns —
//  with the invented legs counted in the distance as if they had been walked.
//
//  The two boundaries are not the same problem, so they don't get the same
//  answer. Segments of one track are one walk with a hole in it, which
//  ``RouteProvenance`` already has a way to say. Separate tracks are separate
//  walks, and a hike holds one route, so the file is refused rather than
//  answered with a guess.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("GPX import containers")
struct GPXImportContainerTests {
    private func gpxFile(_ xml: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-\(UUID().uuidString)")
            .appendingPathExtension("gpx")
        try xml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// One walk in one `<trkseg>`: the shape nothing should be marked on.
    private static let unbrokenTrack = """
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx version="1.1" creator="OpenHikesTests" xmlns="http://www.topografix.com/GPX/1/1">
        <trk><trkseg>
        <trkpt lat="47.6300" lon="12.8600"/>
        <trkpt lat="47.6310" lon="12.8600"/>
        <trkpt lat="47.6320" lon="12.8600"/>
        </trkseg></trk>
    </gpx>
    """

    /// One walk, recorded with the watch paused in the middle: two `<trkseg>`
    /// containers about a kilometre apart, which is the shape that used to be
    /// flattened into a straight-line leg nobody walked.
    private static let pausedTrack = """
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx version="1.1" creator="OpenHikesTests" xmlns="http://www.topografix.com/GPX/1/1">
        <trk>
        <trkseg>
            <trkpt lat="47.6300" lon="12.8600"/>
            <trkpt lat="47.6310" lon="12.8600"/>
        </trkseg>
        <trkseg>
            <trkpt lat="47.6400" lon="12.8600"/>
        </trkseg>
        </trk>
    </gpx>
    """

    /// Multi-segment tracks (a recording paused and resumed) are one hike, in
    /// file order.
    @Test("every segment of a track is imported, in order")
    func multipleSegments() throws {
        let track = try GPXImport.load(from: try gpxFile(Self.pausedTrack))
        #expect(track.points.count == 3)
        #expect(track.points.map { ($0.coordinate.latitude * 1e4).rounded() } == [476_300, 476_310, 476_400])
    }

    /// The point that opens the second segment arrives across ground the file
    /// never recorded, and the route has to say so. Otherwise the map draws a
    /// solid line over a stretch nobody walked and the moving clock counts it
    /// as walking — which is exactly the "teleport leg" a paused recording
    /// used to produce silently.
    ///
    /// Read as a pause rather than as an inference: `<trkseg>` is what a
    /// pause is written as, here and by ``GPXExport``.
    @Test("the leg joining two segments is marked as a pause")
    func segmentBoundaryIsAPause() throws {
        let track = try GPXImport.load(from: try gpxFile(Self.pausedTrack))
        #expect(track.route.map(\.isPauseBoundary) == [false, false, true])
        // Nothing was reasoned about here — the file said the recording
        // stopped — so the route claims no inference either.
        #expect(!track.route.containsInferredGeometry)
        let segments = track.route.pausedSegments
        #expect(segments.count == 1)
        let segment = try #require(segments.first)
        // The gap is ~1 km against ~111 m of walking, so a line drawn over it
        // without saying anything would be mostly invention.
        #expect(
            RouteGeometry.distanceMeters(from: segment[0], to: segment[1]) > 900
        )
    }

    /// Nothing is marked when the file never split the track: an ordinary
    /// single-segment recording is one uninterrupted walk.
    @Test("an unbroken track carries no boundaries")
    func singleSegmentHasNoBoundaries() throws {
        let track = try GPXImport.load(from: try gpxFile(Self.unbrokenTrack))
        #expect(!track.route.containsPause)
        #expect(!track.route.containsInferredGeometry)
    }

    /// An empty `<trkseg>` — plenty of exporters leave one behind — is not a
    /// boundary, because nothing arrives across it.
    @Test("an empty segment introduces no boundary")
    func emptySegmentsAreNotBoundaries() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="OpenHikesTests" xmlns="http://www.topografix.com/GPX/1/1">
            <trk>
            <trkseg></trkseg>
            <trkseg>
                <trkpt lat="47.6300" lon="12.8600"/>
                <trkpt lat="47.6310" lon="12.8600"/>
            </trkseg>
            </trk>
        </gpx>
        """
        let track = try GPXImport.load(from: try gpxFile(xml))
        #expect(track.points.count == 2)
        #expect(!track.route.containsPause)
    }

    /// Two `<trk>` elements are two walks, and a hike holds one route. Joining
    /// them would draw a leg between two valleys; picking one would throw the
    /// other away without saying so. Refusing is the only answer that is true.
    @Test("a file holding several tracks is refused rather than joined")
    func refusesMultipleTracks() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="OpenHikesTests" xmlns="http://www.topografix.com/GPX/1/1">
            <trk><name>Morning</name><trkseg>
            <trkpt lat="47.6300" lon="12.8600"/>
            <trkpt lat="47.6310" lon="12.8600"/>
            </trkseg></trk>
            <trk><name>Afternoon</name><trkseg>
            <trkpt lat="48.1000" lon="11.5000"/>
            <trkpt lat="48.1010" lon="11.5000"/>
            </trkseg></trk>
        </gpx>
        """
        #expect(throws: GPXImport.ImportFailure.multipleTracks) {
            try GPXImport.load(from: try gpxFile(xml))
        }
    }

    /// Several `<rte>` elements are the same problem in the flavour below
    /// tracks, and the fallback must not quietly re-flatten what the track
    /// path refuses.
    @Test("a file holding several routes is refused too")
    func refusesMultipleRoutes() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="OpenHikesTests" xmlns="http://www.topografix.com/GPX/1/1">
            <rte><rtept lat="47.6300" lon="12.8600"/><rtept lat="47.6310" lon="12.8600"/></rte>
            <rte><rtept lat="48.1000" lon="11.5000"/><rtept lat="48.1010" lon="11.5000"/></rte>
        </gpx>
        """
        #expect(throws: GPXImport.ImportFailure.multipleTracks) {
            try GPXImport.load(from: try gpxFile(xml))
        }
    }

    /// A second `<trk>` that carries nothing importable is not a second walk.
    /// Exporters emit named-but-empty tracks and tracks whose points are all
    /// out of range; refusing an otherwise ordinary file over one would cost
    /// the walker the hike they actually have.
    @Test("a track with no usable points doesn't make a file multi-track", arguments: [
        "<trk><name>Empty</name></trk>",
        "<trk><trkseg></trkseg></trk>",
        "<trk><trkseg><trkpt lat=\"91.0\" lon=\"12.8600\"/></trkseg></trk>",
    ])
    func emptyTracksDontCountAsContainers(extraTrack: String) throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="OpenHikesTests" xmlns="http://www.topografix.com/GPX/1/1">
            <trk><name>Thumsee Loop</name><trkseg>
            <trkpt lat="47.6300" lon="12.8600"/>
            <trkpt lat="47.6310" lon="12.8600"/>
            </trkseg></trk>
            \(extraTrack)
        </gpx>
        """
        let track = try GPXImport.load(from: try gpxFile(xml))
        #expect(track.points.count == 2)
        #expect(track.name == "Thumsee Loop")
    }

    /// Legal GPX puts `<trkpt>` inside a `<trkseg>`, but files in the wild put
    /// them straight under `<trk>`. They still belong to that track, and they
    /// still have to be told apart from the next one's.
    @Test("track points written without a segment still belong to their track")
    func pointsWithoutASegmentKeepTheirTrack() throws {
        let single = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
            <trk><trkpt lat="47.6300" lon="12.8600"/><trkpt lat="47.6310" lon="12.8600"/></trk>
        </gpx>
        """
        let track = try GPXImport.load(from: try gpxFile(single))
        #expect(track.points.count == 2)
        #expect(!track.route.containsInferredGeometry)

        let pair = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
            <trk><trkpt lat="47.6300" lon="12.8600"/><trkpt lat="47.6310" lon="12.8600"/></trk>
            <trk><trkpt lat="48.1000" lon="11.5000"/><trkpt lat="48.1010" lon="11.5000"/></trk>
        </gpx>
        """
        #expect(throws: GPXImport.ImportFailure.multipleTracks) {
            try GPXImport.load(from: try gpxFile(pair))
        }
    }
}
