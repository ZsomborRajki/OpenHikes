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
    ///   `ModelConfiguration` is fixed for the life of its container.
    static func openHikes(
        isStoredInMemoryOnly: Bool = false,
        syncsToCloud: Bool = true
    ) -> ModelConfiguration {
        ModelConfiguration(
            "Hikes",
            schema: Schema([Hike.self]),
            isStoredInMemoryOnly: isStoredInMemoryOnly,
            cloudKitDatabase: isStoredInMemoryOnly || !syncsToCloud ? .none : .automatic
        )
    }

    /// The unmirrored store: what this device has on its own disk.
    ///
    /// Always `.none`, with no parameter to say otherwise. The point of this
    /// store is that it is the one place the answer is not a choice.
    static func openHikesLocal(isStoredInMemoryOnly: Bool = false) -> ModelConfiguration {
        ModelConfiguration(
            "HikeLocalState",
            schema: Schema([HikeLocalState.self]),
            isStoredInMemoryOnly: isStoredInMemoryOnly,
            cloudKitDatabase: .none
        )
    }

    /// The hike store at a chosen location, for the suites that assert on what
    /// survives a reopen.
    ///
    /// Never mirrored: a test that writes into the user's real iCloud database
    /// is a test that has already failed.
    static func openHikes(url: URL) -> ModelConfiguration {
        ModelConfiguration("Hikes", schema: Schema([Hike.self]), url: url, cloudKitDatabase: .none)
    }

    /// The sidecar store at a chosen location, alongside ``openHikes(url:)``.
    static func openHikesLocal(url: URL) -> ModelConfiguration {
        ModelConfiguration(
            "HikeLocalState",
            schema: Schema([HikeLocalState.self]),
            url: url,
            cloudKitDatabase: .none
        )
    }
}

extension ModelContainer {
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
        try ModelContainer(
            for: Schema([Hike.self, HikeLocalState.self]),
            configurations: .openHikes(
                isStoredInMemoryOnly: isStoredInMemoryOnly,
                syncsToCloud: syncsToCloud
            ),
            .openHikesLocal(isStoredInMemoryOnly: isStoredInMemoryOnly)
        )
    }

    /// Both stores at chosen locations, for the reopen suites.
    static func openHikes(url: URL, localURL: URL) throws -> ModelContainer {
        try ModelContainer(
            for: Schema([Hike.self, HikeLocalState.self]),
            configurations: .openHikes(url: url),
            .openHikesLocal(url: localURL)
        )
    }
}
