//
//  RecordingSharedStateStore.swift
//  OpenHikes
//
//  Off-main access to the App Group files a live recording shares with the
//  widget. HikeRecorder depends on the protocol so its unit tests never touch
//  process-global widget state.
//

import Foundation
import OpenHikesShared
import WidgetKit

nonisolated protocol RecordingSharedStateStoring: Sendable {
    func save(
        _ snapshot: SharedRecordingSnapshot,
        reloadWidget: Bool
    ) async throws
    func clear(sessionID: UUID?) async throws
    func pendingFixes(for sessionID: UUID) async throws
        -> [SharedRecordingFix]
    func removePendingFixes(ids: Set<UUID>) async throws
}

actor AppGroupRecordingSharedStateStore: RecordingSharedStateStoring {
    func save(
        _ snapshot: SharedRecordingSnapshot,
        reloadWidget: Bool
    ) throws {
        assertOffMainThread(
            "Recording widget snapshot writes must stay off the main thread"
        )
        try SharedStore.saveRecording(snapshot)
        if reloadWidget {
            WidgetCenter.shared.reloadTimelines(ofKind: TrailWidgetKind.id)
        }
    }

    func clear(sessionID: UUID?) throws {
        assertOffMainThread(
            "Recording widget snapshot deletion must stay off the main thread"
        )
        try SharedStore.clearRecording(sessionID: sessionID)
        WidgetCenter.shared.reloadTimelines(ofKind: TrailWidgetKind.id)
    }

    func pendingFixes(
        for sessionID: UUID
    ) throws -> [SharedRecordingFix] {
        assertOffMainThread(
            "Widget fix reads must stay off the main thread"
        )
        return try SharedStore.loadPendingRecordingFixes().filter { fix in
            fix.sessionID == sessionID
        }
    }

    func removePendingFixes(ids: Set<UUID>) throws {
        assertOffMainThread(
            "Widget fix deletion must stay off the main thread"
        )
        try SharedStore.removePendingRecordingFixes(ids: ids)
    }
}
