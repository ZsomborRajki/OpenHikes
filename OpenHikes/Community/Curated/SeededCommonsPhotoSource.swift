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

import Foundation
import OpenHikesData

#if DEBUG

/// A stand-in for Wikimedia Commons with three photographs on every route.
nonisolated struct SeededCommonsPhotoSource: CommonsPhotoSourcing {
    /// Who took the three, in walking order — the last names nobody.
    static let authors: [String?] = ["Anna Berger", "Lukas Moser", nil]
    /// What all three are shared under.
    static let licenceName = "CC BY-SA 4.0"

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
    private static let licenceURL = URL(string: "https://creativecommons.org/licenses/by-sa/4.0/")!
    private static let filePage = URL(string: "https://commons.wikimedia.org/wiki/File:Seeded_trail_photo.jpg")!
    // swiftlint:enable force_unwrapping

    @concurrent
    func photos(along route: [RouteCoordinate], downloadingInto directory: URL) async throws -> [CommonsPhoto] {
        guard route.count > 1 else { return [] }
        let profile = RouteProfile(route: route)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var photos: [CommonsPhoto] = []
        for (index, share) in Self.positions.enumerated() {
            guard let coordinate = profile.coordinate(atDistance: profile.totalDistanceMeters * share),
                  let data = await SeededPhotoFixture.encodedImage(
                      index: Self.firstFrame + index,
                      size: Self.frameSize
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
                        author: Self.authors[index],
                        licence: HikePhotoLicence(
                            name: Self.licenceName,
                            url: Self.licenceURL,
                            sourceURL: Self.filePage
                        )
                    )
                )
            )
        }
        return photos
    }
}

#endif
