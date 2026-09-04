//
//  ModelConfiguration+OpenHikes.swift
//  OpenHikes
//
//  Every SwiftData store this app opens, and the one thing they all have to
//  say.
//
//  There are two, and the split is the whole design. ``Hike`` lives in a store
//  SwiftData mirrors to the user's private CloudKit database;
//  ``HikeLocalState`` lives in one it does not. Mirroring syncs a *row* and
//  resolves conflicts last-writer-wins, so anything describing files in *this*
//  device's Application Support has to sit somewhere the mirror cannot reach —
//  see ``HikeLocalState`` for what a second device's tile inventory would
//  otherwise do to this one's offline maps.
//
//  Collected into one place because the failure mode of getting it wrong
//  somewhere is not a compile error: it is a silent whole-row sync of
//  whichever store was opened without thinking about it.
//
//  Two constraints ride along with `.automatic` and are easy to trip over
//  later. Mirroring refuses to open a store that has a mandatory attribute
//  with no default, and it forbids uniqueness constraints outright — ``Hike``
//  satisfies both, and a column added to it has to keep satisfying them.
//

import Foundation
import SwiftData

extension ModelConfiguration {
    /// The mirrored store: hikes, their metadata, their routes and their photo
    /// metadata.
    ///
    /// - Parameter syncsToCloud: False for a store that must never reach
    ///   iCloud — an in-memory one, which cannot mirror at all, and the user's
    ///   own switch, which is read once at launch because a
    ///   `ModelConfiguration` is fixed for the life of its container. Once at
    ///   launch is the settled answer rather than the easy one: see
    ///   ``CloudSyncCoordinator/pendingRelaunch``.
    static func openHikes(
        schema: Schema,
        isStoredInMemoryOnly: Bool = false,
        syncsToCloud: Bool = true
    ) -> ModelConfiguration {
        ModelConfiguration(
            "Hikes",
            schema: schema,
            isStoredInMemoryOnly: isStoredInMemoryOnly,
            cloudKitDatabase: isStoredInMemoryOnly || !syncsToCloud ? .none : .automatic
        )
    }

    /// The unmirrored store: what this device has on its own disk.
    ///
    /// Always `.none`, with no parameter to say otherwise. The point of this
    /// store is that it is the one place the answer is not a choice.
    static func openHikesLocal(
        schema: Schema,
        isStoredInMemoryOnly: Bool = false
    ) -> ModelConfiguration {
        ModelConfiguration(
            "HikeLocalState",
            schema: schema,
            isStoredInMemoryOnly: isStoredInMemoryOnly,
            cloudKitDatabase: .none
        )
    }

    /// The hike store at a chosen location, for the suites that assert on what
    /// survives a reopen.
    ///
    /// Never mirrored: a test that writes into the user's real iCloud database
    /// is a test that has already failed.
    static func openHikes(schema: Schema, url: URL) -> ModelConfiguration {
        ModelConfiguration("Hikes", schema: schema, url: url, cloudKitDatabase: .none)
    }

    /// The sidecar store at a chosen location, alongside ``openHikes(url:)``.
    static func openHikesLocal(schema: Schema, url: URL) -> ModelConfiguration {
        ModelConfiguration(
            "HikeLocalState",
            schema: schema,
            url: url,
            cloudKitDatabase: .none
        )
    }
}

extension ModelContainer {
    private static func schema(
        _ modelTypes: [any PersistentModel.Type],
        version: Schema.Version
    ) -> Schema {
        Schema(modelTypes, version: version)
    }

    /// The app's container: both stores, one context, one place that knows
    /// they come as a pair.
    ///
    /// A factory rather than two configurations spelled out at each call site,
    /// because there are half a dozen of those — the app, its fallback, UI
    /// testing, two previews and the test fixtures — and a container built
    /// with only the mirrored half does not fail to compile. It fails at the
    /// first tile a hike tries to claim.
    static func openHikes(
        isStoredInMemoryOnly: Bool = false,
        syncsToCloud: Bool = true
    ) throws -> ModelContainer {
        let version = OpenHikesSchemaV2.self
        return try ModelContainer(
            for: Schema(versionedSchema: version),
            migrationPlan: OpenHikesMigrationPlan.self,
            configurations: .openHikes(
                schema: schema(version.hikeModels, version: version.versionIdentifier),
                isStoredInMemoryOnly: isStoredInMemoryOnly,
                syncsToCloud: syncsToCloud
            ),
            .openHikesLocal(
                schema: schema(version.localStateModels, version: version.versionIdentifier),
                isStoredInMemoryOnly: isStoredInMemoryOnly
            )
        )
    }

    /// Both stores at chosen locations, for the reopen suites.
    static func openHikes(url: URL, localURL: URL) throws -> ModelContainer {
        try openHikes(
            schemaVersion: OpenHikesSchemaV2.self,
            url: url,
            localURL: localURL,
            migrationPlan: OpenHikesMigrationPlan.self
        )
    }

    /// A chosen schema version over the stores that version had. The migration
    /// suite uses this to write a genuine previous-version fixture through the
    /// same store configuration boundary as production.
    ///
    /// The sidecar configuration is opened only when the version actually has
    /// one. A version predating the split — see ``OpenHikesSchemaV1`` — left no
    /// second file behind, and writing a fixture that has one would be writing
    /// a store no install ever had.
    static func openHikes(
        schemaVersion: any OpenHikesVersionedSchema.Type,
        url: URL,
        localURL: URL,
        migrationPlan: (any SchemaMigrationPlan.Type)? = nil
    ) throws -> ModelContainer {
        var configurations: [ModelConfiguration] = [
            .openHikes(
                schema: schema(schemaVersion.hikeModels, version: schemaVersion.versionIdentifier),
                url: url
            ),
        ]
        if !schemaVersion.localStateModels.isEmpty {
            configurations.append(
                .openHikesLocal(
                    schema: schema(schemaVersion.localStateModels, version: schemaVersion.versionIdentifier),
                    url: localURL
                )
            )
        }
        return try ModelContainer(
            for: Schema(versionedSchema: schemaVersion),
            migrationPlan: migrationPlan,
            configurations: configurations
        )
    }
}
