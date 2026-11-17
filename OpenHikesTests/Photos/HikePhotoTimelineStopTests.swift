//
//  HikePhotoTimelineStopTests.swift
//  OpenHikesTests
//
//  What a timeline says about a photograph taken during a stop: a pause
//  whose two ends are one place (#1470).
//
//  ``HikePhotoTimelinePauseTests`` pins the refusal: a paused leg can be a
//  drive, so a picture from the middle of a long one is placed nowhere. A
//  stop is the pause that refusal has no reason for. The hiker went nowhere,
//  and a hut or a summit is where most of a hike's pictures are taken.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Hike photo timeline at a stop")
struct HikePhotoTimelineStopTests {
    private static let latitude = 47.0
    private static let longitude = 12.0
    private static let metersPerDegree = 111_195.0
    private static let epoch = Date(timeIntervalSince1970: 1_750_000_000)
    private static let toleranceMeters = 0.5
    /// Forty minutes at a hut.
    private static let stopLength: TimeInterval = 2400

    private static func coordinate(north meters: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude + meters / metersPerDegree, longitude: longitude)
    }

    /// A walk to the hut, a pause of `stopLength` that resumes `span` metres
    /// from where it began, and a minute of walking on.
    private static func route(resumingAfter span: Double) -> [RouteCoordinate] {
        func point(north meters: Double, at seconds: TimeInterval, resumed: Bool = false) -> RouteCoordinate {
            RouteCoordinate(
                latitude: coordinate(north: meters).latitude,
                longitude: longitude,
                timestamp: epoch.addingTimeInterval(seconds),
                boundary: resumed ? .paused : nil
            )
        }
        return [
            point(north: -100, at: -60),
            point(north: 0, at: 0),
            point(north: span, at: stopLength, resumed: true),
            point(north: span + 100, at: stopLength + 60),
        ]
    }

    private static func meters(
        from position: HikePhotoTimeline.Position,
        to coordinate: CLLocationCoordinate2D
    ) -> Double {
        RouteGeometry.distanceMeters(from: position.coordinate, to: coordinate)
    }

    @Test("a photo taken in the middle of a long stop is placed at the stop")
    func middleOfAStop() throws {
        let timeline = try #require(HikePhotoTimeline(route: Self.route(resumingAfter: 25)))

        let position = try #require(timeline.position(at: Self.epoch.addingTimeInterval(900)))

        #expect(Self.meters(from: position, to: Self.coordinate(north: 0)) < Self.toleranceMeters)
        #expect(position.secondsFromFix == 900, "how long before or after a fix it was taken is still said")
    }

    @Test("a photo taken late in a stop is placed where the walk resumed")
    func lateInAStop() throws {
        let timeline = try #require(HikePhotoTimeline(route: Self.route(resumingAfter: 25)))

        let position = try #require(timeline.position(at: Self.epoch.addingTimeInterval(Self.stopLength - 600)))

        #expect(Self.meters(from: position, to: Self.coordinate(north: 25)) < Self.toleranceMeters)
    }

    @Test("nothing is interpolated across a stop either")
    func noInterpolation() throws {
        let timeline = try #require(HikePhotoTimeline(route: Self.route(resumingAfter: 80)))

        let position = try #require(timeline.position(at: Self.epoch.addingTimeInterval(Self.stopLength / 2 - 1)))

        #expect(Self.meters(from: position, to: Self.coordinate(north: 0)) < Self.toleranceMeters)
    }

    /// The pause that the grace is for: it resumed somewhere else.
    @Test("a pause that ends somewhere else still places nothing in its middle")
    func aPauseThatWentSomewhere() throws {
        let span = HikePhotoTimeline.stopSpanMeters + 50
        let timeline = try #require(HikePhotoTimeline(route: Self.route(resumingAfter: span)))

        #expect(timeline.position(at: Self.epoch.addingTimeInterval(900)) == nil)
        #expect(timeline.position(at: Self.epoch.addingTimeInterval(120)) != nil, "its ends keep their grace")
    }
}
