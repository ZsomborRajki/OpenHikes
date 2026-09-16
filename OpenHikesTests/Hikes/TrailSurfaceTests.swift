//
//  TrailSurfaceTests.swift
//  OpenHikesTests
//
//  Covers classifying OSM surface tagging. The other three parts of that
//  sentence are their own files now — TrailSurfaceBreakdownTests,
//  TrailSurfaceAnalyzerTests and TrailSurfacePersistenceTests — since a file
//  declares one @Suite.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Trail surface classification")
struct TrailSurfaceClassificationTests {
    @Test(
        "OSM surface values collapse onto the categories a hiker plans around",
        arguments: [
            ("asphalt", TrailSurface.paved),
            ("concrete:plates", .paved),
            ("paving_stones", .paved),
            ("sett", .paved),
            ("wood", .paved),
            ("gravel", .gravel),
            ("fine_gravel", .gravel),
            ("compacted", .gravel),
            ("pebblestone", .gravel),
            ("ground", .ground),
            ("dirt", .ground),
            ("grass", .ground),
            ("sand", .ground),
            ("unpaved", .ground),
            ("rock", .rock),
            ("scree", .rock),
        ]
    )
    func classifiesSurfaceValues(value: String, expected: TrailSurface) {
        #expect(TrailSurface(osmSurface: value) == expected)
    }

    @Test("a way that changes surface partway is read from its leading value")
    func takesTheLeadingValueOfAMultiValueSurface() {
        #expect(TrailSurface(osmSurface: "gravel;dirt") == .gravel)
        #expect(TrailSurface(osmSurface: "asphalt;gravel;wood") == .paved)
    }

    @Test("casing and stray whitespace don't change the category")
    func normalizesBeforeMatching() {
        #expect(TrailSurface(osmSurface: "  Asphalt ") == .paved)
        #expect(TrailSurface(osmSurface: "FINE_GRAVEL") == .gravel)
    }

    @Test("tagging nobody has taught this build about is unknown, not wrong")
    func unrecognizedTaggingIsUnknown() {
        #expect(TrailSurface(osmSurface: "moon_dust") == .unknown)
        #expect(TrailSurface(osmSurface: nil) == .unknown)
        #expect(TrailSurface(osmSurface: "") == .unknown)
    }

    @Test("tracktype answers only for a way that has no surface of its own")
    func fallsBackToTracktype() {
        #expect(TrailSurface(osmSurface: nil, tracktype: "grade1") == .paved)
        #expect(TrailSurface(osmSurface: nil, tracktype: "grade2") == .gravel)
        #expect(TrailSurface(osmSurface: nil, tracktype: "grade5") == .ground)
        // A surface tag is a material and beats a firmness grade.
        #expect(
            TrailSurface(osmSurface: "ground", tracktype: "grade1") == .ground
        )
        // An unrecognised surface shouldn't block a usable tracktype.
        #expect(
            TrailSurface(osmSurface: "moon_dust", tracktype: "grade1") == .paved
        )
        #expect(TrailSurface(osmSurface: nil, tracktype: "grade9") == .unknown)
    }

    @Test("only the four surveyed categories claim to describe a surface")
    func surveyedCategories() {
        #expect(TrailSurface.allCases.filter(\.isSurveyed).count == 4)
        #expect(!TrailSurface.unknown.isSurveyed)
        #expect(!TrailSurface.unmapped.isSurveyed)
    }
}
