//
//  DeletedWatchWalk.swift
//  OpenHikes
//
//  A walk from the watch whose hike the hiker has deleted on this phone.
//
//  The import recognises a second arrival by
//  ``HikeLocalState/watchSessionID``, and the sidecar goes with its hike — so
//  once a hike was deleted, nothing said its walk had ever been here, and a
//  retry from the watch made it again (#1115). The watch keeps a walk until a
//  receipt comes back, so a lost receipt, a transfer still in flight or a watch
//  relaunch is all that retry takes.
//
//  **A row per deletion, not per import.** Written by `HikeDeletion` in the
//  same save that takes the hike out, so the store has it exactly when the
//  deletion is on disk and a refused save takes it back with the rest. A
//  ledger written at import instead would also have to tell a deleted hike
//  from one whose save never landed, and a sidecar that outlived its hike
//  would read as a deletion — dropping a walk the hiker never saw.
//
//  **In the unmirrored store**, for the reason ``HikeLocalState/watchSessionID``
//  is: a watch session is a transfer to *this* phone, the only device that
//  will ever be offered that walk again. It costs no `CD_` record type and no
//  entry in ``MirroredCloudKitSchema``.
//
//  Never pruned. A row is a UUID per watch hike the hiker deleted, and a walk
//  the watch still holds can arrive any time it next connects.
//

import Foundation
import SwiftData

@Model
public final class DeletedWatchWalk {
    /// Indexed because the import asks by it, once per arriving walk.
    #Index<DeletedWatchWalk>([\.sessionID])

    /// The watch recording the deleted hike was imported from — the same
    /// identifier ``HikeLocalState/watchSessionID`` held.
    public var sessionID: UUID

    public init(sessionID: UUID) {
        self.sessionID = sessionID
    }
}
