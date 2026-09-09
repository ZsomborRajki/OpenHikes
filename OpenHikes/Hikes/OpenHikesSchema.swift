//
//  OpenHikesSchema.swift
//  OpenHikes
//

import SwiftData

/// The current model and its two store configurations.
/// See "Schema and migration policy" in the repository instructions.
nonisolated enum OpenHikesSchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }
    static var hikeModels: [any PersistentModel.Type] { [Hike.self, HikeWalk.self] }
    static var localStateModels: [any PersistentModel.Type] { [HikeLocalState.self] }
    static var models: [any PersistentModel.Type] { hikeModels + localStateModels }
}
