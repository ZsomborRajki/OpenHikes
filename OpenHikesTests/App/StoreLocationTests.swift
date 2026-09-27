//
//  StoreLocationTests.swift
//  OpenHikesTests
//
//  The one-time move of the SwiftData stores out of the App Group container.
//
//  Each test points the move at folders of its own under the temporary
//  directory. The defaults are the host app's real Application Support and
//  the real group container, and these tests move files on purpose.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@Suite("Store location")
struct StoreLocationTests {
    private let root = FileManager.default.temporaryDirectory
        .appending(path: "store-location-\(UUID().uuidString)", directoryHint: .isDirectory)

    private var legacy: URL { root.appending(path: "Group/Library/Application Support", directoryHint: .isDirectory) }
    private var directory: URL { root.appending(path: "App/Stores", directoryHint: .isDirectory) }
    private var staging: URL { root.appending(path: "App/Stores.moving", directoryHint: .isDirectory) }

    /// Every file both stores leave in a folder, the external data included.
    private static let storeItems = [
        "Hikes.store", "Hikes.store-wal", "Hikes.store-shm", ".Hikes_SUPPORT",
        "HikeLocalState.store", "HikeLocalState.store-wal", "HikeLocalState.store-shm",
    ]

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    private static func write(_ name: String, in folder: URL, contents: String? = nil) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if name.hasPrefix(".") {
            let external = folder.appending(path: "\(name)/_EXTERNAL_DATA", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
            try Data((contents ?? name).utf8).write(to: external.appending(path: "route"))
        } else {
            try Data((contents ?? name).utf8).write(to: folder.appending(path: name))
        }
    }

    private static func contents(of url: URL) throws -> String {
        try #require(String(bytes: try Data(contentsOf: url), encoding: .utf8))
    }

    @Test("a fresh install gets an empty folder and nothing staged")
    func freshInstall() throws {
        defer { try? FileManager.default.removeItem(at: root) }

        let opened = try StoreLocation.prepare(directory: directory, legacyDirectory: legacy)

        #expect(opened == directory)
        #expect(Self.exists(directory))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).isEmpty)
        #expect(!Self.exists(staging))
    }

    @Test("both stores leave the group container whole, and nothing beside them does")
    func movesEveryStoreFile() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        for name in Self.storeItems {
            try Self.write(name, in: legacy)
        }
        try Self.write("trail-snapshot.json", in: legacy.deletingLastPathComponent().deletingLastPathComponent())
        try Self.write("Other.store", in: legacy)

        try StoreLocation.prepare(directory: directory, legacyDirectory: legacy)

        for name in Self.storeItems {
            #expect(Self.exists(directory.appending(path: name)), "\(name) did not arrive")
            #expect(!Self.exists(legacy.appending(path: name)), "\(name) was left behind")
        }
        #expect(
            try Self.contents(of: directory.appending(path: ".Hikes_SUPPORT/_EXTERNAL_DATA/route"))
                == ".Hikes_SUPPORT"
        )
        #expect(Self.exists(legacy.appending(path: "Other.store")))
        #expect(!Self.exists(directory.appending(path: "Other.store")))
        #expect(!Self.exists(staging))
    }

    /// A launch killed between two renames: the next one has to finish the
    /// same move, not start a fresh store beside half of the old one.
    @Test("a move interrupted part-way is finished by the next launch")
    func resumesAnInterruptedMove() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.write("Hikes.store", in: staging)
        for name in Self.storeItems where name != "Hikes.store" {
            try Self.write(name, in: legacy)
        }

        try StoreLocation.prepare(directory: directory, legacyDirectory: legacy)

        for name in Self.storeItems {
            #expect(Self.exists(directory.appending(path: name)), "\(name) did not arrive")
        }
        #expect(!Self.exists(staging))
    }

    /// What a TestFlight downgrade leaves: an older build made a store in the
    /// group container again. The finished move is not redone over it — a
    /// log from that store beside this database would corrupt it.
    @Test("once the stores have moved, the group container is never read again")
    func finishedMoveIsFinal() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.write("Hikes.store", in: directory, contents: "moved")
        try Self.write("Hikes.store", in: legacy, contents: "recreated")
        try Self.write("Hikes.store-wal", in: legacy)

        try StoreLocation.prepare(directory: directory, legacyDirectory: legacy)

        #expect(try Self.contents(of: directory.appending(path: "Hikes.store")) == "moved")
        #expect(!Self.exists(directory.appending(path: "Hikes.store-wal")))
        #expect(Self.exists(legacy.appending(path: "Hikes.store")))
    }

    /// The part a file-level test cannot show: that SwiftData opens what moved
    /// as the same pair of stores, the sidecar's columns included.
    @Test("a hike saved before the move is there after it")
    func hikeSurvivesTheMove() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let id = UUID()
        do {
            let container = try ModelContainer.openHikes(
                url: StoreLocation.storeURL(StoreLocation.hikes, in: legacy),
                localURL: StoreLocation.storeURL(StoreLocation.localState, in: legacy)
            )
            let context = ModelContext(container)
            let hike = Hike(title: "Before the move", distanceMeters: 1)
            hike.id = id
            hike.route = Fixture.ridgeRoute
            context.insert(hike)
            hike.autoSavedTileKeys = ["osm/16/9/9"]
            try context.save()
        }

        try StoreLocation.prepare(directory: directory, legacyDirectory: legacy)

        let container = try ModelContainer.openHikes(
            url: StoreLocation.storeURL(StoreLocation.hikes, in: directory),
            localURL: StoreLocation.storeURL(StoreLocation.localState, in: directory)
        )
        let context = ModelContext(container)
        let reopened = try #require(
            try context.fetch(FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })).first
        )
        #expect(reopened.title == "Before the move")
        #expect(reopened.route == Fixture.ridgeRoute)
        #expect(reopened.autoSavedTileKeys == ["osm/16/9/9"])
    }

    /// The facts the move cannot check for itself: that it looks where
    /// `.automatic` put the stores, and lands outside every shared container.
    @Test("the defaults are the group's Application Support and the app's own")
    func defaultsAreTheRealFolders() throws {
        #expect(
            StoreLocation.directory.deletingLastPathComponent().standardizedFileURL
                == URL.applicationSupportDirectory.standardizedFileURL
        )
        let group = try #require(StoreLocation.legacyDirectory)
        #expect(group.path(percentEncoded: false).hasSuffix("/Library/Application Support/"))
        #expect(!StoreLocation.directory.path(percentEncoded: false).contains("/Shared/AppGroup/"))
    }
}
