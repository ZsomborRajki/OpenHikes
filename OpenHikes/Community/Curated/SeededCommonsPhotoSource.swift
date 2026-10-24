//
//  SeededCommonsPhotoSource.swift
//  OpenHikes
//
//  Three photographs from Wikimedia Commons that nobody downloaded.
//
//  The Commons half of `--ui-test-community=commons`, behind the same door as
//  ``SeededCuratedTrailSource`` and for the same reason: a launch gets one only
//  by naming that scenario, the whole file is `#if DEBUG`, and no suite reaches
//  Wikimedia by falling into anything.
//
//  What is faked is only the network. The photographs are real JPEGs written
//  into the preview's own directory, standing on the route they were asked
//  about, and from there they go through the real gallery merge, the real map
//  pins, the real viewer's credit and the real ``CommunityImport`` — so a test
//  that opens one is testing the app.
//
//  Two of the three name an author and one does not, because a Commons file
//  page that names nobody is an ordinary case and the credit has a shape for
//  it: the licence and the link, with nobody in front of them.
//
//  An area search finds two more, taken a few metres from the third, because
//  a spot photographed from every side is the ordinary shape of a summit or a
//  hut on Commons, and the *Community* tab draws such a group as one pin —
//  see `MapCommunityCommonsPhotos.swift`. Metres rather than shares of the
//  area, so they stay one group at whatever zoom the area was searched at.
//

import CoreLocation
import Foundation
import OpenHikesData

#if DEBUG

/// A stand-in for Wikimedia Commons with three photographs on every route.
nonisolated struct SeededCommonsPhotoSource: CommonsPhotoSourcing {
    /// Who took the three, in walking order — the last names nobody — and
    /// then the two an area search finds beside the third.
    static let authors: [String?] = ["Anna Berger", "Lukas Moser", nil, "Marta Huber", "Jonas Leitner"]
    /// What all of them are shared under.
    static let licenseName = "CC BY-SA 4.0"

    /// Where along the route each stands, as a share of its length.
    private static let positions = [0.25, 0.5, 0.75]
    /// Picked so the seeded frames draw in hues the community's own seeded
    /// photographs do not.
    private static let firstFrame = 7
    /// The frame the community's seeded photographs are drawn at: a real JPEG
    /// the real decode reads, without twelve megapixels of it.
    private static let frameWidth = 1008.0
    private static let frameHeight = 756.0
    private static let frameSize = CGSize(width: frameWidth, height: frameHeight)
    // swiftlint:disable force_unwrapping
    private static let licenseURL = URL(string: "https://creativecommons.org/licenses/by-sa/4.0/")!
    private static let filePage = URL(string: "https://commons.wikimedia.org/wiki/File:Seeded_trail_photo.jpg")!
    // swiftlint:enable force_unwrapping

    @concurrent
    func photos(along route: [RouteCoordinate], downloadingInto directory: URL) async throws -> [CommonsPhoto] {
        guard route.count > 1 else { return [] }
        let profile = RouteProfile(route: route)
        let spots = Self.positions.map { profile.coordinate(atDistance: profile.totalDistanceMeters * $0) }
        return try await Self.photos(at: spots, downloadingInto: directory)
    }

    /// The same three, across the area on screen rather than along a route —
    /// the trail maker's *Search this area* under
    /// `--ui-test-trail-points=seeded` and the *Community* tab's — and the two
    /// beside the third. Both pills hand over the rectangle they measured
    /// above the sheet, so all of it is visible and the three go just south
    /// of its middle, clear of the pill along the top. A second search over
    /// the same area finds the five already shown and adds nothing, which is
    /// what the real source does too.
    @concurrent
    func photos(
        in area: CommunitySearchArea,
        avoiding shown: Set<URL>,
        downloadingInto directory: URL
    ) async throws -> [CommonsPhoto] {
        // Shares of the rectangle on screen, or of the circle for an area
        // that carries none, which no pill hands over.
        let halfHeight = area.visibleSpan.map { $0.latitudeDelta / 2 } ?? area.radiusMeters / Self.metersPerDegree
        let halfWidth = area.visibleSpan.map { $0.longitudeDelta / 2 }
            ?? area.radiusMeters / Self.metersPerDegree / cos(area.latitude * .pi / 180)
        let spots: [CLLocationCoordinate2D] = zip(Self.areaNorths, Self.areaEasts).map { north, east in
            CLLocationCoordinate2D(
                latitude: area.latitude + north * halfHeight,
                longitude: area.longitude + east * halfWidth
            )
        }
        let third = spots[spots.count - 1]
        let beside = Self.besideThird.map { north, east in
            CLLocationCoordinate2D(
                latitude: third.latitude + north / Self.metersPerDegree,
                longitude: third.longitude + east / Self.metersPerDegree / cos(third.latitude * .pi / 180)
            )
        }
        return try await Self.photos(at: spots + beside, downloadingInto: directory)
            .filter { !shown.contains($0.credit.license.sourceURL) }
    }

    /// Where an area's three stand, as shares of its half-height north and
    /// its half-width east of its middle: a little south of the middle, below
    /// the pill, and apart enough that no two thumbnails overlap.
    private static let sideNorth = -0.2
    private static let middleNorth = -0.1
    private static let sideEast = 0.3
    private static let areaNorths = [sideNorth, middleNorth, sideNorth]
    private static let areaEasts = [-sideEast, 0, sideEast]
    /// Where the two beside the third stand from it, in metres north and
    /// east: close enough that no zoom a test searches at draws them apart.
    private static let besideThird: [(north: Double, east: Double)] = [(12, 0), (0, 12)]
    private static let metersPerDegree = 111_320.0

    /// One photograph per spot that has one, each its own Commons page so
    /// that a viewer and a save can tell them apart.
    private static func photos(
        at spots: [CLLocationCoordinate2D?],
        downloadingInto directory: URL
    ) async throws -> [CommonsPhoto] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var photos: [CommonsPhoto] = []
        for (index, spot) in spots.enumerated() {
            guard let coordinate = spot,
                  let data = await SeededPhotoFixture.encodedImage(
                      index: firstFrame + index,
                      size: frameSize
                  )
            else { continue }
            try Task.checkCancellation()
            let url = directory.appendingPathComponent("commons-seeded-\(index).jpeg", isDirectory: false)
            guard (try? data.write(to: url)) != nil else { continue }
            photos.append(
                CommonsPhoto(
                    pin: CommunityPhotoPin(capturedAt: SeededCommunityTransport.hikeDate, coordinate: coordinate),
                    fileURL: url,
                    credit: CommonsPhotoCredit(
                        author: authors[index],
                        license: HikePhotoLicense(
                            name: licenseName,
                            url: licenseURL,
                            sourceURL: filePage.appending(queryItems: [URLQueryItem(name: "seeded", value: "\(index)")])
                        )
                    )
                )
            )
        }
        return photos
    }
}

#endif
