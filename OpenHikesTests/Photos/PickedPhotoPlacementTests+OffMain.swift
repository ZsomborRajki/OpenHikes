//
//  PickedPhotoPlacementTests+OffMain.swift
//  OpenHikesTests
//
//  Where a picker selection's route-sized work runs.
//
//  The picker built its selection's plan — the route's timeline, its measured
//  legs and a whole ``RouteProfile`` — synchronously in the picker's
//  completion, and placed each photograph on the main actor once its metadata
//  read came back, projecting the camera onto the whole route whenever the
//  clock could not place it (#1189). It then read the hike on the main actor
//  as the picker closed, decoding and hashing the route before the hop
//  (#1215). Asserted through the work seam rather than a stopwatch, as
//  ``PhotoDiscoveryControllerTests`` asserts Find Photos': each step records
//  the thread it ran on, and the caller is the main actor itself, so a step
//  that stays on its caller's executor fails.
//
//  Split from ``PickedPhotoPlacementTests`` as an extension, because one test
//  type goes in a file and these share its fixtures.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Synchronization
import Testing

extension PickedPhotoPlacementTests {
    /// Which threads each step of an import ran on, one entry per call.
    nonisolated final class WorkLog: Sendable {
        private let threads = Mutex<(fetches: [Bool], plans: [Bool], placements: [Bool])>(([], [], []))

        /// One entry per hike fetched from the store, which only a saved hike
        /// is — see ``HikePhotoSearchPlan/SourceRead``.
        var fetchesOnMainThread: [Bool] { threads.withLock(\.fetches) }
        var plansOnMainThread: [Bool] { threads.withLock(\.plans) }
        var placementsOnMainThread: [Bool] { threads.withLock(\.placements) }

        /// The real work, recording where each step ran before doing it.
        var work: PickedPhotoWork {
            PickedPhotoWork(
                fetchHike: { context, id in
                    self.threads.withLock { $0.fetches.append(Thread.isMainThread) }
                    return try PickedPhotoWork.standard.fetchHike(context, id)
                },
                buildPlan: { source in
                    self.threads.withLock { $0.plans.append(Thread.isMainThread) }
                    return PickedPhotoWork.standard.buildPlan(source)
                },
                place: { metadata, plan, fallback in
                    self.threads.withLock { $0.placements.append(Thread.isMainThread) }
                    return PickedPhotoWork.standard.place(metadata, plan, fallback)
                }
            )
        }
    }

    /// Where a selection is filed when the picker closes, as
    /// `attachPickedPhotos` reads it: the claim in force, made the way a
    /// hike's screen makes one, or a place's screen when `place` is set.
    private static func selection(filedOn hike: Hike, place: UUID? = nil) throws -> PhotoCaptureController.Filing {
        let controller = PhotoCaptureController()
        controller.attach(to: hike, place: place) { _ in graphSelection }
        return try #require(controller.currentSubject())
    }

    /// An unstamped route with no walks has nothing for a library scan to
    /// search, so the profile is there only because the picker asked for it.
    @Test("a selection's plan is built off the main thread, profile included")
    func selectionPlanLeavesTheMainThread() async throws {
        // `pthread_main_np` rather than `Thread.isMainThread`, which Swift
        // makes unavailable from an `async` context.
        #expect(pthread_main_np() != 0, "the bug needs a main-actor caller to reproduce")
        let log = WorkLog()
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.unstampedRoute)
        let selection = try Self.selection(filedOn: hike)

        let plan = try #require(await log.work.plan(from: selection.pickerSearchSource))

        #expect(log.plansOnMainThread == [false])
        #expect(plan.isEmpty)
        #expect(plan.profile != nil)
    }

    /// The selection's source was read on the main actor as the picker
    /// closed: the route decoded on first access and, with a walk along it,
    /// hashed again to tell which walks are along its line (#1215). A saved
    /// hike is read in a context of the import's own instead, to the plan
    /// the same hike read on the main actor builds — the walk along the line
    /// in it, and the walk along a line since redrawn left out.
    @Test("a saved hike's selection is read off the main thread, to the same plan")
    func savedSelectionIsReadOffTheMainThread() async throws {
        #expect(pthread_main_np() != 0, "the bug needs a main-actor caller to reproduce")
        let log = WorkLog()
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)
        let length = RouteProfile(route: PhotoDiscoveryFixture.route).totalDistanceMeters
        let aDayLater = 24.0 * 60
        for revision in [PhotoDiscoveryFixture.routeRevision, "a line since redrawn"] {
            let walk = PhotoDiscoveryFixture.walk(
                hikeID: hike.id,
                fromStep: aDayLater,
                toStep: aDayLater + 9,
                covering: 0...length,
                routeDistanceMeters: length,
                routeRevision: revision
            )
            context.insert(walk)
            walk.hike = hike
        }
        try context.save()
        let selection = try Self.selection(filedOn: hike)

        let plan = try #require(await log.work.plan(from: selection.pickerSearchSource))
        let readOnTheMainActor = HikePhotoSearchPlan(source: hike.photoSearchSource, profilesRoute: true)

        #expect(log.fetchesOnMainThread == [false])
        #expect(log.plansOnMainThread == [false])
        #expect(plan.route == readOnTheMainActor.route)
        #expect(plan.walks == readOnTheMainActor.walks)
        #expect(plan.walks.count == 1)
        #expect(plan.timeline?.searchWindow == readOnTheMainActor.timeline?.searchWindow)
        #expect(plan.profile?.totalDistanceMeters == readOnTheMainActor.profile?.totalDistanceMeters)
    }

    /// A place's own screen is where its picks belong, so a selection made
    /// there reads nothing off the hike and builds no plan — not even on a
    /// recorded route, which a selection on the hike's own screen would
    /// index and match against.
    @Test("a selection filed under a place indexes nothing")
    func placeSelectionBuildsNoPlan() async throws {
        let log = WorkLog()
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)
        let selection = try Self.selection(filedOn: hike, place: UUID())

        let plan = await log.work.plan(from: selection.pickerSearchSource)

        #expect(plan == nil)
        #expect(log.plansOnMainThread.isEmpty)
    }

    /// Both tiers the plan answers: a photo the walk's clock places, and one
    /// from a year earlier that only its camera's position on the line can.
    @Test(
        "a picked photo is placed off the main thread, where it was placed before",
        arguments: [(5.0, PhotoMatchEvidence.timeAndPlace), (-365.0 * 24 * 60, .place)]
    )
    func placementLeavesTheMainThread(step: Double, evidence: PhotoMatchEvidence) async throws {
        #expect(pthread_main_np() != 0, "the bug needs a main-actor caller to reproduce")
        let sandbox = PhotoStoreSandbox()
        let log = WorkLog()
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)
        let takenAt = PhotoDiscoveryFixture.date(atStep: step)
        let data = try await offMain {
            try #require(
                PhotoMetadataStamp.stamped(
                    Self.sampleJPEG(),
                    capturedAt: takenAt,
                    coordinate: PhotoDiscoveryFixture.coordinate(atStep: 5)
                )
            )
        }
        let plan = await log.work.plan(from: HikePhotoSearchPlan.SourceRead(hike))

        let photo = try #require(
            await HikePhotoImport.addPicked(
                data,
                to: hike,
                plan: plan,
                fallback: Self.graphSelection,
                assetLocalIdentifier: "picked-asset",
                store: sandbox.store,
                work: log.work
            )
        )

        #expect(log.placementsOnMainThread == [false])
        #expect(photo.matchEvidence == evidence)
        #expect(photo.capturedAt == takenAt)
        #expect(Self.meters(photo.coordinate, PhotoDiscoveryFixture.coordinate(atStep: 5)) < 1)
    }
}
