//
//  HikeRecorderTests+Review.swift
//  OpenHikesTests
//
//  Stopping a recording that matching moved now ends in review rather than in
//  the store: the hiker decides, per section, between the trail and the trace.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import SwiftData
import Testing

/// The trace `recordSnappedTrace` walks, beside the trail `matchedPathGraph`
/// puts ~11 m to its west.
private enum SnappedTrace {
    static let startLatitude = 47.63
    static let endLatitude = 47.6302
}

extension HikeRecorderTests {

    @Test("a snapped recording waits for review before it is saved")
    func snappedRecordingRequiresReview() async throws {
        let recorder = await recordSnappedTrace()

        let outcome = try await recorder.stop()

        guard case .needsReview = outcome else {
            Issue.record("a moved route should be reviewed before saving")
            return
        }
        #expect(recorder.phase == .reviewing)
        let review = try #require(recorder.routeReview)
        #expect(review.sections.count == 1)
        let section = try #require(review.current)
        #expect(section.kind == .snapped)
        #expect(section.trailName == "Matched Path")
        #expect(review.choice(for: section) == .matched)
        #expect(recorder.trace.reviewSegment.count == section.matchedPoints.count)

        let draft = try #require(recorder.currentHike)
        #expect(draft.isRecording, "the draft is held until review finishes")
        #expect(draft.route.isEmpty)
    }

    @Test("keeping the trail saves the matched line and the raw trace")
    func keepingTheTrailSavesMatchedGeometry() async throws {
        let recorder = await recordSnappedTrace()
        _ = try await recorder.stop()

        let hike = try await recorder.saveReviewedRecording()

        #expect(hike.route.count == 2)
        #expect(hike.route.allSatisfy { coordinate in
            abs(coordinate.longitude - 12.8599) < 0.00001
        })
        #expect(hike.rawRoute.count == 2)
        #expect(hike.rawRoute.allSatisfy { coordinate in
            abs(coordinate.longitude - 12.86) < 0.00001
        })
        #expect(recorder.phase == .idle)
        #expect(try context.fetch(FetchDescriptor<Hike>()).count == 1)
    }

    @Test("handing the section back to GPS saves the recorded trace instead")
    func choosingGPSSavesTheRecordedTrace() async throws {
        let recorder = await recordSnappedTrace()
        _ = try await recorder.stop()

        recorder.selectRouteChoice(.gps)
        let previewedLongitudes = recorder.trace.reviewSegment.map(\.longitude)
        let hike = try await recorder.saveReviewedRecording()

        #expect(previewedLongitudes.allSatisfy { longitude in
            abs(longitude - 12.86) < 0.00001
        })
        #expect(hike.route.count == 2)
        #expect(hike.route.allSatisfy { coordinate in
            abs(coordinate.longitude - 12.86) < 0.00001
        })
        #expect(
            hike.rawRoute.isEmpty,
            "the saved route is the trace, so a second copy holds no new fact"
        )
        #expect(recorder.phase == .idle)
    }

    @Test("a failed reviewed save retains its choices and name for retry")
    func reviewedSaveFailureCanRetry() async throws {
        let saver = ScriptedModelContextSaver(failedSaveNumbers: [2])
        let recorder = makeRecorder(
            trailGraphProvider: StubTrailGraphProvider(
                graph: matchedPathGraph()
            ),
            saveModelContext: saver.save
        )
        await recorder.start()
        source.deliver(fix(latitude: SnappedTrace.startLatitude))
        await settleDelegateHop()
        clock.advance(by: 10)
        source.deliver(fix(latitude: SnappedTrace.endLatitude))
        await settleDelegateHop()

        guard case .needsReview = try await recorder.stop(
            customName: "  Retried Reviewed Hike  "
        ) else {
            Issue.record("the moved route did not enter review")
            return
        }
        recorder.selectRouteChoice(.gps)
        do {
            _ = try await recorder.saveReviewedRecording()
            Issue.record("the injected persistence failure was ignored")
        } catch let failure as RecordingFailure {
            guard case .save = failure else {
                Issue.record("the reviewed save returned the wrong failure")
                return
            }
        }

        #expect(recorder.canRetrySave)
        #expect(recorder.routeReview != nil)
        guard case .failed = recorder.phase else {
            Issue.record("the failed reviewed save did not remain recoverable")
            return
        }

        let hike = try await recorder.retrySave()

        #expect(hike.customName == "Retried Reviewed Hike")
        #expect(hike.route.allSatisfy { coordinate in
            abs(coordinate.longitude - 12.86) < 0.00001
        })
        #expect(hike.rawRoute.isEmpty)
        #expect(recorder.phase == .idle)
        #expect(saver.saveCount == 3)
        let freshContext = ModelContext(container)
        let reloaded = try freshContext.fetch(FetchDescriptor<Hike>())
        #expect(reloaded.first?.customName == "Retried Reviewed Hike")
    }

    @Test("a choice only reaches the recording while the review is open")
    func choicesAreIgnoredOutsideReview() async throws {
        let recorder = await recordSnappedTrace()

        recorder.selectRouteChoice(.gps)
        #expect(recorder.routeReview == nil)

        _ = try await recorder.stop()
        let review = try #require(recorder.routeReview)
        let section = try #require(review.current)
        #expect(review.choice(for: section) == .matched)

        _ = try await recorder.saveReviewedRecording()
        recorder.selectRouteChoice(.gps)
        #expect(recorder.routeReview == nil)
    }

    @Test("an unmatched recording still saves without a review step")
    func unmatchedRecordingSkipsReview() async throws {
        let recorder = makeRecorder(
            trailGraphProvider: StubTrailGraphProvider(graph: .empty)
        )
        await recorder.start()
        source.deliver(fix(latitude: SnappedTrace.startLatitude))
        await settleDelegateHop()
        clock.advance(by: 10)
        source.deliver(fix(latitude: SnappedTrace.endLatitude))
        await settleDelegateHop()

        let hike = try savedHike(from: await recorder.stop())

        #expect(recorder.routeReview == nil)
        #expect(hike.route.count == 2)
        #expect(hike.rawRoute.isEmpty)
    }

    /// Records two fixes ~11 m east of `matchedPathGraph`'s trail, which the
    /// matcher snaps onto it.
    private func recordSnappedTrace() async -> HikeRecorder {
        let recorder = makeRecorder(
            trailGraphProvider: StubTrailGraphProvider(
                graph: matchedPathGraph()
            )
        )
        await recorder.start()
        source.deliver(fix(latitude: SnappedTrace.startLatitude))
        await settleDelegateHop()
        clock.advance(by: 10)
        source.deliver(fix(latitude: SnappedTrace.endLatitude))
        await settleDelegateHop()
        return recorder
    }
}
