//
//  StoreSavesTests.swift
//  OpenHikesTests
//
//  What wakes a task kept true to the Hikes store, and what a look at its
//  history names: see `StoreSaves.swift`. The two tasks built on it, the
//  Hilliest list's and the library's lines, are held to their own effects in
//  `HikeListElevationWatchTests` and `LibraryLinesTests`; this holds the part
//  they share to its word.
//
//  A wake is counted through ``StoreSaves/wakes`` rather than read off the
//  stream, which gathers the wakes that arrive together into one, so a wake
//  that should never have come would otherwise look like none. A save is a
//  remote change posted by hand for a store named by its identifier, as
//  SwiftData posts one. The observer reads it on the posting thread, so by
//  the time the post returns it has been counted or dropped.
//
//  A test that counts wakes exactly names a store first, one no real store
//  is. SwiftData posts a real store's remote change from a thread of its
//  own, so the one for an earlier test's save can still arrive in the middle
//  of a later test, and with no store named it would be counted there.
//

import CoreData
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Synchronization
import Testing

@Suite("Store saves")
@MainActor
struct StoreSavesTests {
    private static let hikesStore = "store-saves-tests-hikes"
    private static let localStore = "store-saves-tests-local"

    private static func postSave(of storeID: String) {
        NotificationCenter.default.post(
            name: .NSPersistentStoreRemoteChange,
            object: nil,
            userInfo: [NSStoreUUIDKey: storeID]
        )
    }

    /// A hike's row in a store of its own, to ask history about.
    private static func row() throws -> (container: ModelContainer, row: PersistentIdentifier) {
        let container = try Fixture.modelContainer()
        let hike = Fixture.hike(in: container.mainContext)
        try container.mainContext.save()
        return (container, hike.persistentModelID)
    }

    /// Where a store on disk goes: emptied once per run, never during one —
    /// see `StoreSandbox` for why.
    private static let sandbox: URL = {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "store-saves", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: root)
        return root
    }()

    /// A token, which only a store's history makes: the one a look hands back
    /// once an import has saved a hike, as the app's first token comes. Both
    /// stores are on disk, as the app opens them.
    private static func importToken() async throws -> DefaultHistoryToken {
        let directory = sandbox.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let container = try ModelContainer.openHikes(
            url: directory.appending(path: "OpenHikes.store"),
            localURL: directory.appending(path: "OpenHikesLocal.store")
        )
        let hike = Fixture.hike(in: container.mainContext)
        try container.mainContext.save()
        let row = hike.persistentModelID
        let storeID = try #require(row.storeIdentifier)
        let since = Date.now
        try await SelectedLineStoreWatchTests.saveElsewhere(hike.id, in: container) { $0.title = "Imported" }
        let answer = await StoreHistoryCheck.answer(StoreHistoryCheck.Request(
            container: container,
            rows: [row],
            storeID: storeID,
            since: since,
            token: nil
        ))
        return try #require(answer.token)
    }

    @Test("the first pass is woken at once")
    func theFirstPassIsWoken() async throws {
        let saves = StoreSaves(in: try Fixture.modelContainer(), store: Self.hikesStore, checking: Looks().look)
        var changes = saves.changes.makeAsyncIterator()
        #expect(await changes.next() != nil)
        #expect(saves.wakes == 1)
    }

    /// Any store's, until one is named: the library names its store from the
    /// hikes it lists, and a library that held nothing at first still has to
    /// hear its first import. A real store's save can wake it too meanwhile,
    /// so that half asks only that this one did.
    @Test("every store's saves wake the task until one is named, and then only its own")
    func onlyTheNamedStoreWakes() throws {
        let saves = StoreSaves(in: try Fixture.modelContainer(), checking: Looks().look)
        let unnamed = saves.wakes
        Self.postSave(of: Self.localStore)
        #expect(saves.wakes > unnamed, "no store is named yet")

        saves.watch(store: Self.hikesStore)
        let named = saves.wakes
        Self.postSave(of: Self.localStore)
        #expect(saves.wakes == named, "dropped on the thread that posted it")
        Self.postSave(of: Self.hikesStore)
        #expect(saves.wakes == named + 1)

        saves.watch(store: nil)
        Self.postSave(of: Self.localStore)
        #expect(saves.wakes == named + 1, "naming nothing keeps the store named before")
    }

    @Test("a look asks about the rows given, in the named store, from when the task began")
    func aLookAsksFromTheStart() async throws {
        let (container, row) = try Self.row()
        let looks = Looks()
        let began = Date.now
        let saves = StoreSaves(in: container, store: Self.hikesStore, checking: looks.look)

        #expect(await saves.savedRows(among: [row]) == [row])
        let request = try #require(looks.requests.first)
        #expect(request.rows == [row])
        #expect(request.storeID == Self.hikesStore)
        #expect(request.since >= began)
        #expect(request.token == nil, "no transaction has given it one")
    }

    @Test("a look with nothing to ask about, or no store named, asks history nothing")
    func nothingToAskAsksNothing() async throws {
        let (container, row) = try Self.row()
        let looks = Looks()

        let unnamed = StoreSaves(in: container, checking: looks.look)
        #expect(await unnamed.savedRows(among: [row]).isEmpty)
        let named = StoreSaves(in: container, store: Self.hikesStore, checking: looks.look)
        #expect(await named.savedRows(among: []).isEmpty)
        #expect(looks.requests.isEmpty)
    }

    /// Naming every row would read every line again, and a failure that held
    /// would ask for one after every look: see the file header of
    /// `StoreSaves.swift`.
    @Test("a look that cannot read history names nothing, and only the first of a run asks again")
    func aFailedLookAsksAgainOnce() async throws {
        let (container, row) = try Self.row()
        let looks = Looks(reads: [false, false, true, false])
        let saves = StoreSaves(in: container, store: Self.hikesStore, checking: looks.look)
        let woken = saves.wakes

        #expect(await saves.savedRows(among: [row]).isEmpty, "the rows it was given back are not named")
        #expect(saves.wakes == woken + 1, "the first failure asks for one more look")
        #expect(await saves.savedRows(among: [row]).isEmpty)
        #expect(saves.wakes == woken + 1, "a failure that holds asks for nothing more")
        #expect(await saves.savedRows(among: [row]) == [row])
        #expect(await saves.savedRows(among: [row]).isEmpty)
        #expect(saves.wakes == woken + 2, "a look that read history starts the run again")
    }

    /// The look after a failed one starts from when the task began, never
    /// from the token held before: an expired token is one reason history
    /// cannot be read, and it would fail every look after it. See the file
    /// header of `StoreSaves.swift`.
    @Test("a look starts from the last look's token, and one after a failed look from when the task began")
    func aLookStartsFromTheLastToken() async throws {
        let (container, row) = try Self.row()
        let token = try await Self.importToken()
        let looks = Looks(reads: [true, true, false, true], token: token)
        let saves = StoreSaves(in: container, store: Self.hikesStore, checking: looks.look)

        for _ in 0..<4 { _ = await saves.savedRows(among: [row]) }

        #expect(looks.requests.map(\.token) == [nil, token, token, nil])
        #expect(Set(looks.requests.map(\.since)).count == 1, "every look reads imports from the same moment")
    }

    @Test("letting the saves go ends the task's stream")
    func lettingGoEndsTheStream() async throws {
        var saves: StoreSaves? = StoreSaves(in: try Fixture.modelContainer(), checking: Looks().look)
        var changes = try #require(saves?.changes).makeAsyncIterator()
        saves = nil
        #expect(await changes.next() != nil, "the first pass's wake")
        #expect(await changes.next() == nil)
    }
}

/// A store's history as a test scripts it: whether each look can read it, in
/// turn, and every request it was asked. A look it reads names every row it
/// was asked about, and hands back `token`. One it cannot read hands the
/// rows back too and no token, as `StoreHistoryCheck` does, for the caller
/// to leave unnamed.
nonisolated private final class Looks: Sendable {
    private let reads: Mutex<[Bool]>
    private let token: DefaultHistoryToken?
    private let asked = Mutex<[StoreHistoryCheck.Request]>([])

    init(reads: [Bool] = [], token: DefaultHistoryToken? = nil) {
        self.reads = Mutex(reads)
        self.token = token
    }

    var requests: [StoreHistoryCheck.Request] { asked.withLock { $0 } }

    @concurrent
    func look(_ request: StoreHistoryCheck.Request) async -> StoreHistoryCheck.Answer {
        asked.withLock { $0.append(request) }
        let wasRead = reads.withLock { $0.isEmpty ? true : $0.removeFirst() }
        return StoreHistoryCheck.Answer(token: wasRead ? token : nil, savedRows: request.rows, wasRead: wasRead)
    }
}
