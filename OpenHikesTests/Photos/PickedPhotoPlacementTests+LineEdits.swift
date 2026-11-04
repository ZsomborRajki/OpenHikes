//
//  PickedPhotoPlacementTests+LineEdits.swift
//  OpenHikesTests
//
//  A picker selection is placed one photograph at a time, each after a wait
//  for its bytes that can be a download, so the plan built when the picker
//  closed can outlive the line it was read from (#1280). It used to go on
//  placing the rest of the selection on that line. ``HikePhotoImport/addPicked``
//  is the step `attachPickedPhotos` runs per photograph, and the plan it is
//  handed is the one the next photograph starts from, so what is asserted
//  here is what that loop carries.
//
//  Split from ``PickedPhotoPlacementTests`` as an extension, because one test
//  type goes in a file and these share its fixtures.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

extension PickedPhotoPlacementTests {
    /// Bytes stamped with a time and position along the route, read off the
    /// main actor as every ImageIO read is.
    private static func stampedPhoto(atStep step: Double) async throws -> Data {
        let takenAt = PhotoDiscoveryFixture.date(atStep: step)
        return try await offMain {
            try #require(PhotoMetadataStamp.stamped(Self.sampleJPEG(), capturedAt: takenAt, coordinate: nil))
        }
    }

    @Test("a photo picked after the line moved goes on the line the hike has now", arguments: PhotoLineEdit.allCases)
    func placedOnTheLineTheHikeHasNow(edit: PhotoLineEdit) async throws {
        let sandbox = PhotoStoreSandbox()
        let log = WorkLog()
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)
        try context.save()
        var plan = await log.work.plan(from: HikePhotoSearchPlan.SourceRead(hike))
        try await edit.replaceLine(of: hike, with: PhotoDiscoveryFixture.movedRoute)

        var photos: [HikePhoto] = []
        for (asset, step) in [("first", 2.0), ("second", 5.0)] {
            let data = try await Self.stampedPhoto(atStep: step)
            photos.append(
                try #require(
                    await HikePhotoImport.addPicked(
                        data,
                        to: hike,
                        plan: &plan,
                        fallback: Self.graphSelection,
                        assetLocalIdentifier: asset,
                        store: sandbox.store,
                        work: log.work
                    )
                )
            )
        }

        #expect(PhotoDiscoveryFixture.pins(photos.map(\.latitude), stand: [2, 5], on: PhotoDiscoveryFixture.movedRoute))
        #expect(photos.map(\.matchEvidence) == [.time, .time])
        #expect(log.plansOnMainThread == [false, false], "the plan, then the one line it was replaced by, once")
        #expect(log.fetchesOnMainThread.allSatisfy { !$0 })
    }

    /// The tier a plan answers with no clock: the camera's own position,
    /// projected onto the line. It is the one that used to be refused for a
    /// camera standing on the line the hike has now.
    @Test("a photo the line moved under is snapped to the line the hike has now")
    func snappedToTheLineTheHikeHasNow() async throws {
        let sandbox = PhotoStoreSandbox()
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)
        try context.save()
        var plan = await PickedPhotoWork.standard.plan(from: HikePhotoSearchPlan.SourceRead(hike))
        try await PhotoLineEdit.received.replaceLine(of: hike, with: PhotoDiscoveryFixture.movedRoute)
        let camera = PhotoDiscoveryFixture.movedRoute[4].clCoordinate
        let aYearEarlier = PhotoDiscoveryFixture.date(atStep: -365.0 * 24 * 60)
        let data = try await offMain {
            try #require(
                PhotoMetadataStamp.stamped(Self.sampleJPEG(), capturedAt: aYearEarlier, coordinate: camera)
            )
        }

        let photo = try #require(
            await HikePhotoImport.addPicked(
                data,
                to: hike,
                plan: &plan,
                fallback: Self.graphSelection,
                assetLocalIdentifier: "snapped",
                store: sandbox.store
            )
        )

        #expect(photo.matchEvidence == .place)
        #expect(Self.meters(photo.coordinate, camera) < 1)
    }

    /// The price of asking is one read per photograph, never the plan's
    /// indexes: a line that has not moved is compared and left alone.
    @Test("a line that has not moved is read and not indexed again")
    func unmovedLineIsNotIndexedAgain() async throws {
        let sandbox = PhotoStoreSandbox()
        let log = WorkLog()
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)
        try context.save()
        var plan = await log.work.plan(from: HikePhotoSearchPlan.SourceRead(hike))
        let data = try await Self.stampedPhoto(atStep: 2)

        _ = await HikePhotoImport.addPicked(
            data,
            to: hike,
            plan: &plan,
            fallback: Self.graphSelection,
            assetLocalIdentifier: "first",
            store: sandbox.store,
            work: log.work
        )

        #expect(log.fetchesOnMainThread == [false, false], "read for the plan, then for the photo")
        #expect(log.plansOnMainThread == [false])
    }

    /// A place's own screen says where its picks belong, however the line
    /// moves, so there is nothing to read for one and no plan to replace.
    @Test("a pick filed under a place keeps to the place when the line moves")
    func pickUnderAPlaceIgnoresTheLine() async throws {
        let sandbox = PhotoStoreSandbox()
        let log = WorkLog()
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)
        let place = TrailPlace(
            latitude: Self.graphSelection.latitude,
            longitude: Self.graphSelection.longitude,
            name: "The hut"
        )
        hike.addPlace(place, in: context)
        try context.save()
        let controller = PhotoCaptureController()
        controller.attach(to: hike, place: place.id) { _ in Self.graphSelection }
        let selection = try #require(controller.currentSubject())
        var plan = await log.work.plan(from: selection.pickerSearchSource)
        try await PhotoLineEdit.received.replaceLine(of: hike, with: PhotoDiscoveryFixture.movedRoute)
        let data = try await Self.stampedPhoto(atStep: 2)

        let photo = try #require(
            await HikePhotoImport.addPicked(
                data,
                to: hike,
                plan: &plan,
                fallback: selection.coordinate,
                assetLocalIdentifier: "at-the-hut",
                placeID: place.id,
                store: sandbox.store,
                work: log.work
            )
        )

        #expect(plan == nil)
        #expect(log.fetchesOnMainThread.isEmpty)
        #expect(log.plansOnMainThread.isEmpty)
        #expect(photo.placeID == place.id)
        #expect(Self.meters(photo.coordinate, Self.graphSelection) < 1)
    }
}
