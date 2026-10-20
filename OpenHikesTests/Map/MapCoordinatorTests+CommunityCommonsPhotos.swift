//
//  MapCoordinatorTests+CommunityCommonsPhotos.swift
//  OpenHikesTests
//
//  The *Community* tab's Commons photographs, against a real `MKMapView`:
//  drawn as thumbnails beside the maker's without touching them, grouped when
//  they would overlap, and opened by a tap. What a search finds is
//  ``CommunityCommonsPhotosTests``.
//
//  The group is built here as MapKit builds one, from the drawn annotations:
//  a map that is not on screen lays nothing out, so it never collides two
//  thumbnails itself.
//

import CoreLocation
import MapKit
@testable import OpenHikes
import OpenHikesData
import Testing

extension MapCoordinatorTests {
    /// Inside the region ``makeMap`` frames, a hundred metres apart.
    private enum CommunityCamera {
        static let latitude: Double = 37.3350
        static let longitude: Double = -122.0300
        static let step: Double = 0.001
        static let takenTimestamp: TimeInterval = 1_600_000_000
        static let takenAt = Date(timeIntervalSince1970: takenTimestamp)
        /// A year after ``takenAt``.
        static let laterTimestamp: TimeInterval = 1_631_536_000
        static let takenLater = Date(timeIntervalSince1970: laterTimestamp)
    }

    private static func communityPhoto(_ index: Int, takenAt: Date = CommunityCamera.takenAt) -> CommonsPhoto {
        CommonsPhoto(
            pin: CommunityPhotoPin(
                capturedAt: takenAt,
                coordinate: CLLocationCoordinate2D(
                    latitude: CommunityCamera.latitude + Double(index) * CommunityCamera.step,
                    longitude: CommunityCamera.longitude
                )
            ),
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("community-\(index).jpeg"),
            credit: CommonsPhotoCredit(
                author: nil,
                license: HikePhotoLicense(
                    name: "CC0",
                    url: nil,
                    sourceURL: URL(string: "https://commons.wikimedia.org/wiki/File:c\(index).jpg")
                        ?? URL(filePath: "/")
                )
            )
        )
    }

    @Test("the tab's photographs are drawn apart from the maker's, and a tap opens one")
    func communityCommonsPhotosAreDrawn() {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        // After the map, which points the coordinator at the view's own; and
        // kept alive to the end, because the coordinator holds it weakly.
        let browser = CommunityBrowser(transport: nil, blockList: .scratch())
        coordinator.community = browser
        defer { withExtendedLifetime(browser) { detach(map) } }
        var opened: [CommonsPhoto] = []
        browser.onOpenCommonsPhoto { opened.append($0) }
        let photos = [Self.communityPhoto(0), Self.communityPhoto(1)]

        coordinator.applyCommunityCommonsPhotos(photos, on: map)
        coordinator.applyTrailDraftPhotos([], on: map)

        let drawn = map.annotations.compactMap { $0 as? CommunityCommonsPhotoAnnotation }
        #expect(Set(drawn.map(\.photo)) == Set(photos), "the maker's empty pass took none of them")

        let first = drawn.first { $0.photo == photos[0] }
        let view = first.flatMap { coordinator.ownedAnnotationView(for: $0, on: map) }
        #expect(view is CommonsPhotoPinView)
        #expect(view?.accessibilityIdentifier == "community-commons-photo-pin")
        #expect(
            view?.clusteringIdentifier == CommunityCommonsPhotoAnnotation.clusteringIdentifier,
            "the tab's thumbnails are grouped when they would overlap"
        )

        if let view {
            #expect(coordinator.selectOwnedAnnotation(view, on: map))
        }
        #expect(opened == [photos[0]])

        coordinator.applyCommunityCommonsPhotos([], on: map)
        #expect(!map.annotations.contains { $0 is CommunityCommonsPhotoAnnotation })
        #endif
    }

    @Test("a group of the tab's photographs is one thumbnail with its count, and a tap opens it newest first")
    func communityCommonsPhotoGroupsAreDrawn() {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        let browser = CommunityBrowser(transport: nil, blockList: .scratch())
        coordinator.community = browser
        defer { withExtendedLifetime(browser) { detach(map) } }
        var opened: [[CommonsPhoto]] = []
        browser.onOpenCommonsPhotos { opened.append($0) }
        // The middle one the newest; the page settles the other two, which
        // were taken at the same moment.
        let photos = [
            Self.communityPhoto(0),
            Self.communityPhoto(1, takenAt: CommunityCamera.takenLater),
            Self.communityPhoto(2),
        ]
        coordinator.applyCommunityCommonsPhotos(photos, on: map)
        let group = MKClusterAnnotation(
            memberAnnotations: map.annotations.compactMap { $0 as? CommunityCommonsPhotoAnnotation }
        )

        let view = coordinator.ownedAnnotationView(for: group, on: map)
        #expect(view is CommonsPhotoPinView)
        #expect(view?.accessibilityIdentifier == "community-commons-photo-group")
        #expect(view?.accessibilityLabel == "3 photos")

        if let view {
            #expect(coordinator.selectOwnedAnnotation(view, on: map))
        }
        #expect(opened == [[photos[1], photos[0], photos[2]]])
        #endif
    }
}
