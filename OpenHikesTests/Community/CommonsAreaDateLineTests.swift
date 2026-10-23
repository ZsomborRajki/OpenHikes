//
//  CommonsAreaDateLineTests.swift
//  OpenHikesTests
//
//  The Commons photographs an area search picks, in the trail maker and on
//  the *Community* tab alike, are the same whichever side of the date line
//  the area's middle stands on: a picture a kilometre over ±180° is a
//  kilometre away, not a lap of the planet.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Commons area photos across the date line")
struct CommonsAreaDateLineTests {
    private static let metersPerDegree = 111_320.0

    /// Taveuni's latitude, which the date line crosses. The tests stand the
    /// area's middle a third of a kilometre west of the line (179.997) and
    /// east of it (-179.997), and compare both against Greenwich.
    private static let latitude = -16.8

    private struct Photo {
        var pageID: Int
        var north: Double
        var east: Double
    }

    /// One configuration in metres from the middle, each photograph far
    /// enough east or west to sit over the line from one of the two middles
    /// above. With a limit of four the grid is two by two, split at the
    /// middle: the crowd fills the north-east cell, and one photograph stands
    /// alone in each of the other three.
    private static let layout: [Photo] = (1...6).map { index in
        let step = Double(index) * 15
        return Photo(pageID: index, north: 100 + step, east: 400 + step)
    } + [
        Photo(pageID: 20, north: -900, east: -1100),
        Photo(pageID: 21, north: 1000, east: -700),
        Photo(pageID: 22, north: -600, east: 1300),
        // Outside a two-kilometre circle, one each way over the line.
        Photo(pageID: 30, north: 0, east: 2300),
        Photo(pageID: 31, north: 100, east: -2400),
    ]

    /// ``layout`` laid out around `middle`, longitudes wrapped into ±180° the
    /// way a geosearch answers them.
    private static func candidates(around middle: CLLocationCoordinate2D) -> [CommonsPhotoCandidate] {
        layout.map { photo in
            CommonsPhotoCandidate(
                pageID: photo.pageID,
                latitude: middle.latitude + photo.north / metersPerDegree,
                longitude: RouteGeometry.normalizedLongitude(
                    middle.longitude + photo.east / (metersPerDegree * cos(middle.latitude * .pi / 180))
                )
            )
        }
    }

    /// The page IDs `spread` keeps of ``layout`` around a middle at
    /// `longitude`, in a two-kilometre circle.
    private static func spread(aroundLongitude longitude: Double, limit: Int) -> [Int] {
        let middle = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let area = CommunitySearchArea(coordinate: middle, radiusMeters: 2000)
        return CommonsAreaPhotos.spread(candidates(around: middle), in: area, limit: limit).map(\.pageID)
    }

    @Test("a photograph over the line is inside the circle, one past the radius is not", arguments: [
        179.997, -179.997,
    ])
    func theCircleWrapsTheLine(longitude: Double) {
        let kept = Self.spread(aroundLongitude: longitude, limit: 16)

        #expect(kept == Self.spread(aroundLongitude: 0, limit: 16))
        #expect(Set(kept) == [1, 2, 3, 4, 5, 6, 20, 21, 22])
    }

    @Test("the grid gives each cell its turn on either side of the line", arguments: [
        179.997, -179.997,
    ])
    func theGridWrapsTheLine(longitude: Double) {
        let kept = Self.spread(aroundLongitude: longitude, limit: 4)

        #expect(kept == Self.spread(aroundLongitude: 0, limit: 4))
        // The crowd's member nearest its cell's middle, then the three loners
        // nearest the area's middle first.
        #expect(kept == [6, 21, 20, 22])
    }
}
