//
//  CommunityUploadQueueingTests+Support.swift
//  OpenHikesTests
//
//  The hikes, listings and stubs ``CommunityUploadQueueingTests`` is built
//  from.
//
//  An extension of the suite rather than a type of its own, because the tests
//  read these as their own and a second type would have to be handed round.
//  What separates this file is length alone: `type_body_length` counts a
//  suite's own body and not its extensions, so the fixtures live here and the
//  file with the assertions stays under the limit.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData

extension CommunityUploadQueueingTests {
    /// Named rather than inline because `no_magic_numbers` skips a `@Test`
    /// body and a suite's own, and this is an extension of one.
    private static let firstPhotoTime: TimeInterval = 1_700_000_000
    private static let photoSpacing: TimeInterval = 60
    private static let photoLatitude = 47.6
    private static let photoLatitudeStep = 0.0001
    private static let photoLongitude = 12.8
    private static let listingLatitude = 47.7
    private static let listingLongitude = 18.9

    /// The trail a contribution in these tests is aimed at.
    static let target = CommunityPhotoTarget(
        listingID: "listing-1",
        title: "Almbachklamm",
        authorName: "Anna"
    )

    /// Attaches `count` photo rows whose pixels are on this device.
    ///
    /// ``CommunityPhotoPublisherTests``'s helper, and the same one for the same
    /// reason: a row with no file behind it is a photograph the upload drops,
    /// so it is never sent and can never be marked as sent.
    func addStoredPhotos(_ count: Int, to hike: Hike, in sandbox: PhotoStoreSandbox) async {
        let data = PhotoDiscoveryFixture.sampleImageData()
        let store = sandbox.store
        for index in 0..<count {
            let captured = Date(
                timeIntervalSince1970: Self.firstPhotoTime + Double(index) * Self.photoSpacing
            )
            let latitude = Self.photoLatitude + Double(index) * Self.photoLatitudeStep
            let longitude = Self.photoLongitude
            guard let photo = await Task.detached(priority: .userInitiated, operation: {
                store.store(
                    data,
                    capturedAt: captured,
                    coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                )
            }).value else { continue }
            hike.photos.append(photo)
        }
    }

    /// The listing a reviewer's approval would have made for `submissionID`.
    func listing(id: String, submissionID: String) -> CommunityListing {
        CommunityListing(
            id: id,
            submissionID: submissionID,
            title: "Pilis Ridge",
            authorName: "Anna",
            authorID: "author-1",
            hikeDate: .now,
            distanceMeters: 1000,
            photoCount: 0,
            latitude: Self.listingLatitude,
            longitude: Self.listingLongitude,
            publishedAt: .now
        )
    }

    /// A stub whose upload lands and whose first notice does not.
    ///
    /// `script` is one answer per notice write, across the upload's own notice
    /// and every repair after it; see ``StubCommunityTransport/queueingScript``.
    func stubFailingTheNotice(
        submissionID: String,
        script: [CommunityFailure?] = [.unreachable]
    ) -> StubCommunityTransport {
        let transport = StubCommunityTransport()
        transport.submissionResult = .success(submissionID)
        transport.queueingScript = script
        return transport
    }
}
