//
//  TileURLRedactionTests.swift
//  OpenHikesTests
//
//  The DEBUG tile logs are the one place a resolved tile URL is written down,
//  and two of the four providers bill against a key carried in that URL's
//  query. A leak here doesn't break the app — it hands out a live credential
//  in any sysdiagnose or screen-shared debug session, which is why the rule is
//  pinned rather than left to a reviewer noticing the next `absoluteString`.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Tile URL redaction")
struct TileURLRedactionTests {
    /// Distinctive enough that a partial leak — a substring surviving some
    /// encoding step — still fails the search below.
    private static let apiKey = "s3cr3t-billable-key"
    private static let tile = OfflineTileDownloader.Tile(z: 14, x: 8723, y: 5685)

    private static func resolvedURL(for provider: TileProvider) throws -> URL {
        try #require(tile.url(from: provider.resolvedTemplate(apiKey: apiKey)))
    }

    /// The issue itself: a resolved URL for a key-gated provider must not carry
    /// the key into the log, whatever that provider calls the query item —
    /// Stadia says `api_key`, Thunderforest says `apikey`.
    @Test("no provider's key survives into the log", arguments: TileProvider.rasterSources)
    func keysAreRedacted(provider: TileProvider) throws {
        let logged = try Self.resolvedURL(for: provider).redactedForLogging
        #expect(!logged.contains(Self.apiKey))
    }

    /// Redaction that also destroyed the tile coordinates would be a fix
    /// nobody keeps: the whole point of the line is which tile was requested.
    @Test("the tile is still identifiable", arguments: TileProvider.rasterSources)
    func coordinatesAndHostSurvive(provider: TileProvider) throws {
        let url = try Self.resolvedURL(for: provider)
        let logged = url.redactedForLogging
        #expect(logged.contains("14/8723/5685"))
        #expect(logged.contains(try #require(url.host())))
    }

    /// The names are what tell "sent with a key" apart from "sent without
    /// one", which is the failure the log is usually being read to diagnose.
    @Test("query names are kept")
    func namesSurvive() throws {
        #expect(try Self.resolvedURL(for: .stadiaOutdoors).redactedForLogging.contains("api_key=redacted"))
        let thunderforest = try Self.resolvedURL(for: .thunderforestOutdoors).redactedForLogging
        #expect(thunderforest.contains("apikey=redacted"))
    }

    /// A keyless provider has nothing to hide, and its URL is logged whole.
    @Test("a URL with no query is unchanged")
    func keylessURLsAreUntouched() throws {
        let url = try #require(Self.tile.url(from: TileProvider.openStreetMap.urlTemplate))
        #expect(url.redactedForLogging == url.absoluteString)
    }

    /// Redaction is by position, not by name: a key smuggled in under a name
    /// nobody added to a list is still gone.
    @Test("every query value goes, not just the ones named like a key")
    func redactionIsNotNameBased() throws {
        let url = try #require(URL(string: "https://example.com/1/2/3.png?token=abc&style=night"))
        let logged = url.redactedForLogging
        #expect(!logged.contains("abc"))
        #expect(!logged.contains("night"))
        #expect(logged.contains("token=redacted"))
        #expect(logged.contains("style=redacted"))
    }
}
