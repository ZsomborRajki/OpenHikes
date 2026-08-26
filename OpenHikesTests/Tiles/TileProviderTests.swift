//
//  TileProviderTests.swift
//  OpenHikesTests
//
//  The provider catalog is small, static, and load-bearing in a way that
//  isn't obvious: `supportsBulkDownload` is not a feature flag, it's a
//  promise to the tile host. OpenStreetMap's tile usage policy forbids bulk
//  downloading outright, which is the entire reason the auto-save mechanism
//  exists — so a change that flips that flag is a licensing problem, not a
//  UI one, and it should fail here.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Tile providers")
struct TileProviderTests {
    /// The one invariant with consequences outside this codebase.
    @Test("OpenStreetMap is never bulk-downloadable")
    func osmForbidsBulkDownload() {
        #expect(TileProvider.openStreetMap.supportsBulkDownload == false)
        #expect(TileProvider.default.id == TileProvider.openStreetMap.id)
    }

    /// Every entry has to carry its attribution — it's displayed wherever the
    /// map is, and every source requires it, Apple's included.
    @Test("every provider is fully described", arguments: TileProvider.all)
    func catalogIsComplete(provider: TileProvider) {
        #expect(!provider.id.isEmpty)
        #expect(!provider.name.isEmpty)
        #expect(!provider.summary.isEmpty)
        #expect(!provider.attribution.isEmpty)
    }

    /// The half of the description only a real tile source has. Split from the
    /// check above because the system base map has no template to fill and no
    /// zoom ceiling to respect — it installs no overlay at all.
    @Test("every raster source has a usable template", arguments: TileProvider.rasterSources)
    func rasterCatalogIsComplete(provider: TileProvider) {
        #expect(provider.maximumZ >= OfflineTileDownloader.minZoom)
        #expect(provider.urlTemplate.contains("{z}"))
        #expect(provider.urlTemplate.contains("{x}"))
        #expect(provider.urlTemplate.contains("{y}"))
        #expect(provider.urlTemplate.hasPrefix("https://"))
    }

    /// The whole point of the option: nothing about it can reach the network.
    /// A template would be enough to build an overlay from by accident, and an
    /// overlay is what fetches, caches and auto-saves — so the absence of one
    /// is the mechanism, not a detail of it.
    @Test("the system base map fetches nothing")
    func systemBaseMapHasNoTilePipeline() {
        let apple = TileProvider.appleMaps
        #expect(apple.usesSystemBaseMap)
        #expect(apple.urlTemplate.isEmpty)
        #expect(apple.apiKeyPlistKey == nil)
        #expect(!apple.supportsBulkDownload)
        #expect(apple.renderedSource == nil)
        #expect(!TileProvider.rasterSources.contains(apple))
    }

    /// Every real tile source still resolves to something the map can draw —
    /// the `nil` above has exactly one origin.
    @Test("only the system base map has no rendered source", arguments: TileProvider.rasterSources)
    func rasterSourcesRender(provider: TileProvider) {
        #expect(provider.renderedSource != nil)
        #expect(provider.renderedSource?.providerID == provider.id)
    }

    /// Its position is a product decision — the cheapest map sits directly
    /// under the default rather than at the bottom of the list — and its id is
    /// a storage contract, like every other one here.
    @Test("the system base map is the second choice, under a stable id")
    func systemBaseMapPlacement() {
        #expect(TileProvider.appleMaps.id == "apple_maps")
        #expect(TileProvider.all.count >= 2)
        #expect(TileProvider.all[1].id == TileProvider.appleMaps.id)
        #expect(TileProvider.all.first?.id == TileProvider.default.id)
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
    /// than a malformed URL. Reaching this at all now takes a stored id that
    /// outlived its key (see `renderable(id:)`), because Settings won't offer
    /// a key-gated provider with no key in the first place.
    @Test("a missing key leaves an empty parameter, not a literal placeholder")
    func resolvedTemplateWithoutKey() {
        let resolved = TileProvider.stadiaOutdoors.resolvedTemplate(apiKey: "")
        #expect(resolved.hasSuffix("api_key="))
        #expect(!resolved.contains("{key}"))
    }

    // MARK: - Usability

    /// What Settings greys a row out on, and what `renderable(id:)` falls back
    /// on. Keyless providers are usable no matter what they're handed — OSM is
    /// the default, so getting this wrong would make a fresh clone unusable.
    @Test("a keyless provider is usable with or without a key")
    func keylessProviderIsAlwaysUsable() {
        let provider = TileProvider.openStreetMap
        #expect(provider.isUsable(withKey: nil))
        #expect(provider.isUsable(withKey: ""))
        #expect(provider.isUsable(withKey: "SECRET"))
    }

    /// The blank-map case: a key-gated provider with nothing to substitute can
    /// only ever 401, so it isn't offered.
    @Test("a key-gated provider is usable only with a non-empty key", arguments: [
        TileProvider.stadiaOutdoors, TileProvider.thunderforestOutdoors
    ])
    func gatedProviderNeedsAKey(provider: TileProvider) {
        #expect(!provider.isUsable(withKey: nil))
        #expect(!provider.isUsable(withKey: ""))
        #expect(provider.isUsable(withKey: "SECRET"))
    }

    /// A build that once had a `Secrets.plist` leaves the chosen id behind in
    /// `UserDefaults` after the key is gone. Rendering that as a blank map is
    /// the worst available answer, so the resolution step falls back instead —
    /// and the fallback has to be a provider that needs no key, or it would
    /// just move the problem.
    @Test("a provider that can't load tiles resolves to the default")
    func unusableProviderFallsBack() {
        for provider in TileProvider.all where !Secrets.canLoadTiles(provider) {
            #expect(
                TileProvider.renderable(id: provider.id).id == TileProvider.default.id,
                "\(provider.name) has no key in this build, so the map must not be asked to draw it"
            )
        }
        #expect(Secrets.canLoadTiles(.default), "the fallback itself must never need a key")
    }

    /// The other half: resolution only ever *substitutes* a provider it can't
    /// draw, never one it can.
    @Test("a usable provider resolves to itself", arguments: TileProvider.all)
    func usableProviderIsKept(provider: TileProvider) {
        guard Secrets.canLoadTiles(provider) else { return }
        #expect(TileProvider.renderable(id: provider.id).id == provider.id)
    }

    /// Keyless providers ignore whatever they're handed.
    @Test("a keyless provider's template is unaffected by a key")
    func keylessTemplateIgnoresKey() {
        let provider = TileProvider.openStreetMap
        #expect(provider.resolvedTemplate(apiKey: "SECRET") == provider.urlTemplate)
    }

    /// Each of these is written in one place and read in another, by name —
    /// pinning the strings is what stops a rename on one side from silently
    /// resetting a user's choice.
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
        let osmSource = source(for: .openStreetMap)
        #expect(osmSource == source(for: .openStreetMap))
        #expect(source(for: .openStreetMap) != source(for: .stadiaOutdoors))
    }

    /// Filling a template has to produce a URL that actually parses — the
    /// downloader silently skips any tile whose URL doesn't.
    @Test("a filled template produces a usable tile URL", arguments: TileProvider.rasterSources)
    func tileURLs(provider: TileProvider) throws {
        let tile = OfflineTileDownloader.Tile(z: 14, x: 8723, y: 5685)
        let url = try #require(tile.url(from: provider.resolvedTemplate(apiKey: "K")))
        #expect(url.absoluteString.contains("14"))
        #expect(url.absoluteString.contains("8723"))
        #expect(url.absoluteString.contains("5685"))
        #expect(url.host() != nil)
    }

    /// `ActiveTileSource` carries `providerID` but not `supportsBulkDownload`,
    /// so the licensing promise above has to be *recovered* at the boundary
    /// into `OfflineTileDownloader.start(route:source:scale:)` rather than
    /// travelling with the value. ``ActiveTileSource/permitsBulkDownload`` is
    /// that lookup, and the downloader's refusal is pinned in
    /// `OfflineTileDownloaderTests`.
    ///
    /// This pins the projection itself: a source always reports its own
    /// provider's policy. If that stops being true, the enforcement above it
    /// has nowhere left to stand.
    @Test("a tile source can be traced back to its bulk-download policy", arguments: TileProvider.all)
    func policyIsRecoverableFromASource(provider: TileProvider) {
        let source = ActiveTileSource(provider)

        #expect(source.permitsBulkDownload == provider.supportsBulkDownload)
        #expect(
            TileProvider.provider(id: source.providerID).supportsBulkDownload
                == provider.supportsBulkDownload
        )
    }

    /// An unknown id resolves to the default provider, and the default is the
    /// one that forbids bulk downloads — so the failure mode of a source the
    /// catalog no longer recognises is "no download", not "download anyway".
    @Test("an unrecognised provider id resolves to a policy that forbids downloads")
    func unknownProviderFailsClosed() {
        let source = ActiveTileSource(
            providerID: "removed_provider",
            urlTemplate: "https://example.invalid/{z}/{x}/{y}.png",
            maximumZ: 12
        )

        #expect(!source.permitsBulkDownload)
    }
}
