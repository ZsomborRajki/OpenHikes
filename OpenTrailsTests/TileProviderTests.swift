//
//  TileProviderTests.swift
//  OpenTrailsTests
//
//  The provider catalog is small, static, and load-bearing in a way that
//  isn't obvious: `supportsBulkDownload` is not a feature flag, it's a
//  promise to the tile host. OpenStreetMap's tile usage policy forbids bulk
//  downloading outright, which is the entire reason the auto-save mechanism
//  exists — so a change that flips that flag is a licensing problem, not a
//  UI one, and it should fail here.
//

import Foundation
import Testing
@testable import OpenTrails

@Suite("Tile providers")
struct TileProviderTests {
    /// The one invariant with consequences outside this codebase.
    @Test("OpenStreetMap is never bulk-downloadable")
    func osmForbidsBulkDownload() {
        #expect(TileProvider.openStreetMap.supportsBulkDownload == false)
        #expect(TileProvider.default.id == TileProvider.openStreetMap.id)
    }

    /// Every provider has to carry its attribution — it's displayed wherever
    /// the tiles are, and all three sources require it.
    @Test("every provider is fully described", arguments: TileProvider.all)
    func catalogIsComplete(provider: TileProvider) {
        #expect(!provider.id.isEmpty)
        #expect(!provider.name.isEmpty)
        #expect(!provider.summary.isEmpty)
        #expect(!provider.attribution.isEmpty)
        #expect(provider.maximumZ >= OfflineTileDownloader.minZoom)
        #expect(provider.urlTemplate.contains("{z}"))
        #expect(provider.urlTemplate.contains("{x}"))
        #expect(provider.urlTemplate.contains("{y}"))
        #expect(provider.urlTemplate.hasPrefix("https://"))
    }

    /// Cache keys are namespaced by provider id, so a duplicate id would make
    /// two sources share saved tiles and render a mixed map.
    @Test("provider ids are unique")
    func idsAreUnique() {
        #expect(Set(TileProvider.all.map(\.id)).count == TileProvider.all.count)
    }

    /// A provider that needs a key must advertise where its key lives, and a
    /// keyless one must not pretend to have a slot.
    @Test("key-gated providers declare a key, keyless ones don't", arguments: TileProvider.all)
    func keyDeclaration(provider: TileProvider) {
        if provider.urlTemplate.contains("{key}") {
            #expect(provider.apiKeyPlistKey != nil)
        } else {
            #expect(provider.apiKeyPlistKey == nil)
        }
    }

    @Test("an unknown or missing provider id falls back to the default")
    func unknownIdFallsBack() {
        #expect(TileProvider.provider(id: nil).id == TileProvider.default.id)
        #expect(TileProvider.provider(id: "").id == TileProvider.default.id)
        #expect(TileProvider.provider(id: "a_provider_we_removed").id == TileProvider.default.id)
        #expect(TileProvider.provider(id: TileProvider.thunderforestOutdoors.id).id == "thunderforest_outdoors")
    }

    @Test("resolving a template substitutes the key and leaves the tile placeholders alone")
    func resolvedTemplate() {
        let resolved = TileProvider.thunderforestOutdoors.resolvedTemplate(apiKey: "SECRET")
        #expect(resolved.contains("apikey=SECRET"))
        #expect(!resolved.contains("{key}"))
        #expect(resolved.contains("{z}/{x}/{y}"))
    }

    /// A missing key resolves to an empty string rather than leaving `{key}`
    /// in the URL — the request still fails, but as a plain 401/403 rather
    /// than a malformed URL. (There is no in-app way to supply a key, so this
    /// is the real experience of picking a key-gated provider on a fresh
    /// clone: a blank map.)
    @Test("a missing key leaves an empty parameter, not a literal placeholder")
    func resolvedTemplateWithoutKey() {
        let resolved = TileProvider.stadiaOutdoors.resolvedTemplate(apiKey: "")
        #expect(resolved.hasSuffix("api_key="))
        #expect(!resolved.contains("{key}"))
    }

    /// Keyless providers ignore whatever they're handed.
    @Test("a keyless provider's template is unaffected by a key")
    func keylessTemplateIgnoresKey() {
        let provider = TileProvider.openStreetMap
        #expect(provider.resolvedTemplate(apiKey: "SECRET") == provider.urlTemplate)
    }

    /// The settings keys are read from two places each (the settings UI and
    /// the map/tracker), by name — pinning the strings is what stops a rename
    /// on one side from silently resetting a user's choice.
    @Test("persisted setting keys are stable")
    func settingsKeys() {
        #expect(SettingsKey.tileProviderID == "settings.tileProviderID")
        #expect(SettingsKey.backgroundTrackingEnabled == "settings.backgroundTrackingEnabled")
        #expect(SettingsKey.lastSelectedHikeID == "selection.lastHikeID")
    }

    /// A resolved source is what the map compares to decide whether to
    /// rebuild its overlay; two identical selections must not look different.
    @Test("resolved sources compare by value")
    func activeSourceEquality() {
        func source(for provider: TileProvider) -> ActiveTileSource {
            ActiveTileSource(
                providerID: provider.id,
                urlTemplate: provider.resolvedTemplate(apiKey: "K"),
                maximumZ: provider.maximumZ
            )
        }
        #expect(source(for: .openStreetMap) == source(for: .openStreetMap))
        #expect(source(for: .openStreetMap) != source(for: .stadiaOutdoors))
    }

    /// Filling a template has to produce a URL that actually parses — the
    /// downloader silently skips any tile whose URL doesn't.
    @Test("a filled template produces a usable tile URL", arguments: TileProvider.all)
    func tileURLs(provider: TileProvider) throws {
        let tile = OfflineTileDownloader.Tile(z: 14, x: 8_723, y: 5_685)
        let url = try #require(tile.url(from: provider.resolvedTemplate(apiKey: "K")))
        #expect(url.absoluteString.contains("14"))
        #expect(url.absoluteString.contains("8723"))
        #expect(url.absoluteString.contains("5685"))
        #expect(url.host() != nil)
    }
}
