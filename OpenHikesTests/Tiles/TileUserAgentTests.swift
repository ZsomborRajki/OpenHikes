//
//  TileUserAgentTests.swift
//  OpenHikesTests
//
//  Who the app says it is when it asks a tile server for something.
//
//  OpenStreetMap's tile usage policy asks for a User-Agent that identifies
//  the application *and* offers a way to make contact, so that a client
//  behaving badly can be told rather than only blocked; Overpass's policy asks
//  the same, and `OverpassTrailGraphProvider` sends this same string. Both
//  halves are therefore under test here: an identifying name that carries the
//  version actually running, and a contact that a stranger could use.
//
//  `TileTransportTests` pins the header against the string the app builds;
//  this pins the string itself, which is the half a copied constant could not
//  catch.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Tile user agent", .serialized)
struct TileUserAgentTests {

    /// The whole header, spelled out. A shape assertion (`hasPrefix`,
    /// `contains`) would pass on a string that had lost the contact and kept
    /// the name, which is exactly the state this replaces.
    @Test("the header names the app, its version and a contact")
    func headerIsIdentifyingAndContactable() throws {
        let version = try #require(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            "the test host is an app bundle, so it has a version"
        )
        #expect(TileCache.userAgent == "OpenHikes/\(version) (iOS; +\(TileCache.repositoryURL))")
    }

    /// The version is read from the bundle rather than written out, because a
    /// literal is a second place the version lives and the one nobody
    /// remembers to bump. This is what would fail if it went back to being a
    /// literal: the two agree today, and only one of them can still be right
    /// after a release.
    @Test("the version is the bundle's, not a literal")
    func versionComesFromTheBundle() throws {
        let version = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        #expect(TileCache.userAgent.contains("OpenHikes/\(version) "))
    }

    /// The contact has to be something a tile operator can actually reach,
    /// and something this project can keep answering after whoever wrote it
    /// has moved on — which is why it is the repository and not an address.
    @Test("the contact is the public repository")
    func contactIsTheRepository() throws {
        let contact = try #require(URL(string: TileCache.repositoryURL))
        #expect(contact.scheme == "https")
        #expect(contact.host() == "github.com")
        #expect(!TileCache.userAgent.contains("@"), "an address in a shipped binary cannot be revoked")
    }

    /// The wire, not the constant: OSM sees what `URLSession` sends, and a
    /// configuration that dropped the header would leave every assertion
    /// above true and the policy still unmet.
    @Test("a tile request carries the contact to the server")
    func requestsCarryTheContact() async {
        StubTileProtocol.reset()
        defer { StubTileProtocol.reset() }
        let sandbox = TileSandbox(sessionConfiguration: StubTileProtocol.sessionConfiguration())
        StubTileProtocol.alwaysRespond(with: .tile())
        guard let url = URL(string: "https://tiles.example.invalid/14/2638/6357.png") else {
            preconditionFailure("Invalid test URL")
        }

        await sandbox.cache.loadTile(forKey: "osm/14/2638/6357@2.0", url: url)

        let sent = StubTileProtocol.requests.first?.value(forHTTPHeaderField: "User-Agent")
        #expect(sent == TileCache.userAgent)
        #expect(sent?.contains(TileCache.repositoryURL) == true)
    }
}
