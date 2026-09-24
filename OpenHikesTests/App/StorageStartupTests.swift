//
//  StorageStartupTests.swift
//  OpenHikesTests
//
//  The store-open failure path: what the app does when SwiftData will not open
//  the store the user's hikes live in.
//
//  This suite starts with an unreadable store. That
//  failing launch still has to be survivable: the app has to come up, say so,
//  and leave what is on disk alone. A crash here turns "your saved hikes are
//  unavailable this launch" into "the app is broken", and a silent fallback
//  is worse still — a user editing an in-memory store all day and losing it at
//  the next launch.
//
//  This suite and the two split out of it — `StoreFailureAttributionTests`
//  and `StorageStartupAlertTests` — drive real SwiftData failures, a store
//  file that is not a store, rather than a synthetic `Error`: the questions
//  worth asking are what SwiftData actually raises and what survives it. They
//  share `StartupStoreSandbox` below, which is why it is not `private`.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import SwiftUI
import Testing

/// A directory holding a `Hikes`/`HikeLocalState` pair, either of which can be
/// corrupted before the container is opened.
///
/// A class rather than a value type so `deinit` does the cleanup: Swift Testing
/// gives a suite instance per test, so the sandbox's lifetime is already
/// exactly the test's. Same arrangement, and same reason, as ``TileSandbox``.
nonisolated final class StartupStoreSandbox: Sendable {
    let root: URL
    let hikesURL: URL
    let localURL: URL

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-sandbox-\(UUID().uuidString)", isDirectory: true)
        hikesURL = root.appendingPathComponent("Hikes.store")
        localURL = root.appendingPathComponent("HikeLocalState.store")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// Makes `url` something SwiftData cannot open, the way a truncated write
    /// would: the file is there, and it is not a store.
    func corrupt(_ url: URL) throws {
        try Data("this is not a SQLite database".utf8).write(to: url)
    }

    @MainActor
    func openContainer() throws -> ModelContainer {
        try ModelContainer.openHikes(url: hikesURL, localURL: localURL)
    }

    @MainActor
    func inMemoryFallback() throws -> ModelContainer {
        try ModelContainer.openHikes(isStoredInMemoryOnly: true)
    }
}

@MainActor
@Suite("Store open failure")
struct StoreOpenFailureTests {
    private static let claimedTileKey = "osm/14/8723/5685@2.0"

    /// The premise everything below rests on: an unreadable store makes
    /// SwiftData throw rather than open something empty. If this stopped being
    /// true the app would come up with a blank hike list and no alert, which is
    /// the one outcome worse than the alert.
    @Test("an unreadable store file makes the container throw rather than open empty")
    func corruptStoreThrows() throws {
        let sandbox = StartupStoreSandbox()
        try sandbox.corrupt(sandbox.hikesURL)

        #expect(throws: (any Error).self) {
            try sandbox.openContainer()
        }
    }

    /// The whole branch in one test: a real store that will not open produces a
    /// real ``StorageStartupIssue``, and the launch continues on the fallback
    /// rather than ending in a crash.
    @Test("an unreadable store falls back to temporary storage and reports it")
    func corruptStoreFallsBackAndReports() throws {
        let sandbox = StartupStoreSandbox()
        try sandbox.corrupt(sandbox.hikesURL)

        let load = try OpenHikesModel.loadContainer(
            persistent: { try sandbox.openContainer() },
            fallback: { try sandbox.inMemoryFallback() }
        )

        let issue = try #require(load.startupIssue, "a failed open the user is never told about is the bug")
        #expect(!issue.underlyingDescription.isEmpty)
    }

    /// And the fallback is a container the app can actually run on. One that
    /// opens but cannot hold a `Hike`, or carries only the mirrored half of the
    /// pair, would turn the failed launch into a crash one screen later.
    @Test("the fallback container still holds both stores")
    func fallbackContainerIsUsable() throws {
        let sandbox = StartupStoreSandbox()
        try sandbox.corrupt(sandbox.hikesURL)

        let load = try OpenHikesModel.loadContainer(
            persistent: { try sandbox.openContainer() },
            fallback: { try sandbox.inMemoryFallback() }
        )
        let context = ModelContext(load.container)
        let hike = Fixture.hike(in: context, title: "Written to the fallback")
        // The sidecar too: they come as a pair, and a container with only the
        // mirrored half fails at the first tile a hike tries to claim.
        hike.autoSavedTileKeys = [Self.claimedTileKey]

        #expect(try context.fetch(FetchDescriptor<Hike>()).count == 1)
        #expect(hike.autoSavedTileKeys == [Self.claimedTileKey])
    }

    /// A store the app has written and can read again — the common case, and
    /// the one a suite of corrupt-file tests could quietly stop covering. If
    /// the URL pair were wrong, every test above would "pass" against a store
    /// that had never opened successfully in the first place.
    @Test("a store written once reopens with its hike intact")
    func writtenStoreReopens() throws {
        let sandbox = StartupStoreSandbox()
        let written = ModelContext(try sandbox.openContainer())
        let identifier = Fixture.hike(in: written, title: "Survives a reopen").id
        try written.save()

        let load = try OpenHikesModel.loadContainer(
            persistent: { try sandbox.openContainer() },
            fallback: { try sandbox.inMemoryFallback() }
        )
        let reopened = ModelContext(load.container)

        #expect(load.startupIssue == nil)
        #expect(try reopened.fetch(FetchDescriptor<Hike>()).first?.id == identifier)
    }
}
