//
//  HikeRecorderTests+Checks.swift
//  OpenHikesTests
//
//  Stopping a recording that matching moved ends in the store, at once: the
//  line is saved with each stretch drawn the way that needs no answer, and
//  the question is kept on the hike for *Edit Route* to ask — see
//  ``RouteAssembly``. It used to end in a review, and the hike was a draft
//  until the hiker had gone through it.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import SwiftData
import Testing

/// The trace `recordSnappedTrace` walks, beside the trail `matchedPathGraph`
/// puts ~7.5 m to its west.
private enum SnappedTrace {
    static let startLatitude = 47.63
    static let endLatitude = 47.6302
    static let longitude = 12.86
    static let trailLongitude = 12.8599
    static let tolerance = 0.00001
}

extension HikeRecorderTests {

    @Test("a snapped recording is saved at once, on the trail, with the stretch kept to check")
    func aSnappedRecordingIsSavedAtOnce() async throws {
        let recorder = await recordSnappedTrace()

        let hike = try await recorder.stop()

        #expect(recorder.phase == .idle)
        #expect(!hike.isRecording)
        #expect(try context.fetch(FetchDescriptor<Hike>()).count == 1)
        #expect(hike.route.count == 2)
        #expect(hike.route.allSatisfy { coordinate in
            coordinate.longitude.isApproximatelyEqual(
                to: SnappedTrace.trailLongitude,
                absoluteTolerance: SnappedTrace.tolerance
            )
        })
        #expect(hike.rawRoute.count == 2)
        #expect(hike.rawRoute.allSatisfy { coordinate in
            coordinate.longitude.isApproximatelyEqual(
                to: SnappedTrace.longitude,
                absoluteTolerance: SnappedTrace.tolerance
            )
        })

        let edit = try #require(hike.routeEdit)
        #expect(edit.original == nil, "a question kept is not an edit: there is nothing to revert")
        #expect(!hike.hasOriginalRoute)
        #expect(edit.uncheckedCount == 1)
        #expect(edit.isOwedALook)
        let check = try #require(edit.assembly?.checks.first)
        #expect(check.kind == .snapped)
        #expect(check.trailName == "Matched Path")
        #expect(check.savedChoice == .matched)
        #expect(check.choice == .matched)
        #expect(!check.isChecked)
    }

    @Test("the kept stretch rebuilds the saved line, and the recorded trace under the other answer")
    func theKeptStretchRebuildsBothLines() async throws {
        let recorder = await recordSnappedTrace()
        let hike = try await recorder.stop()
        var assembly = try #require(hike.routeEdit?.assembly)

        #expect(assembly.line(saved: hike.route, raw: hike.rawRoute).route == hike.route)

        assembly.checks[0].choice = .gps
        let recorded = assembly.line(saved: hike.route, raw: hike.rawRoute).route
        #expect(recorded.count == 2)
        #expect(recorded.allSatisfy { coordinate in
            coordinate.longitude.isApproximatelyEqual(
                to: SnappedTrace.longitude,
                absoluteTolerance: SnappedTrace.tolerance
            )
        })
    }

    @Test("a failed save retains its line, its stretches and its name for retry")
    func aFailedSaveCanRetry() async throws {
        let saver = ScriptedModelContextSaver(failedSaveNumbers: [2])
        let recorder = makeRecorder(
            trailGraphProvider: StubTrailGraphProvider(
                graph: matchedPathGraph()
            ),
            saveModelContext: saver.save
        )
        await recorder.start()
        source.deliver(fix(latitude: SnappedTrace.startLatitude))
        clock.advance(by: 10)
        source.deliver(fix(latitude: SnappedTrace.endLatitude))

        do {
            _ = try await recorder.stop(customName: "  Retried Hike  ")
            Issue.record("the injected persistence failure was ignored")
        } catch let failure as RecordingFailure {
            guard case .save = failure else {
                Issue.record("the save returned the wrong failure")
                return
            }
        }

        #expect(recorder.canRetrySave)
        guard case .failed = recorder.phase else {
            Issue.record("the failed save did not remain recoverable")
            return
        }
        let draft = try #require(recorder.currentHike)
        #expect(draft.isRecording)
        #expect(draft.routeEditData == nil, "a save that was refused leaves nothing of itself on the draft")

        let hike = try await recorder.retrySave()

        #expect(hike.customName == "Retried Hike")
        #expect(hike.route.allSatisfy { coordinate in
            coordinate.longitude.isApproximatelyEqual(
                to: SnappedTrace.trailLongitude,
                absoluteTolerance: SnappedTrace.tolerance
            )
        })
        #expect(hike.routeEdit?.assembly?.checks.count == 1)
        #expect(recorder.phase == .idle)
        #expect(saver.saveCount == 3)
        let freshContext = ModelContext(container)
        let reloaded = try freshContext.fetch(FetchDescriptor<Hike>())
        #expect(reloaded.first?.customName == "Retried Hike")
        #expect(reloaded.first?.routeEdit?.uncheckedCount == 1)
    }

    @Test("an unmatched recording keeps nothing to check")
    func anUnmatchedRecordingKeepsNothing() async throws {
        let recorder = makeRecorder(
            trailGraphProvider: StubTrailGraphProvider(graph: .empty)
        )
        await recorder.start()
        source.deliver(fix(latitude: SnappedTrace.startLatitude))
        clock.advance(by: 10)
        source.deliver(fix(latitude: SnappedTrace.endLatitude))

        let hike = try await recorder.stop()

        #expect(hike.route.count == 2)
        #expect(hike.rawRoute.isEmpty)
        #expect(hike.routeEditData == nil)
    }

    /// Records two fixes ~7.5 m east of `matchedPathGraph`'s trail, which the
    /// matcher snaps onto it.
    private func recordSnappedTrace() async -> HikeRecorder {
        let recorder = makeRecorder(
            trailGraphProvider: StubTrailGraphProvider(
                graph: matchedPathGraph()
            )
        )
        await recorder.start()
        source.deliver(fix(latitude: SnappedTrace.startLatitude))
        clock.advance(by: 10)
        source.deliver(fix(latitude: SnappedTrace.endLatitude))
        return recorder
    }
}
