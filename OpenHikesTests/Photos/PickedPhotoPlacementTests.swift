//
//  PickedPhotoPlacementTests.swift
//  OpenHikesTests
//
//  Where a photograph from the system picker is pinned, in three tiers: where
//  "Find Photos of This Hike" would have put it whenever that can place it;
//  where its own camera was, when the clock cannot speak but the GPS is on the
//  trail; and at the elevation graph's selection only when neither can.
//
//  The fallback cases are the half worth spelling out, because each is a way a
//  coarse rule would pin a picture somewhere confidently wrong — a photo with
//  no position in it, one the camera put kilometres from the trail, and one
//  picked on a place's own screen, which says where it belongs by being there.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

#if canImport(UIKit)
import UIKit
#endif

@Suite("Picked photo placement")
struct PickedPhotoPlacementTests {
    /// Where the graph's selection stands: well clear of anywhere a match
    /// could land, so a test can tell the two apart by position alone.
    private static let graphSelection = CLLocationCoordinate2D(latitude: 47.6000, longitude: 12.8000)
    private static let now = Date(timeIntervalSince1970: 1_760_000_000)

    private static var recordedPlan: HikePhotoSearchPlan {
        HikePhotoSearchPlan(
            timeline: HikePhotoTimeline(route: PhotoDiscoveryFixture.route),
            walks: [],
            route: PhotoDiscoveryFixture.route
        )
    }

    private static func metres(_ from: CLLocationCoordinate2D?, _ to: CLLocationCoordinate2D) -> Double {
        guard let from else { return .infinity }
        return RouteGeometry.distanceMeters(from: from, to: to)
    }

    private static func resolve(
        takenAtStep step: Double?,
        camera: CLLocationCoordinate2D? = nil,
        plan: HikePhotoSearchPlan? = recordedPlan
    ) -> PickedPhotoPlacement {
        PickedPhotoPlacement.resolve(
            PickedPhotoMetadata(
                capturedAt: step.map(PhotoDiscoveryFixture.date(atStep:)),
                coordinate: camera
            ),
            plan: plan,
            fallback: graphSelection,
            now: now
        )
    }

    // MARK: - Placed like Find Photos

    /// Location off for the camera, but taken during the recording: the clock
    /// alone places it, exactly as a library scan would.
    @Test("a photo taken during the recording is placed by its time")
    func placedByTime() {
        let placement = Self.resolve(takenAtStep: 4.5)

        #expect(placement.evidence == .time)
        #expect(Self.metres(placement.coordinate, PhotoDiscoveryFixture.coordinate(atStep: 4.5)) < 1)
        #expect(placement.capturedAt == PhotoDiscoveryFixture.date(atStep: 4.5))
    }

    @Test("a photo whose camera agrees with the recording is placed by both")
    func placedByTimeAndPlace() {
        let placement = Self.resolve(
            takenAtStep: 3,
            camera: PhotoDiscoveryFixture.coordinate(atStep: 3)
        )

        #expect(placement.evidence == .timeAndPlace)
        #expect(Self.metres(placement.coordinate, PhotoDiscoveryFixture.coordinate(atStep: 3)) < 1)
    }

    /// An imported trail has no clock of its own; a walk along it is what
    /// places the picture, and the camera's position outranks the walk's even
    /// progress.
    @Test("a photo taken while walking an imported trail is placed by the walk")
    func placedByWalk() throws {
        let profile = RouteProfile(route: PhotoDiscoveryFixture.unstampedRoute)
        let walk = try #require(
            HikeWalkPhotoTimeline(
                startedAt: PhotoDiscoveryFixture.date(atStep: 0),
                endedAt: PhotoDiscoveryFixture.date(atStep: 9),
                coverage: TrailWalkCoverage(
                    intervals: [0, profile.totalDistanceMeters],
                    furthestDistanceMeters: profile.totalDistanceMeters
                )
            )
        )
        let plan = HikePhotoSearchPlan(
            timeline: nil,
            walks: [walk],
            route: PhotoDiscoveryFixture.unstampedRoute
        )
        let takenAt = PhotoDiscoveryFixture.coordinate(atStep: 2)

        let placement = Self.resolve(takenAtStep: 6, camera: takenAt, plan: plan)

        #expect(placement.evidence == .place)
        #expect(Self.metres(placement.coordinate, takenAt) < 1)
    }

    // MARK: - Placed by the camera when the clock cannot

    /// Photographed on this trail last year, imported while looking at this
    /// walk: the clock is a year out, and the camera puts it on the route.
    @Test("a photo from another day whose GPS is on the trail is snapped there")
    func anotherDayOnTheTrailIsSnapped() {
        let lastYear = -365.0 * 24 * 60
        let takenAt = PhotoDiscoveryFixture.coordinate(atStep: 7)

        let placement = Self.resolve(takenAtStep: lastYear, camera: takenAt)

        #expect(placement.evidence == .place)
        #expect(Self.metres(placement.coordinate, takenAt) < 1)
        #expect(placement.capturedAt == PhotoDiscoveryFixture.date(atStep: lastYear))
    }

    @Test("a photo with no capture time whose GPS is on the trail is snapped there")
    func noTimeOnTheTrailIsSnapped() {
        let takenAt = PhotoDiscoveryFixture.coordinate(atStep: 2)

        let placement = Self.resolve(takenAtStep: nil, camera: takenAt)

        #expect(placement.evidence == .place)
        #expect(Self.metres(placement.coordinate, takenAt) < 1)
        #expect(placement.capturedAt == Self.now)
    }

    /// Snapped onto the route rather than pinned where the camera stood: a
    /// fix a few tens of metres off to the side is still this point of the
    /// trail, and the map draws the pin on the line.
    @Test("a photo a little off the trail is snapped onto it")
    func nearTheTrailIsSnappedOntoIt() {
        let beside = CLLocationCoordinate2D(
            latitude: PhotoDiscoveryFixture.latitude + PhotoDiscoveryFixture.latitudeStep * 3,
            longitude: PhotoDiscoveryFixture.longitude + 0.0005
        )

        let placement = Self.resolve(takenAtStep: nil, camera: beside)

        #expect(placement.evidence == .place)
        #expect(Self.metres(placement.coordinate, PhotoDiscoveryFixture.coordinate(atStep: 3)) < 1)
    }

    /// A trail never walked with this app has no clock at all; the route is
    /// still there to snap onto.
    @Test("a photo on a trail never walked is snapped by its GPS")
    func unwalkedTrailSnapsByPlace() {
        let plan = HikePhotoSearchPlan(timeline: nil, walks: [], route: PhotoDiscoveryFixture.unstampedRoute)
        let takenAt = PhotoDiscoveryFixture.coordinate(atStep: 5)

        let placement = Self.resolve(takenAtStep: 4, camera: takenAt, plan: plan)

        #expect(placement.evidence == .place)
        #expect(Self.metres(placement.coordinate, takenAt) < 1)
    }

    // MARK: - Falling back to the graph selection

    /// No clock and no position: the hiker's own pointing is the best
    /// evidence there is. It is dated by its import, which is what the picker
    /// always did.
    @Test("a photo with neither a capture time nor GPS goes to the graph selection")
    func noTimeFallsBack() {
        let placement = Self.resolve(takenAtStep: nil)

        #expect(placement.evidence == nil)
        #expect(Self.metres(placement.coordinate, Self.graphSelection) < 1)
        #expect(placement.capturedAt == Self.now)
    }

    /// Another day, and no position to snap by. It keeps its own date, so the
    /// gallery orders it by when it was taken.
    @Test("a photo from another day with no GPS goes to the graph selection with its own date")
    func outsideTheWalkFallsBack() {
        let dayBefore = -24.0 * 60
        let placement = Self.resolve(takenAtStep: dayBefore)

        #expect(placement.evidence == nil)
        #expect(Self.metres(placement.coordinate, Self.graphSelection) < 1)
        #expect(placement.capturedAt == PhotoDiscoveryFixture.date(atStep: dayBefore))
    }

    /// The clock says it belongs and the camera says it was taken kilometres
    /// away — the receipt photographed in the car park. A library scan refuses
    /// it, and the picker does not snap it onto a trail it was never on.
    @Test(
        "a photo the camera puts far off the trail goes to the graph selection",
        arguments: [4.0, -365.0 * 24 * 60]
    )
    func farFromTheTrailFallsBack(step: Double) {
        let elsewhere = CLLocationCoordinate2D(
            latitude: PhotoDiscoveryFixture.latitude + 0.05,
            longitude: PhotoDiscoveryFixture.longitude
        )

        let placement = Self.resolve(takenAtStep: step, camera: elsewhere)

        #expect(placement.evidence == nil)
        #expect(Self.metres(placement.coordinate, Self.graphSelection) < 1)
    }

    /// A trail never walked with this app, and a photo with no position.
    @Test("a trail with nothing to search and a photo with no GPS goes to the graph selection")
    func emptyPlanFallsBack() {
        let plan = HikePhotoSearchPlan(timeline: nil, walks: [], route: PhotoDiscoveryFixture.unstampedRoute)

        let placement = Self.resolve(takenAtStep: 4, plan: plan)

        #expect(placement.evidence == nil)
        #expect(Self.metres(placement.coordinate, Self.graphSelection) < 1)
    }

    /// Picked on a place's own screen: the place is where it belongs, however
    /// well its clock would have matched the walk.
    @Test("a photo filed under a place stays at the place")
    func placeFilingIsNotMatched() {
        let placement = Self.resolve(
            takenAtStep: 4.5,
            camera: PhotoDiscoveryFixture.coordinate(atStep: 4.5),
            plan: nil
        )

        #expect(placement.evidence == nil)
        #expect(Self.metres(placement.coordinate, Self.graphSelection) < 1)
    }

    // MARK: - Through the import

    /// The whole path, from bytes to a stored photo: the EXIF is read, the
    /// walk places it, and what lands on the hike says so.
    @Test("a picked photo from the recording is stored where the walk puts it")
    func importStoresTheMatch() async throws {
        let sandbox = PhotoStoreSandbox()
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)
        let takenAt = PhotoDiscoveryFixture.date(atStep: 5)
        let data = try await offMain {
            try #require(
                PhotoMetadataStamp.stamped(
                    Self.sampleJPEG(),
                    capturedAt: takenAt,
                    coordinate: PhotoDiscoveryFixture.coordinate(atStep: 5)
                )
            )
        }

        let photo = try #require(
            await HikePhotoImport.addPicked(
                data,
                to: hike,
                plan: hike.photoSearchPlan,
                fallback: Self.graphSelection,
                assetLocalIdentifier: "picked-asset",
                store: sandbox.store
            )
        )

        #expect(hike.photos.map(\.id) == [photo.id])
        #expect(photo.matchEvidence == .timeAndPlace)
        #expect(photo.capturedAt == takenAt)
        #expect(photo.assetLocalIdentifier == "picked-asset")
        #expect(Self.metres(photo.coordinate, PhotoDiscoveryFixture.coordinate(atStep: 5)) < 1)
    }

    @Test("a picked photo with no metadata is stored at the graph selection")
    func importFallsBack() async throws {
        let sandbox = PhotoStoreSandbox()
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)

        let photo = try #require(
            await HikePhotoImport.addPicked(
                PhotoDiscoveryFixture.sampleImageData(),
                to: hike,
                plan: hike.photoSearchPlan,
                fallback: Self.graphSelection,
                assetLocalIdentifier: "bare-asset",
                store: sandbox.store
            )
        )

        #expect(photo.matchEvidence == nil)
        #expect(Self.metres(photo.coordinate, Self.graphSelection) < 1)
    }

    nonisolated private static func sampleJPEG() -> Data {
        #if canImport(UIKit)
        let size = CGSize(width: 8, height: 8)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.9) ?? Data()
        #else
        return Data()
        #endif
    }
}
