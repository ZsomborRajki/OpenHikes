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
    /// every one of their seven places.
    @Test(
        "a longitude is written inside GPX's range, to seven places",
        arguments: [
            (180.0, "-180.0000000"),
            (179.99999999, "-180.0000000"),
            (179.99999996, "-180.0000000"),
            (179.99999994, "179.9999999"),
            (179.9999999, "179.9999999"),
            (-180.0, "-180.0000000"),
            (-179.99999999, "-180.0000000"),
            (-179.9999999, "-179.9999999"),
            (12.7654321, "12.7654321"),
            (-0.000002, "-0.0000020"),
        ]
    )
    func writesLegalLongitude(degrees: Double, written: String) {
        #expect(GPXExport.formattedLongitude(degrees) == written)
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
