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
//  clock could not place it (#1189). Asserted through the work seam rather
//  than a stopwatch, as ``PhotoDiscoveryControllerTests`` asserts Find
//  Photos': each step records the thread it ran on, and the caller is the
//  main actor itself, so a step that stays on its caller's executor fails.
//
//  Split from ``PickedPhotoPlacementTests`` as an extension, because one test
//  type goes in a file and these share its fixtures.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Synchronization
import Testing

extension PickedPhotoPlacementTests {
    /// Which threads each step of an import ran on, one entry per call.
    nonisolated final class WorkLog: Sendable {
        private let threads = Mutex<(plans: [Bool], placements: [Bool])>(([], []))

        var plansOnMainThread: [Bool] { threads.withLock(\.plans) }
        var placementsOnMainThread: [Bool] { threads.withLock(\.placements) }

        /// The real work, recording where each step ran before doing it.
        var work: PickedPhotoWork {
            PickedPhotoWork(
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
        let plan = await log.work.plan(from: hike.photoSearchSource)

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
