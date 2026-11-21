//
//  HikeRecorder+RetrySave.swift
//  OpenHikes
//
//  What a stopped recording still offers when its save was refused: the same
//  save again, from what was already prepared. Split out to keep
//  `HikeRecorder.swift` under the file-length limit.
//

import Foundation
import OpenHikesData

extension HikeRecorder {
    func retrySave() async throws -> Hike {
        guard case .failed = phase, let journal, let pendingPreparedSave else {
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
}
