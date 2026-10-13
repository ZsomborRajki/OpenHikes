//
//  MapCoordinatorTests+TrailDraftPhotos.swift
//  OpenHikesTests
//
//  The trail maker's Commons photographs, against a real `MKMapView`: drawn
//  as thumbnails, left alone by a pass that changed nothing, and taken down.
//  What a search finds and what the chip does are ``TrailDraftPhotosTests``
//  and ``TrailDraftPhotoControllerTests``.
//

import CoreLocation
import MapKit
@testable import OpenHikes
import OpenHikesData
import Testing

extension MapCoordinatorTests {
    /// Inside the region ``makeMap`` frames, a hundred metres apart.
    private enum Camera {
        static let latitude: Double = 37.3350
        static let longitude: Double = -122.0300
        static let step: Double = 0.001
        static let takenTimestamp: TimeInterval = 1_600_000_000
        static let takenAt = Date(timeIntervalSince1970: takenTimestamp)
    }

    private static func commonsPhoto(_ index: Int) -> CommonsPhoto {
        CommonsPhoto(
            pin: CommunityPhotoPin(
                capturedAt: Camera.takenAt,
                coordinate: CLLocationCoordinate2D(
                    latitude: Camera.latitude + Double(index) * Camera.step,
                    longitude: Camera.longitude
                )
            ),
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("commons-\(index).jpeg"),
            credit: CommonsPhotoCredit(
                author: "Hiker \(index)",
                licence: HikePhotoLicence(
                    name: "CC0",
                    url: nil,
                    sourceURL: URL(string: "https://commons.wikimedia.org/wiki/File:\(index).jpg")
                        ?? URL(filePath: "/")
                )
            )
        )
    }

    @Test("the maker's photographs are drawn as thumbnails, once, and taken down")
    func trailDraftPhotosAreDrawn() {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let photos = [Self.commonsPhoto(0), Self.commonsPhoto(1)]

        coordinator.applyTrailDraftPhotos(photos, on: map)
        // `annotations` is in no particular order, so neither is this.
        let drawn = map.annotations.compactMap { $0 as? TrailDraftPhotoAnnotation }
        #expect(drawn.count == photos.count)
        #expect(Set(drawn.map(\.photo)) == Set(photos))

        // The same photographs again move nothing — an unrelated pass over the
        // draft must not re-drop every thumbnail — and nor does the same set
        // in another order, which is how the map hands them back.
        coordinator.applyTrailDraftPhotos(photos, on: map)
        coordinator.applyTrailDraftPhotos(photos.reversed(), on: map)
        let again = map.annotations.compactMap { $0 as? TrailDraftPhotoAnnotation }
        #expect(again.count == 2)
        #expect(Set(again.map(ObjectIdentifier.init)) == Set(drawn.map(ObjectIdentifier.init)))

        let first = drawn.first { $0.photo == photos[0] }
        let view = first.flatMap { coordinator.makerAnnotationView(for: $0, on: map) }
        #expect(view is TrailDraftPhotoAnnotationView)
        #expect(view?.accessibilityLabel == "Photo by Hiker 0 · CC0")

        coordinator.applyTrailDraftPhotos([], on: map)
        #expect(!map.annotations.contains { $0 is TrailDraftPhotoAnnotation })
        #endif
    }
}
