//
//  HikeRecorder+Draft.swift
//  OpenHikes
//
//  Draft creation, device-local ownership, and deletion. A mirrored draft
//  may belong to another phone; automatic cleanup requires a local claim.
//

import Foundation
import SwiftData

extension HikeRecorder {
    func ensureRecordingHike(
        sessionID: UUID,
        startedAt: Date,
        title: String?
    ) throws(RecordingFailure) -> Hike {
        if let existing = try existingHike(sessionID: sessionID) {
            if existing.isRecording {
                try claimRecoveredDraft(existing)
                currentHike = existing
            }
            return existing
        }

        let hike = Hike(
            title: title ?? Self.defaultTitle(for: startedAt),
            distanceMeters: 0,
            id: sessionID,
            date: startedAt,
            tintHex: Hike.randomTintHex(),
            route: [],
            isRecording: true
        )
        container.mainContext.insert(hike)
        hike.ownsRecordingDraft = true
        do {
            try saveModelContext(container.mainContext)
            currentHike = hike
            return hike
        } catch {
            hike.deleteLocalState()
            container.mainContext.delete(hike)
            throw .save(error.localizedDescription)
        }
    }

    /// This path is reached with a matching device-local journal, which is
    /// the evidence a legacy draft needs before it can be claimed. Keep the
    /// claim durable even when the recovered session stays paused.
    private func claimRecoveredDraft(_ hike: Hike) throws(RecordingFailure) {
        do {
            let previousState = try hike.resolveLocalState()
            guard previousState?.ownsRecordingDraft != true else { return }
            hike.ownsRecordingDraft = true
            do {
                try saveModelContext(container.mainContext)
            } catch {
                if let previousState {
                    previousState.ownsRecordingDraft = false
                } else {
                    hike.deleteLocalState()
                }
                throw error
            }
        } catch {
            throw .save(error.localizedDescription)
        }
    }

    func deleteRecordingHike(sessionID: UUID?) throws(RecordingFailure) {
        guard let sessionID,
              let hike = try existingHike(sessionID: sessionID),
              hike.isRecording else { return }
        // A discarded draft is deleted the same way a saved hike is, sidecar
        // and photo files included — see `HikeDeletion`. A recording draft is
        // not an empty one on either count: the camera attaches photos to it
        // while the walk is on, and `AutoSaveController` folds browsing tiles
        // into whichever hike is active, which for the length of a walk is
        // this draft.
        do {
            try HikeDeletion.delete([hike], store: photoStore, save: saveModelContext)
        } catch {
            throw .save(error.localizedDescription)
        }
    }

    func deleteOrphanedRecordingHikes(
        except sessionID: UUID? = nil
    ) throws(RecordingFailure) {
        let descriptor = FetchDescriptor<Hike>(
            predicate: #Predicate { $0.isRecording }
        )
        let orphans: [Hike]
        do {
            // The journal is device-local; the drafts are mirrored. Neither
            // a missing journal nor local tiles/photos authorize deleting a
            // row another phone may still be recording into. Query positive
            // claims afresh so drafts arriving after launch stay protected.
            let owned = try container.mainContext.fetch(FetchDescriptor<HikeLocalState>(
                predicate: #Predicate { $0.ownsRecordingDraft }
            ))
            let ownedIDs = Set(owned.map(\.hikeID))
            orphans = try container.mainContext.fetch(descriptor).filter { draft in
                draft.id != sessionID && ownedIDs.contains(draft.id)
            }
        } catch {
            throw .save(error.localizedDescription)
        }
        guard !orphans.isEmpty else { return }

        if let currentHike,
           orphans.contains(where: { $0.id == currentHike.id }) {
            self.currentHike = nil
        }
        // One commit for the whole sweep, and — as in
        // `deleteRecordingHike(sessionID:)` — nothing erased until it lands.
        // An orphan has had a whole walk to accumulate photos and auto-saved
        // tile keys before the launch that abandoned it.
        do {
            try HikeDeletion.delete(orphans, store: photoStore, save: saveModelContext)
        } catch {
            throw .save(error.localizedDescription)
        }
    }

}
