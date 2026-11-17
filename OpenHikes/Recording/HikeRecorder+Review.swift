//
//  HikeRecorder+Review.swift
//  OpenHikes
//
//  What a stopped recording still offers: the route review's choices, the
//  save that follows it, and the retry of a save the store refused. Split out
//  to keep `HikeRecorder.swift` under the file-length limit.
//

import Foundation
import OpenHikesData

extension HikeRecorder {
    func selectRouteChoice(_ choice: TrailRouteChoice) {
        guard phase == .reviewing, let routeReview else { return }
        routeReview.select(choice)
        updateReviewPreview()
    }

    func moveToPreviousReviewSection() {
        guard phase == .reviewing, let routeReview else { return }
        routeReview.moveBackward()
        updateReviewPreview()
    }

    func moveToNextReviewSection() {
        guard phase == .reviewing, let routeReview else { return }
        routeReview.moveForward()
        updateReviewPreview()
    }

    func saveReviewedRecording() async throws -> Hike {
        guard phase == .reviewing else { throw RecordingFailure.save(String(
            localized: "No reviewed recording is ready to save."
        )) }
        return try await savePendingReviewedRecording()
    }

    func retrySave() async throws -> Hike {
        guard case .failed = phase, let journal else {
            throw RecordingFailure.save(String(localized: "No failed recording save is ready to retry."))
        }
        if pendingReviewSave != nil { return try await savePendingReviewedRecording() }
        guard let pendingPreparedSave else {
            throw RecordingFailure.save(String(localized: "No failed recording save is ready to retry."))
        }

        phase = .saving
        do {
            let hike = try persist(
                pendingPreparedSave.session,
                prepared: pendingPreparedSave.prepared,
                customName: pendingPreparedSave.customName
            )
            await finishSavedSession(
                pendingPreparedSave.session,
                journal: journal
            )
            return hike
        } catch {
            fail(error, endLocationUpdates: false)
            throw error
        }
    }

    private func savePendingReviewedRecording() async throws -> Hike {
        guard let pendingReviewSave,
              let routeReview,
              let journal else {
            throw RecordingFailure.save(String(localized: "No reviewed recording is ready to save."))
        }
        phase = .saving
        do {
            let points = pendingReviewSave.normalizedPoints
            let choices = routeReview.legChoices
            let startedAt = pendingReviewSave.session.metadata.startedAt
            guard pendingReviewSave.session.metadata.endedAt != nil else {
                throw RecordingFailure.save(String(localized: "The recording has not been finished yet."))
            }
            let prepared = try await RecordingPreparation.prepareResolvedOffMain(
                points: points,
                startedAt: startedAt,
                matchResult: pendingReviewSave.matchResult,
                choices: choices
            )
            pendingPreparedSave = PendingPreparedSave(
                session: pendingReviewSave.session,
                prepared: prepared,
                customName: pendingReviewSave.customName
            )
            let hike = try persist(
                pendingReviewSave.session,
                prepared: prepared,
                customName: pendingReviewSave.customName
            )
            await finishSavedSession(pendingReviewSave.session, journal: journal)
            return hike
        } catch let failure as RecordingFailure {
            fail(failure, endLocationUpdates: false)
            throw failure
        } catch {
            let failure = RecordingFailure.save(error.localizedDescription)
            fail(failure, endLocationUpdates: false)
            throw failure
        }
    }
}
