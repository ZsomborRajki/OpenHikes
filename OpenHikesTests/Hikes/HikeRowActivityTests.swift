//
//  HikeRowActivityTests.swift
//  OpenHikesTests
//
//  The hikes list decides which row is under way, and the row reads the
//  phase its badge names (`HikeRow.swift`). A pause, a resume or a stop
//  Auto-Pause calls moves the phase and not the hike under way, so it must
//  wake the row's read and leave the list's alone: the list is the costliest
//  body in the app, and it re-ran for each of them to change one capsule.
//
//  Counted the way `RenderIsolationTests` counts, with both sides asserted:
//  the row's read is told of the pause, so the list's zero beside it is not
//  a counter that saw nothing.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@MainActor
@Suite("Hike row activity")
struct HikeRowActivityTests {
    private let container: ModelContainer
    private let directory: URL

    init() throws {
        container = try Fixture.modelContainer()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hike-row-activity-\(UUID().uuidString)", isDirectory: true)
    }

    private func recorder() -> HikeRecorder {
        HikeRecorder(
            container: container,
            source: StubRecordingLocationSource(),
            journalDirectory: directory,
            journalFlushDelay: .zero,
            automaticallyRecovers: false
        )
    }

    @Test("a recording's pause re-badges its row and leaves the list's choice alone")
    func recordingPauseWakesOnlyTheRow() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = recorder()
        let walk = TrailWalkSession(context: ModelContext(container))
        await recorder.start()
        let hike = try #require(recorder.currentHike)
        let activity = try #require(HikeRowActivity(hike, recorder: recorder, walk: walk))
        #expect(activity.status(of: hike).title == "Finding GPS")

        let list = ObservationCounter { _ = HikeRowActivity(hike, recorder: recorder, walk: walk) }
        let row = ObservationCounter { _ = activity.status(of: hike) }
        await list.settle()

        recorder.pause()
        await row.settle()

        #expect(activity.status(of: hike).title == "Paused")
        #expect(row.count >= 1, "the row is told")
        #expect(list.count == 0, "the list is not")
    }

    @Test("a walk's pause re-badges its row and leaves the list's choice alone")
    func walkPauseWakesOnlyTheRow() async throws {
        let context = ModelContext(container)
        let walk = TrailWalkSession(context: context)
        let recorder = recorder()
        let hike = Fixture.hike(in: context)
        let profile = RouteProfile(route: hike.route)
        // Far enough along, in enough fixes, to start the walk.
        for index in 0...2 {
            walk.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[index])
        }
        let activity = try #require(HikeRowActivity(hike, recorder: recorder, walk: walk))
        #expect(activity.status(of: hike).title == "Active")

        let list = ObservationCounter { _ = HikeRowActivity(hike, recorder: recorder, walk: walk) }
        let row = ObservationCounter { _ = activity.status(of: hike) }
        await list.settle()

        walk.pause()
        await row.settle()

        #expect(activity.status(of: hike).title == "Paused")
        #expect(row.count == 1, "the row is told")
        #expect(list.count == 0, "the list is not")
    }

    @Test("a hike nothing is under way on has no activity")
    func idleHikeHasNone() {
        let context = ModelContext(container)
        let hike = Fixture.hike(in: context)
        #expect(HikeRowActivity(hike, recorder: recorder(), walk: TrailWalkSession(context: context)) == nil)
    }
}
