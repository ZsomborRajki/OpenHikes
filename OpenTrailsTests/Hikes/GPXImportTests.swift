//
//  GPXImportTests.swift
//  OpenTrailsTests
//
//  GPX import is the app's only way to get a hike in, and its only untrusted
//  input: an arbitrary file picked from Files/iCloud, written by any of a
//  hundred different exporters. So there are two things to check here — that
//  a well-formed file yields everything the detail view will ask for, and
//  that a badly-formed one is refused at the door rather than turned into a
//  Hike that breaks something later.
//

import CoreLocation
import Foundation
@testable import OpenTrails
import Testing

@Suite("GPX import")
struct GPXImportTests {
    // MARK: Fixtures

    /// Writes `xml` to a temp file so it can be handed to the importer the
    /// same way a picked document is.
    private func gpxFile(_ xml: String, name: String = "fixture") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
            .appendingPathExtension("gpx")
        try xml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static let fullTrack = """
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx version="1.1" creator="OpenTrailsTests" xmlns="http://www.topografix.com/GPX/1/1">
        <metadata>
        <name>Metadata Name</name>
        <desc>Metadata description</desc>
        <author><name>Ada Lovelace</name></author>
        <keywords>hiking, bavaria</keywords>
        <time>2026-06-01T08:00:00Z</time>
        </metadata>
        <trk>
        <name>Thumsee Loop</name>
        <desc>A lakeside loop.</desc>
        <trkseg>
            <trkpt lat="47.6300" lon="12.8600"><ele>600.0</ele><time>2026-06-01T08:05:00Z</time></trkpt>
            <trkpt lat="47.6310" lon="12.8600"><ele>620.0</ele><time>2026-06-01T08:06:00Z</time></trkpt>
            <trkpt lat="47.6320" lon="12.8600"><ele>610.0</ele><time>2026-06-01T08:07:00Z</time></trkpt>
        </trkseg>
        </trk>
    </gpx>
    """

    // MARK: A well-formed file

    @Test("a track's points, elevations and times all come through")
    func loadsTrackPoints() throws {
        let track = try GPXImport.load(from: try gpxFile(Self.fullTrack))
        #expect(track.points.count == 3)
        #expect(abs(track.points[0].coordinate.latitude - 47.63) < 1e-9)
        #expect(abs(track.points[0].coordinate.longitude - 12.86) < 1e-9)
        #expect(track.points.map(\.elevation) == [600, 620, 610])
        #expect(track.points.allSatisfy { $0.time != nil })
    }

    /// The track's own name/description win over the file-level metadata:
    /// exporters commonly leave a generic metadata name ("Track") next to a
    /// meaningful one on the track itself.
    @Test("the track's own name and description are preferred over the file's")
    func prefersTrackMetadata() throws {
        let track = try GPXImport.load(from: try gpxFile(Self.fullTrack))
        #expect(track.name == "Thumsee Loop")
        #expect(track.trackDescription == "A lakeside loop.")
        #expect(track.author == "Ada Lovelace")
        #expect(track.keywords == "hiking, bavaria")
    }

    @Test("the activity date comes from the file's metadata when it has one")
    func startTimeFromMetadata() throws {
        let track = try GPXImport.load(from: try gpxFile(Self.fullTrack))
        let expected = ISO8601DateFormatter().date(from: "2026-06-01T08:00:00Z")
        #expect(track.startTime == expected)
    }

    /// Without file metadata, the first point that carries a time stands in —
    /// otherwise the hike would be filed under its import date.
    @Test("without metadata the first timestamped point dates the hike")
    func startTimeFromFirstPoint() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="OpenTrailsTests" xmlns="http://www.topografix.com/GPX/1/1">
            <trk><trkseg>
            <trkpt lat="47.6300" lon="12.8600"><ele>600.0</ele></trkpt>
            <trkpt lat="47.6310" lon="12.8600"><ele>620.0</ele><time>2026-06-01T09:30:00Z</time></trkpt>
            </trkseg></trk>
        </gpx>
        """
        let track = try GPXImport.load(from: try gpxFile(xml))
        #expect(track.startTime == ISO8601DateFormatter().date(from: "2026-06-01T09:30:00Z"))
    }

    /// The length shown on the hike row comes from here, and it has to be the
    /// walked distance — the sum of the legs, not the crow-flies span.
    @Test("length is summed leg by leg")
    func distanceIsSummedPerLeg() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="OpenTrailsTests" xmlns="http://www.topografix.com/GPX/1/1">
            <trk><trkseg>
            <trkpt lat="47.6300" lon="12.8600"/>
            <trkpt lat="47.6310" lon="12.8600"/>
            <trkpt lat="47.6300" lon="12.8600"/>
            </trkseg></trk>
        </gpx>
        """
        let track = try GPXImport.load(from: try gpxFile(xml))
        // ~111 m out and ~111 m back: an out-and-back is twice the span, not zero.
        #expect(abs(track.distanceMeters - 222) < 5)
    }

    @Test("a single point has no length to speak of")
    func distanceSinglePoint() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="OpenTrailsTests" xmlns="http://www.topografix.com/GPX/1/1">
            <trk><trkseg><trkpt lat="47.6300" lon="12.8600"/></trkseg></trk>
        </gpx>
        """
        let track = try GPXImport.load(from: try gpxFile(xml))
        #expect(track.distanceMeters == 0)
        #expect(track.points.count == 1)
    }

    /// Multi-segment tracks (a recording paused and resumed) are one hike, in
    /// file order.
    @Test("every segment of a track is imported, in order")
    func multipleSegments() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="OpenTrailsTests" xmlns="http://www.topografix.com/GPX/1/1">
            <trk>
            <trkseg>
                <trkpt lat="47.6300" lon="12.8600"/>
                <trkpt lat="47.6310" lon="12.8600"/>
            </trkseg>
            <trkseg>
                <trkpt lat="47.6320" lon="12.8600"/>
            </trkseg>
            </trk>
        </gpx>
        """
        let track = try GPXImport.load(from: try gpxFile(xml))
        #expect(track.points.count == 3)
        #expect(track.points.map { ($0.coordinate.latitude * 1e4).rounded() } == [476_300, 476_310, 476_320])
    }

    // MARK: Falling back through the GPX flavours

    /// Plenty of planning tools export a *route* rather than a track.
    @Test("a file with only a route still imports")
    func fallsBackToRoutePoints() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="OpenTrailsTests" xmlns="http://www.topografix.com/GPX/1/1">
            <rte>
            <rtept lat="47.6300" lon="12.8600"><ele>600.0</ele></rtept>
            <rtept lat="47.6310" lon="12.8600"><ele>620.0</ele></rtept>
            </rte>
        </gpx>
        """
        let track = try GPXImport.load(from: try gpxFile(xml))
        #expect(track.points.count == 2)
        #expect(track.points[1].elevation == 620)
    }

    /// And some export loose waypoints — the last resort before giving up.
    @Test("a file with only waypoints still imports")
    func fallsBackToWaypoints() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="OpenTrailsTests" xmlns="http://www.topografix.com/GPX/1/1">
            <wpt lat="47.6300" lon="12.8600"><ele>600.0</ele></wpt>
            <wpt lat="47.6310" lon="12.8600"><ele>620.0</ele></wpt>
        </gpx>
        """
        let track = try GPXImport.load(from: try gpxFile(xml))
        #expect(track.points.count == 2)
    }

    /// Track points win when a file carries several flavours at once —
    /// otherwise a route's handful of turn markers would replace the real
    /// recorded track.
    @Test("track points win over routes and waypoints in the same file")
    func trackWinsOverOtherFlavours() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="OpenTrailsTests" xmlns="http://www.topografix.com/GPX/1/1">
            <wpt lat="10.0" lon="10.0"/>
            <rte><rtept lat="20.0" lon="20.0"/></rte>
            <trk><trkseg>
            <trkpt lat="47.6300" lon="12.8600"/>
            <trkpt lat="47.6310" lon="12.8600"/>
            </trkseg></trk>
        </gpx>
        """
        let track = try GPXImport.load(from: try gpxFile(xml))
        #expect(track.points.count == 2)
        #expect(track.points.allSatisfy { $0.coordinate.latitude > 47 })
    }

    // MARK: Refusing bad input

    /// Coordinates Web Mercator can't hold are dropped rather than clamped:
    /// clamping would quietly move a point onto the edge of the map, and —
    /// before the check existed — feeding one to the tile math was a crash.
    @Test("points outside the projection's range are dropped, not clamped")
    func rejectsUnprojectableCoordinates() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="OpenTrailsTests" xmlns="http://www.topografix.com/GPX/1/1">
            <trk><trkseg>
            <trkpt lat="47.6300" lon="12.8600"/>
            <trkpt lat="90.0" lon="12.8600"/>
            <trkpt lat="-90.0" lon="12.8600"/>
            <trkpt lat="47.6310" lon="360.0"/>
            <trkpt lat="47.6320" lon="12.8600"/>
            </trkseg></trk>
        </gpx>
        """
        let track = try GPXImport.load(from: try gpxFile(xml))
        #expect(track.points.count == 2)
        for point in track.points {
            #expect(abs(point.coordinate.latitude) < 85)
            #expect(abs(point.coordinate.longitude) <= 180)
        }
    }

    /// A file that parsed fine and simply has nothing in it. Told apart from
    /// "that isn't a GPX file" because the user can act on the difference —
    /// and because the import used to report neither.
    @Test("a parsable file with nothing importable is refused as empty", arguments: [
        // Well-formed GPX, no points anywhere.
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1"><metadata><name>Empty</name></metadata></gpx>
        """,
        // Every point unprojectable.
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
            <trk><trkseg><trkpt lat="91.0" lon="12.86"/><trkpt lat="47.63" lon="181.0"/></trkseg></trk>
        </gpx>
        """,
        // Points missing coordinates entirely.
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
            <trk><trkseg><trkpt><ele>600</ele></trkpt></trkseg></trk>
        </gpx>
        """,
        // Well-formed XML that simply isn't GPX. CoreGPX parses it happily
        // into a document with no tracks, so it can't be told apart from an
        // empty GPX file — which is why `.noUsablePoints` is worded to cover
        // "this may not be a GPX file" too.
        "<?xml version=\"1.0\"?><html><body>Not a GPX file</body></html>",
    ])
    func refusesEmptyFiles(xml: String) throws {
        #expect(throws: GPXImport.ImportFailure.noUsablePoints) {
            try GPXImport.load(from: try gpxFile(xml))
        }
    }

    /// Only a file the parser can't get through at all reaches `.unreadable`.
    @Test("a file that isn't even XML is refused as unreadable")
    func refusesNonXMLFiles() throws {
        #expect(throws: GPXImport.ImportFailure.unreadable) {
            try GPXImport.load(from: try gpxFile("this is not a gpx file"))
        }
    }

    @Test("a file that isn't there is refused rather than trapping")
    func refusesMissingFile() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).gpx")
        #expect(throws: GPXImport.ImportFailure.unreadable) {
            try GPXImport.load(from: missing)
        }
    }

    @Test("background parsing preserves the specific import failure")
    func backgroundParsingPreservesFailure() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).gpx")
        var failure: GPXImport.ImportFailure?

        do throws(GPXImport.ImportFailure) {
            _ = try await GPXImport.loadOffMain(from: missing)
        } catch {
            failure = error
        }

        #expect(failure == .unreadable)
    }

    /// Every refusal has to carry something to show the user — the whole point
    /// of typing them. A case added later without copy would fail here rather
    /// than surfacing as an empty alert.
    @Test("every failure explains itself", arguments: [
        GPXImport.ImportFailure.unreadable, .noUsablePoints, .tooShort
    ])
    func failuresAreExplained(failure: GPXImport.ImportFailure) throws {
        let description = try #require(failure.errorDescription)
        let suggestion = try #require(failure.recoverySuggestion)
        #expect(!description.isEmpty)
        #expect(!suggestion.isEmpty)
    }

    /// A one-point file parses successfully — refusing it is the *import's*
    /// call. Keeping the two apart is what lets the alert say "only one track
    /// point" instead of the blanket "couldn't read that".
    @Test("a single-point file parses, and is left for the import to refuse")
    func singlePointParsesButIsntARoute() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="OpenTrailsTests" xmlns="http://www.topografix.com/GPX/1/1">
            <trk><trkseg><trkpt lat="47.6300" lon="12.8600"/></trkseg></trk>
        </gpx>
        """
        let track = try GPXImport.load(from: try gpxFile(xml))
        #expect(track.points.count == 1)
        // The rule `OpenTrailsModel.importHike` applies to it.
        #expect(track.points.count <= 1, "which is what makes it .tooShort at the import")
    }

    /// Blank metadata fields are common (`<desc></desc>`) and should read as
    /// absent, so the detail view's Details section doesn't appear with
    /// nothing in it.
    @Test("blank metadata reads as absent")
    func blankMetadataIsAbsent() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
            <metadata><desc>   </desc><keywords></keywords><author><name> </name></author></metadata>
            <trk><name>  </name><trkseg>
            <trkpt lat="47.6300" lon="12.8600"/>
            <trkpt lat="47.6310" lon="12.8600"/>
            </trkseg></trk>
        </gpx>
        """
        let track = try GPXImport.load(from: try gpxFile(xml))
        #expect(track.name == nil)
        #expect(track.trackDescription == nil)
        #expect(track.author == nil)
        #expect(track.keywords == nil)
    }

    // MARK: What the rest of the app builds on top

    /// An imported track is immediately re-read by `RouteProfile` (elevation
    /// chart, auto-follow) and by the tile enumerators. This is the seam
    /// between "parsed a file" and "the feature works", so it's checked as
    /// one step rather than assumed.
    @Test("an imported track indexes cleanly into a route profile")
    func importedTrackFeedsTheProfile() throws {
        let track = try GPXImport.load(from: try gpxFile(Self.fullTrack))
        let profile = RouteProfile(route: track.route)
        #expect(profile.samples.count == track.points.count)
        #expect(abs((profile.distances.last ?? 0) - track.distanceMeters) < 0.001)
        let range = try #require(profile.elevationRange)
        #expect(range == 600...620)
    }
}
