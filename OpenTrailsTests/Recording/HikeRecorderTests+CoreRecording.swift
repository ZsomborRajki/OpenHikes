//
//  HikeRecorderTests.swift
//  OpenTrailsTests
//

import CoreLocation
import Foundation
@testable import OpenTrails
import OpenTrailsShared
import SwiftData
import Testing

private final class StubRecordingLocationSource: RecordingLocationSource {

  extension HikeRecorderTests {

    @Test("Start creates one draft and Stop finalizes that same hike")
    func startCreatesDraftAndStopFinalizesIt() async throws {
      let recorder = makeRecorder()
      await recorder.start()
      #expect(source.startCount == 1)
      let draft = try #require(recorder.currentHike)
      #expect(draft.isRecording)
      #expect(draft.route.isEmpty)
      #expect(try context.fetch(FetchDescriptor<Hike>()).count == 1)

      source.deliver(fix(latitude: 47.63))
      await settleDelegateHop()
      clock.advance(by: 10)
      source.deliver(fix(latitude: 47.6302))
      await settleDelegateHop()

      #expect(
        draft.route.isEmpty,
        "the durable row exists, but the live trace must not rewrite SwiftData per fix"
      )
      #expect(recorder.stats.pointCount == 2)

      let hike = try savedHike(from: await recorder.stop())

      #expect(try context.fetch(FetchDescriptor<Hike>()).count == 1)
      #expect(hike.id == draft.id)
      #expect(!hike.isRecording)
      #expect(hike.route.count == 2)
      #expect(
        hike.rawRoute.isEmpty,
        "with no matcher yet the route is the raw trace; a second copy is pure cost"
      )
      #expect(hike.distanceMeters > 20)
      #expect(recorder.phase == .idle)
    }

    @Test("the finalized hike stays recorder-owned until cleanup finishes")
    func finalizedHikeRemainsOwnedDuringCleanup() async throws {
      let sharedStore = BlockingClearRecordingSharedStateStore()
      let recorder = makeRecorder(sharedStateStore: sharedStore)
      await recorder.start()
      source.deliver(fix(latitude: 47.63))
      await settleDelegateHop()
      clock.advance(by: 10)
      source.deliver(fix(latitude: 47.6302))
      await settleDelegateHop()

      let stop = Task { try await recorder.stop() }
      await sharedStore.waitForClearToStart()

      let hike = try #require(recorder.currentHike)
      #expect(recorder.phase == .saving)
      #expect(!hike.isRecording)
      #expect(
        hike.belongsToActiveRecording(
          currentHikeID: recorder.currentHike?.id
        )
      )

      await sharedStore.releaseClear()
      _ = try savedHike(from: try await stop.value)

      #expect(recorder.currentHike == nil)
      #expect(!hike.belongsToActiveRecording(currentHikeID: nil))
    }

    @Test("discard removes the active recording entry")
    func discardRemovesDraft() async throws {
      let recorder = makeRecorder()
      await recorder.start()
      let draftID = try #require(recorder.currentHike?.id)

      #expect(try context.fetch(FetchDescriptor<Hike>()).count == 1)

      await recorder.discard()

      #expect(recorder.phase == .idle)
      #expect(recorder.currentHike == nil)
      #expect(
        try context.fetch(
          FetchDescriptor<Hike>(
            predicate: #Predicate { $0.id == draftID }
          )
        ).isEmpty
      )
    }

    @Test("Start replaces an orphaned recording draft")
    func startRemovesOrphanedDraft() async throws {
      let orphan = Hike(
        title: "Interrupted Hike",
        distanceMeters: 0,
        isRecording: true
      )
      context.insert(orphan)
      try context.save()

      let recorder = makeRecorder()
      await recorder.start()

      let current = try #require(recorder.currentHike)
      let hikes = try context.fetch(FetchDescriptor<Hike>())
      #expect(hikes.count == 1)
      #expect(current.id != orphan.id)
      #expect(hikes.first?.id == current.id)
    }

    @Test("recovery removes a recording draft that has no journal")
    func recoveryRemovesOrphanedDraft() async throws {
      context.insert(
        Hike(
          title: "Interrupted Hike",
          distanceMeters: 0,
          isRecording: true
        )
      )
      try context.save()

      let recorder = makeRecorder()
      await recorder.recoverOpenSession()

      #expect(recorder.phase == .idle)
      #expect(try context.fetch(FetchDescriptor<Hike>()).isEmpty)
    }

    @Test("the bundled Thumsee simulator route records and saves end to end")
    func bundledDemoRouteRecordsHike() async throws {
      let routeURL = try #require(
        Bundle.main.url(
          forResource: "ThumseeLoopFast",
          withExtension: "gpx"
        )
      )
      let track = try GPXImport.load(from: routeURL)
      let locations = acceleratedLocations(
        from: track,
        endingAt: clock.now
      )
      let recorder = makeRecorder()

      await recorder.start()
      source.deliver(locations)
      await settleDelegateHop()

      let acceptedPointCount = recorder.stats.pointCount
      let hike = try savedHike(from: await recorder.stop())
      let first = try #require(hike.route.first)
      let last = try #require(hike.route.last)
      let sourceFirst = try #require(track.points.first)
      let sourceLast = try #require(track.points.last)

      #expect(track.points.count > 300)
      #expect(acceptedPointCount > 250)
      #expect(hike.route.count == acceptedPointCount)
      #expect(
        RouteGeometry.distanceMeters(
          from: first.clCoordinate,
          to: sourceFirst.coordinate
        ) < 1
      )
      #expect(
        RouteGeometry.distanceMeters(
          from: last.clCoordinate,
          to: sourceLast.coordinate
        ) < 1
      )
      #expect(
        abs(hike.distanceMeters - track.distanceMeters)
        < track.distanceMeters * 0.15
      )
      #expect(hike.rawRoute.isEmpty)
    }

    @Test("the journal falls back to Application Support without an App Group")
    func journalFallsBackOutsideTheAppGroup() {
      let appGroup = URL(filePath: "/tmp/group.example")
      let support = URL(filePath: "/tmp/support.example")

      #expect(
        HikeRecorder.journalDirectory(
          appGroupContainer: appGroup,
          applicationSupport: support
        ) == appGroup.appendingPathComponent("Recording", isDirectory: true),
        "the shared container is still preferred, for the widget payload to come"
      )
      #expect(
        HikeRecorder.journalDirectory(
          appGroupContainer: nil,
          applicationSupport: support
        ) == support.appendingPathComponent("Recording", isDirectory: true),
        "an unprovisioned App Group must not be the difference between recording and refusing"
      )
      #expect(
        HikeRecorder.journalDirectory(
          appGroupContainer: nil,
          applicationSupport: nil
        ) == nil
      )
    }

    @Test("a paused session is not described as recording")
    func pausedSessionIsNotCapturingFixes() async {
      let recorder = makeRecorder()
      await recorder.start()
      source.deliver(fix(latitude: 47.63))
      await settleDelegateHop()
      #expect(recorder.isCapturingFixes)

      recorder.pause()

      #expect(recorder.isActive, "still reachable from the hikes list")
      #expect(!recorder.isCapturingFixes, "but no longer taking fixes")
    }

    @Test("elapsed time comes from a monotonic source, not the wall clock")
    func elapsedTimeSurvivesAClockChange() async {
      let uptime = TestClock(Date(timeIntervalSince1970: 1000))
      let newRecorder = HikeRecorder(
        container: container,
        source: source,
        journalDirectory: directory,
        clock: clock.read,
        uptime: { uptime.now.timeIntervalSince1970 },
        journalFlushDelay: .zero,
        automaticallyRecovers: false
      )
      await recorder.start()

      uptime.advance(by: 90)
      // Someone's phone picks up an NTP correction an hour into the walk.
      clock.advance(by: -3600)

      #expect(recorder.elapsedSeconds() == 90)
    }
  }
}
