//
//  GPXExportTests+Photographs.swift
//  OpenHikesTests
//
//  The `<wpt>` half of the document, and the two things it deliberately does
//  not carry.
//
//  An extension rather than a suite of its own, for the reason
//  `GPXExportTests+FileName.swift` is one: these are `GPXExportTests` tests,
//  the `one_suite_per_file` rule forbids a second `@Suite` here, and the
//  fixtures above — `track(…)`, `reimported(_:)` — are exactly what they need.
//
//  The round trip is the assertion that matters most and it is the one that
//  could not exist before this change: a file carrying **both** a track and
//  photo waypoints has to come back as that track. `GPXImport` reads `<wpt>`
//  only as a last-resort source of track points, for a file with no `<trk>`
//  and no `<rte>` — which is correct, and which nothing pinned. Writing
//  waypoints into every exported hike is what makes it load-bearing.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

extension GPXExportTests {
    /// Two photographs on the route, far enough apart that a waypoint written
    /// at the wrong one is visible in the assertion rather than inside a
    /// rounding error.
    /// Seven decimal places on each, because that is the precision the
    /// exporter promises and a shorter coordinate would pass whatever it did
    /// with the rest.
    static let firstPhotographLatitude = 47.6301234
    static let firstPhotographLongitude = 12.9901234
    static let firstPhotographElevation = 812.5
    static let secondPhotographLatitude = 47.6404321
    static let secondPhotographLongitude = 12.9804321
    /// Ten minutes and twenty minutes into the walk, measured from the
    /// suite's own hike date rather than spelled as epoch seconds — a
    /// timestamp written as a literal says nothing about where in the walk it
    /// falls.
    private static let firstPhotographOffset: TimeInterval = 600
    private static let secondPhotographOffset: TimeInterval = 1200
    static let firstPhotographTime = date.addingTimeInterval(firstPhotographOffset)
    static let secondPhotographTime = date.addingTimeInterval(secondPhotographOffset)

    private static var photographs: [GPXExport.Photograph] {
        [
            GPXExport.Photograph(
                coordinate: RouteCoordinate(
                    latitude: firstPhotographLatitude,
                    longitude: firstPhotographLongitude,
                    elevation: firstPhotographElevation
                ),
                capturedAt: firstPhotographTime
            ),
            GPXExport.Photograph(
                coordinate: RouteCoordinate(
                    latitude: secondPhotographLatitude,
                    longitude: secondPhotographLongitude
                ),
                capturedAt: secondPhotographTime
            ),
        ]
    }

    private func photographed() -> GPXExport.Track {
        var payload = track()
        payload.photographs = Self.photographs
        return payload
    }

    // MARK: What is written

    @Test("an anchored photograph is written as a waypoint with its place and moment")
    func writesAWaypointPerPhotograph() {
        let xml = GPXExport.xml(for: photographed())

        #expect(xml.components(separatedBy: "<wpt ").count - 1 == 2)
        #expect(xml.contains("<wpt lat=\"47.6301234\" lon=\"12.9901234\">"))
        #expect(xml.contains("<wpt lat=\"47.6404321\" lon=\"12.9804321\">"))
        #expect(xml.contains("<ele>812.50</ele>"))
        #expect(xml.contains("<name>Photo</name>"))
        #expect(xml.contains("<sym>Photo</sym>"))
    }

    /// The pixels live under ``HikePhotoStore`` and the share sheet hands over
    /// one `.gpx`, so a `<link href="…">` would be a promise about a file the
    /// receiver does not have — see ``GPXExport/Photograph``.
    @Test("no link is written, because the picture does not travel with the file")
    func writesNoLinkToThePixels() {
        let xml = GPXExport.xml(for: photographed())

        #expect(!xml.contains("<link"))
    }

    /// `lat` and `lon` are required attributes and ``HikePhoto``'s coordinate
    /// is optional on purpose, so there is no honest waypoint for a photo with
    /// no place on the map. The omission is the decision; this is what says it
    /// out loud.
    @Test("a hike whose photographs are all unanchored writes no waypoints")
    func omitsUnanchoredPhotographs() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        hike.photos = [
            HikePhoto(capturedAt: Self.firstPhotographTime),
            HikePhoto(capturedAt: Self.secondPhotographTime),
        ]

        let payload = GPXExport.Track(hike: hike)

        #expect(payload.photographs.isEmpty)
        #expect(!GPXExport.xml(for: payload).contains("<wpt "))
    }

    @Test("only the anchored half of a mixed gallery reaches the file")
    func writesOnlyTheAnchoredPhotographs() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let anchored = try #require(Fixture.ridgeRoute.first)
        hike.photos = [
            HikePhoto(capturedAt: Self.firstPhotographTime),
            HikePhoto(
                capturedAt: Self.secondPhotographTime,
                coordinate: CLLocationCoordinate2D(
                    latitude: anchored.latitude,
                    longitude: anchored.longitude
                )
            ),
        ]

        let payload = GPXExport.Track(hike: hike)

        #expect(payload.photographs.count == 1)
        #expect(payload.photographs.first?.coordinate.latitude == anchored.latitude)
        #expect(GPXExport.xml(for: payload).components(separatedBy: "<wpt ").count - 1 == 1)
    }

    @Test("a hike with no photographs writes the document it always wrote")
    func writesNoWaypointsWithoutPhotographs() {
        #expect(!GPXExport.xml(for: track()).contains("<wpt"))
    }

    // MARK: Where it is written

    /// GPX 1.1 fixes the order of `<gpx>`'s children — metadata, `wpt*`,
    /// `rte*`, `trk*` — exactly as it fixes `<metadata>`'s own, and a
    /// schema-validating reader refuses a file that puts waypoints after the
    /// track. Nothing in a round trip can see this: our own importer does not
    /// care, which is precisely why it needs its own assertion.
    @Test("waypoints are written between the metadata and the track")
    func writesWaypointsInSchemaOrder() throws {
        let xml = GPXExport.xml(for: photographed())
        let metadata = try #require(xml.range(of: "</metadata>"))
        let waypoint = try #require(xml.range(of: "<wpt "))
        let track = try #require(xml.range(of: "<trk>"))

        #expect(metadata.upperBound < waypoint.lowerBound)
        #expect(waypoint.upperBound < track.lowerBound)
    }

    // MARK: The round trip

    /// **The one this change makes load-bearing.** `GPXImport.track(from:)`
    /// falls back to `<wpt>` only for a file with no `<trk>` and no `<rte>`,
    /// so a file carrying both comes back as its track — and now that every
    /// exported hike with a photograph carries both, that fallback ordering is
    /// something the app depends on rather than a courtesy to other people's
    /// files.
    @Test("a file carrying both a track and photo waypoints re-imports as the track")
    func reimportsTheTrackRatherThanTheWaypoints() throws {
        let payload = photographed()

        let imported = try reimported(payload)

        #expect(imported.route.count == payload.route.count)
        #expect(imported.route.first?.latitude == payload.route.first?.latitude)
        #expect(imported.route.last?.latitude == payload.route.last?.latitude)
        // The sharp version of the same thing: a waypoint's coordinate must
        // not appear in the route at all. Both sit off the ridge fixture's
        // line, so finding one here would mean the fallback had been taken.
        for photograph in payload.photographs {
            #expect(!imported.route.contains { $0.latitude == photograph.coordinate.latitude })
        }
    }
}
