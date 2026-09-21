//
//  OpenHikesSchema.swift
//  OpenHikes
//

import SwiftData

/// The current model and its two store configurations.
/// See "Schema and migration policy" in the repository instructions.
nonisolated enum OpenHikesSchema: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var hikeModels: [any PersistentModel.Type] { [Hike.self, HikeWalk.self, TrailPoint.self] }
    /// The unmirrored store. ``TrailDraftRecord`` is here rather than beside
    /// ``Hike`` because a half-drawn trail is one device's unfinished work —
    /// see that type for the argument, and note what it buys: no `CD_` record
    /// type, no Console index and no entry in ``MirroredCloudKitSchema``.
    static var localStateModels: [any PersistentModel.Type] {
        [HikeLocalState.self, TrailDraftRecord.self]
    }
    static var models: [any PersistentModel.Type] { hikeModels + localStateModels }
}
