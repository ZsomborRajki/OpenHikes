//
//  MapEntitlementTests.swift
//  OpenHikesTests
//
//  The gate that decides whether a commercial map source may be drawn.
//
//  Every test here passes its entitlement explicitly. The process-wide
//  ``MapEntitlement`` is shared by every suite in this bundle and Swift Testing
//  runs them in parallel, so a suite that wrote to it would decide another
//  suite's answer — which is exactly why `renderable(id:entitlement:)` takes a
//  parameter at all.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Map entitlement")
struct MapEntitlementTests {
    /// The window between launch and StoreKit answering. Getting this backwards
    /// is the difference between a paying user's map flickering to
    /// OpenStreetMap on every launch and nobody noticing anything.
    @Test("an unresolved entitlement allows the paid sources")
    func unknownIsOptimistic() {
        let unknown = MapEntitlementState.unknown
        #expect(unknown.allows(.stadiaOutdoors))
        #expect(unknown.allows(.thunderforestOutdoors))
        #expect(!unknown.isResolved)
    }

    @Test("a resolved entitlement is what locks or unlocks")
    func resolvedStates() {
        #expect(MapEntitlementState.entitled.allows(.stadiaOutdoors))
        #expect(!MapEntitlementState.notEntitled.allows(.stadiaOutdoors))
        #expect(!MapEntitlementState.notEntitled.allows(.thunderforestOutdoors))
        #expect(MapEntitlementState.entitled.isResolved)
        #expect(MapEntitlementState.notEntitled.isResolved)
    }

    /// The free sources cannot be gated by anything, including a bug in the
    /// entitlement itself. A user who never pays still has a working map.
    @Test("the free sources are allowed in every state")
    func freeSourcesAreNeverGated() {
        for state in [MapEntitlementState.unknown, .entitled, .notEntitled] {
            #expect(state.allows(.openStreetMap))
            #expect(state.allows(.appleMaps))
        }
    }

    /// The fallback that keeps a lapsed or synced-in paid id from drawing a
    /// blank map.
    @Test("an unentitled device renders a paid id as the default")
    func unentitledFallsBackToDefault() {
        #expect(
            TileProvider.renderable(
                id: TileProvider.stadiaOutdoors.id,
                entitlement: .notEntitled
            ).id == TileProvider.default.id
        )
        #expect(
            TileProvider.renderable(
                id: TileProvider.thunderforestOutdoors.id,
                entitlement: .notEntitled
            ).id == TileProvider.default.id
        )
    }

    /// The stored id has to survive the fallback: it syncs through iCloud, so
    /// rewriting it here would push a downgrade to a device that *is* entitled.
    @Test("the stored id is never rewritten by the fallback")
    func fallbackLeavesTheStoredIDAlone() {
        let defaults = UserDefaults(suiteName: "MapEntitlementTests.\(UUID().uuidString)")
        guard let defaults else {
            Issue.record("Couldn't create an isolated defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        defaults.set(TileProvider.stadiaOutdoors.id, forKey: SettingsKey.tileProviderID)
        let rendered = TileProvider.selected(in: defaults, entitlement: .notEntitled)

        #expect(rendered.id == TileProvider.default.id)
        #expect(
            defaults.string(forKey: SettingsKey.tileProviderID)
                == TileProvider.stadiaOutdoors.id
        )
    }

    /// An entitled device with no API key still falls back — the two gates are
    /// independent, and a paid unlock cannot conjure a build-time secret.
    @Test("entitlement doesn't override a missing API key")
    func entitlementDoesNotBypassSecrets() {
        let stadia = TileProvider.stadiaOutdoors
        let rendered = TileProvider.renderable(id: stadia.id, entitlement: .entitled)
        #expect(rendered.id == (Secrets.canLoadTiles(stadia) ? stadia.id : TileProvider.default.id))
    }
}
