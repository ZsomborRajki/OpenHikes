//
//  MapControllerFramingTests.swift
//  OpenHikesTests
//
//  Framing a line the map is not otherwise drawing.
//
//  ``MapController/fitToRoute()`` fits the *selected hike's* overlay, which
//  while the trail maker is up is a different line or no line at all. So the
//  drawing has its own, and the two claims worth holding are that it frames
//  every point it was given and that it leaves the camera alone when there is
//  nothing to frame — a maker opened on an empty draft must not fly anywhere,
//  because where the hiker is looking is where they are about to draw.
//

import CoreLocation
import MapKit
@testable import OpenHikes
import Testing

@MainActor
@Suite("Map controller framing")
struct MapControllerFramingTests {
    private enum Ridge {
        static let west: Double = 12.8500
        static let east: Double = 12.8900
        static let south: Double = 47.6300
        static let north: Double = 47.6400
    }

    private static func coordinate(
        _ latitude: Double,
        _ longitude: Double
    ) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private static func contains(
        _ region: MKCoordinateRegion,
        _ coordinate: CLLocationCoordinate2D
    ) -> Bool {
        abs(region.center.latitude - coordinate.latitude) <= region.span.latitudeDelta / 2
            && abs(region.center.longitude - coordinate.longitude) <= region.span.longitudeDelta / 2
    }

    @Test("an empty drawing moves nothing")
    func nothingDrawnFramesNothing() {
        let controller = MapController()
        controller.showDrawnLine([])
        #expect(controller.showRegionRequest == 0)
        #expect(controller.region == nil)
    }

    /// A line of one coordinate has no extent, so it is framed by a span rather
    /// than by a fit — `MKMapRect` would otherwise frame nothing at all.
    @Test("a lone point is framed around itself")
    func onePointIsCentred() throws {
        let controller = MapController()
        let only = Self.coordinate(Ridge.south, Ridge.west)

        controller.showDrawnLine([only])

        let region = try #require(controller.region)
        #expect(controller.showRegionRequest == 1)
        #expect(abs(region.center.latitude - only.latitude) < 1e-6)
        #expect(abs(region.center.longitude - only.longitude) < 1e-6)
        #expect(region.span.latitudeDelta > 0)
    }

    @Test("every point of a drawn line is inside the frame")
    func theWholeLineIsFramed() throws {
        let controller = MapController()
        let line = [
            Self.coordinate(Ridge.south, Ridge.west),
            Self.coordinate(Ridge.north, Ridge.east),
            Self.coordinate(Ridge.south, Ridge.east),
        ]

        controller.showDrawnLine(line)

        let region = try #require(controller.region)
        for point in line {
            #expect(Self.contains(region, point), "the frame has to hold the whole drawing")
        }
    }

    /// Room around the line, so a pin at either end sits inside the frame
    /// rather than half off its edge.
    @Test("the frame is wider than the line itself")
    func theFrameIsPadded() throws {
        let controller = MapController()
        let line = [
            Self.coordinate(Ridge.south, Ridge.west),
            Self.coordinate(Ridge.north, Ridge.east),
        ]

        controller.showDrawnLine(line)

        let region = try #require(controller.region)
        #expect(region.span.latitudeDelta > Ridge.north - Ridge.south)
        #expect(region.span.longitudeDelta > Ridge.east - Ridge.west)
    }
}
