//
//  GPXExportTests+Antimeridian.swift
//  OpenHikesTests
//
//  The one longitude GPX 1.1 forbids. `longitudeType` stops short of +180,
//  so a file that spells the antimeridian that way is refused by a reader
//  that validates, and two positions used to produce it: a fix exactly on
//  +180, and one just short of it that seven places round up.
//
//  An extension of `GPXExportTests` for the reason its other files are: the
//  `one_suite_per_file` rule, and the fixtures — `track(…)`, `reimported(_:)`
//  — that the round trip needs.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

extension GPXExportTests {
    /// What each longitude is written as. Both ways onto +180 are here, and
    /// the values beside them on both sides of the meridian, which must keep
    /// every one of their seven places, rounded the way the style rounds
    /// them: the halves (`…85`, `…64999999`) are the ones a second rounding
    /// moved. The last four lie outside the range and come back a turn round.
    @Test(
        "a longitude is written inside GPX's range, to seven places",
        arguments: [
            (180.0, "-180.0000000"),
            (179.99999999, "-180.0000000"),
            (179.99999996, "-180.0000000"),
            (179.99999994, "179.9999999"),
            (179.9999999, "179.9999999"),
            (179.99999985, "179.9999998"),
            (-180.0, "-180.0000000"),
            (-179.99999999, "-180.0000000"),
            (-179.9999999, "-179.9999999"),
            (-179.99999985, "-179.9999998"),
            (12.7654321, "12.7654321"),
            (-0.000002, "-0.0000020"),
            (120.00000064999999, "120.0000006"),
            (180.00000004, "-180.0000000"),
            (-180.00000004, "-180.0000000"),
            (190.0, "-170.0000000"),
            (-190.0, "170.0000000"),
        ]
    )
    func writesLegalLongitude(degrees: Double, written: String) {
        #expect(GPXExport.formattedLongitude(degrees) == written)
    }

    /// A longitude keeps the rounding a latitude gets, so a point whose two
    /// are the same number is written with the same digits twice. Each value
    /// is one where rounding the `Double` by hand and rounding its digits
    /// disagree about the seventh place.
    @Test(
        "a longitude is rounded as a latitude is",
        arguments: [47.71816765, -57.41586205, 82.09270215, -10.30400765]
    )
    func roundsLongitudeAsLatitude(degrees: Double) throws {
        let point = RouteCoordinate(latitude: degrees, longitude: degrees)

        let xml = GPXExport.xml(for: track(route: [point]))

        let written = try #require(xml.firstMatch(of: #/<trkpt lat="([^"]+)" lon="([^"]+)"/#))
        #expect(written.output.1 == written.output.2)
    }

    /// A track point, a photograph and a place on +180, and one point that
    /// rounds onto it. Every `lon` the document carries goes through the one
    /// formatter, so none of the three may spell the meridian the way the
    /// schema forbids, and each comes back where it was.
    @Test("track points, photographs and places on +180° are written as −180°")
    func writesTheAntimeridianOneWay() throws {
        let onMeridian = RouteCoordinate(latitude: -16.7, longitude: 180)
        let roundedOnto = RouteCoordinate(latitude: -16.8, longitude: 179.99999999)
        var exported = track(route: [onMeridian, roundedOnto])
        exported.photographs = [
            GPXExport.Photograph(coordinate: onMeridian, capturedAt: Self.date),
        ]
        exported.places = [
            TrailPlace(latitude: -16.75, longitude: 180, name: "Date Line Hut"),
        ]

        let xml = GPXExport.xml(for: exported)

        #expect(!xml.contains(#"lon="180"#))
        #expect(xml.components(separatedBy: #"lon="-180.0000000""#).count - 1 == 4)
        let imported = try reimported(exported)
        #expect(imported.route.map(\.longitude) == [-180, -180])
        #expect(imported.places.map(\.longitude) == [-180])
    }
}
