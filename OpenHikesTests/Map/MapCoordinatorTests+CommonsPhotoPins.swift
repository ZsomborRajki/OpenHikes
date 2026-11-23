//
//  MapCoordinatorTests+CommonsPhotoPins.swift
//  OpenHikesTests
//
//  The one way both surfaces put Commons photographs on a real `MKMapView`
//  (``MapView/Coordinator/applyCommonsPhotos(_:as:on:)``): each reads back
//  and takes down only its own class of pin, so the *Community* tab's and the
//  maker's stand side by side, the same photograph included, and an answer
//  that changed nothing but its order moves nothing on either.
//

import CoreLocation
import MapKit
@testable import OpenHikes
import OpenHikesData
import Testing

extension MapCoordinatorTests {
    /// Inside the region ``makeMap`` frames, a hundred metres apart.
    private enum PinCamera {
        static let latitude: Double = 37.3350
        static let longitude: Double = -122.0300
        static let step: Double = 0.001
        static let takenTimestamp: TimeInterval = 1_600_000_000
        static let takenAt = Date(timeIntervalSince1970: takenTimestamp)
    }

    private static func pinnedPhoto(_ index: Int, standing: Bool = true) -> CommonsPhoto {
        CommonsPhoto(
            pin: CommunityPhotoPin(
                capturedAt: PinCamera.takenAt,
                coordinate: standing
                    ? CLLocationCoordinate2D(
                        latitude: PinCamera.latitude + Double(index) * PinCamera.step,
                        longitude: PinCamera.longitude
                    )
                    : nil
            ),
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("pins-\(index).jpeg"),
            credit: CommonsPhotoCredit(
                author: nil,
                license: HikePhotoLicense(
                    name: "CC0",
                    url: nil,
                    sourceURL: URL(string: "https://commons.wikimedia.org/wiki/File:p\(index).jpg")
                        ?? URL(filePath: "/")
                )
            )
        )
    }

    /// The pins of one class on `map`, by identity: what moving nothing means.
    private static func drawn<Pin: CommonsPhotoAnnotation>(
        _ pin: Pin.Type,
        on map: MKMapView
    ) -> Set<ObjectIdentifier> {
        Set(map.annotations.compactMap { $0 as? Pin }.map(ObjectIdentifier.init))
    }

    @Test("each surface's photographs are its own: a pass over one, reordered or changed, leaves the other's")
    func commonsPhotoPinsStayApart() {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        // The second photograph on both surfaces at once.
        let community = [Self.pinnedPhoto(0), Self.pinnedPhoto(1)]
        let maker = [Self.pinnedPhoto(1), Self.pinnedPhoto(2)]

        coordinator.applyCommunityCommonsPhotos(community, on: map)
        coordinator.applyTrailDraftPhotos(maker, on: map)
        let communityPins = Self.drawn(CommunityCommonsPhotoAnnotation.self, on: map)
        let makerPins = Self.drawn(TrailDraftPhotoAnnotation.self, on: map)
        #expect(communityPins.count == 2)
        #expect(makerPins.count == 2, "the photograph on both is a pin on each")

        // The same answers in another order move nothing on either surface.
        coordinator.applyCommunityCommonsPhotos(community.reversed(), on: map)
        coordinator.applyTrailDraftPhotos(maker.reversed(), on: map)
        #expect(Self.drawn(CommunityCommonsPhotoAnnotation.self, on: map) == communityPins)
        #expect(Self.drawn(TrailDraftPhotoAnnotation.self, on: map) == makerPins)

        // A new answer on one surface replaces that surface's pins alone.
        coordinator.applyCommunityCommonsPhotos([Self.pinnedPhoto(3)], on: map)
        #expect(Self.drawn(TrailDraftPhotoAnnotation.self, on: map) == makerPins)
        let replaced = map.annotations.compactMap { $0 as? CommunityCommonsPhotoAnnotation }
        #expect(replaced.map(\.photo) == [Self.pinnedPhoto(3)])

        coordinator.applyTrailDraftPhotos([], on: map)
        #expect(!map.annotations.contains { $0 is TrailDraftPhotoAnnotation })
        #expect(Self.drawn(CommunityCommonsPhotoAnnotation.self, on: map) == Set(replaced.map(ObjectIdentifier.init)))
        #endif
    }

    @Test("a photograph with no place to stand is no pin on either surface")
    func aPhotographWithNoPlaceIsNoPin() {
        let nowhere = Self.pinnedPhoto(0, standing: false)

        #expect(CommunityCommonsPhotoAnnotation(photo: nowhere) == nil)
        #expect(TrailDraftPhotoAnnotation(photo: nowhere) == nil)
    }
}
