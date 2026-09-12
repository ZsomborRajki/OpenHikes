//
//  CommunityBlockListTests.swift
//  OpenHikesTests
//

import Foundation
@testable import OpenHikes
import Testing

/// What a block is keyed on, what it survives, and what it must not hide.
@MainActor
@Suite("Community block list")
struct CommunityBlockListTests {
    private static func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "CommunityBlockListTests-\(UUID().uuidString)"))
    }

    @Test("a fresh device blocks nobody")
    func startsEmpty() throws {
        let blocks = CommunityBlockList(defaults: try Self.defaults())
        #expect(blocks.isEmpty)
        #expect(!blocks.isBlocked(.stub()))
    }

    @Test("blocking hides every hike that author published")
    func blockingHidesTheAuthor() throws {
        let blocks = CommunityBlockList(defaults: try Self.defaults())
        let reported = CommunityListing.stub(id: "listing-1", authorID: "author-1")
        let theirOther = CommunityListing.stub(id: "listing-2", authorID: "author-1")
        let somebodyElse = CommunityListing.stub(id: "listing-3", authorID: "author-2")

        blocks.block(reported)

        #expect(blocks.isBlocked(theirOther))
        #expect(!blocks.isBlocked(somebodyElse))
        #expect(
            blocks.excludingBlocked([reported, theirOther, somebodyElse]).map(\.id)
                == ["listing-3"]
        )
    }

    /// The whole reason the schema gained a field. `authorName` is free text
    /// the hiker types on every submission, so blocking on it would block a
    /// string — and would fail open for the one person it is meant to stop,
    /// who need only type something else next time.
    @Test("a block follows the author and not the name they typed")
    func blockingIsKeyedOnIdentityRatherThanName() throws {
        let blocks = CommunityBlockList(defaults: try Self.defaults())
        blocks.block(.stub(id: "listing-1", authorName: "Anna", authorID: "author-1"))

        // Same person, a different name on the next submission: still blocked.
        #expect(blocks.isBlocked(.stub(id: "listing-2", authorName: "A.", authorID: "author-1")))
        // A different person who happens to have typed the same name: not.
        #expect(!blocks.isBlocked(.stub(id: "listing-3", authorName: "Anna", authorID: "author-2")))
    }

    @Test("unblocking gives their hikes back")
    func unblockingIsReversible() throws {
        let blocks = CommunityBlockList(defaults: try Self.defaults())
        let listing = CommunityListing.stub(authorID: "author-1")
        blocks.block(listing)
        blocks.unblock("author-1")

        #expect(blocks.isEmpty)
        #expect(!blocks.isBlocked(listing))
        #expect(blocks.excludingBlocked([listing]).count == 1)
    }

    @Test("unblocking everyone empties the list")
    func unblockAllClearsIt() throws {
        let blocks = CommunityBlockList(defaults: try Self.defaults())
        blocks.block(.stub(id: "listing-1", authorID: "author-1"))
        blocks.block(.stub(id: "listing-2", authorID: "author-2"))
        blocks.unblockAll()

        #expect(blocks.isEmpty)
        #expect(blocks.authors.isEmpty)
    }

    @Test("a repeated block keeps its original name, date and position")
    func blockingIsIdempotent() throws {
        let defaults = try Self.defaults()
        let blocks = CommunityBlockList(defaults: defaults)
        let earlier = Date(timeIntervalSince1970: 1_750_000_000)
        blocks.block(.stub(authorName: "Anna", authorID: "author-1"), at: earlier)
        blocks.block(.stub(authorName: "Bence", authorID: "author-2"), at: earlier.addingTimeInterval(60))
        let original = blocks.authors
        blocks.block(.stub(authorName: "Renamed", authorID: "author-1"), at: earlier.addingTimeInterval(120))

        #expect(blocks.authors == original)
        #expect(CommunityBlockList(defaults: defaults).authors == original)
    }

    @Test("removing a middle block preserves order and reblocking puts it first")
    func removalAndReblockingPreserveOrder() throws {
        let defaults = try Self.defaults()
        let blocks = CommunityBlockList(defaults: defaults)
        for id in ["author-1", "author-2", "author-3"] {
            blocks.block(.stub(authorID: id))
        }
        let snapshot = blocks.blockedIDs
        blocks.unblock("author-2")
        blocks.unblock("not-blocked")
        #expect(blocks.authors.map(\.id) == ["author-3", "author-1"])
        #expect(blocks.blockedIDs == ["author-1", "author-3"])
        #expect(snapshot == ["author-1", "author-2", "author-3"])
        #expect(CommunityBlockList(defaults: defaults).authors == blocks.authors)

        blocks.block(.stub(authorID: "author-2"))
        #expect(blocks.authors.map(\.id) == ["author-2", "author-3", "author-1"])
        #expect(CommunityBlockList(defaults: defaults).authors == blocks.authors)
        blocks.unblockAll()
        #expect(blocks.blockedIDs.isEmpty)
        #expect(CommunityBlockList(defaults: defaults).isEmpty)
    }

    @Test("storage stays an ordered array of blocked authors")
    func storageKeepsItsArrayShape() throws {
        let defaults = try Self.defaults()
        let stored = [
            CommunityBlockList.BlockedAuthor(id: "author-2", name: "Bence", blockedAt: .distantFuture),
            CommunityBlockList.BlockedAuthor(id: "author-1", name: "Anna", blockedAt: .distantPast),
        ]
        defaults.set(try JSONEncoder().encode(stored), forKey: SettingsKey.communityBlockedAuthors)
        let blocks = CommunityBlockList(defaults: defaults)
        #expect(blocks.authors == stored)
        #expect(blocks.blockedIDs == ["author-1", "author-2"])
        blocks.block(.stub(authorID: "author-3"))

        let data = try #require(defaults.data(forKey: SettingsKey.communityBlockedAuthors))
        let decoded = try JSONDecoder().decode([CommunityBlockList.BlockedAuthor].self, from: data)
        #expect(decoded == blocks.authors)
        #expect(Array(decoded.dropFirst()) == stored)
    }

    /// Settings draws this list, and the entry a hiker just made is the one
    /// they are most likely to have made by accident.
    @Test("the newest block is listed first, with the name and the day")
    func theListIsOrderedForUndoing() throws {
        let blocks = CommunityBlockList(defaults: try Self.defaults())
        let earlier = Date(timeIntervalSince1970: 1_750_000_000)
        blocks.block(.stub(authorName: "Anna", authorID: "author-1"), at: earlier)
        blocks.block(
            .stub(authorName: "Bence", authorID: "author-2"),
            at: earlier.addingTimeInterval(60)
        )

        #expect(blocks.authors.map(\.name) == ["Bence", "Anna"])
        #expect(blocks.authors.first?.blockedAt == earlier.addingTimeInterval(60))
    }

    /// A block list that forgot itself on the next launch would be a block
    /// that quietly stopped working — and the hiker would never be told.
    @Test("a block survives the launch it was made in")
    func blocksArePersisted() throws {
        let defaults = try Self.defaults()
        CommunityBlockList(defaults: defaults).block(.stub(authorName: "Anna", authorID: "author-1"))

        let reopened = CommunityBlockList(defaults: defaults)
        #expect(reopened.isBlocked(.stub(id: "listing-9", authorID: "author-1")))
        #expect(reopened.authors.map(\.name) == ["Anna"])
    }

    /// The failure a block list must not have. An author-less listing cannot
    /// reach this from CloudKit — `CommunityListing.init(record:)` drops the
    /// record — but if one ever did, adding an empty key would hide every
    /// *other* listing missing the same field.
    @Test("a listing naming no author cannot be blocked")
    func anEmptyAuthorIsRefused() throws {
        let blocks = CommunityBlockList(defaults: try Self.defaults())
        blocks.block(.stub(id: "listing-1", authorID: ""))

        #expect(blocks.isEmpty)
        #expect(!blocks.isBlocked(.stub(id: "listing-2", authorID: "")))
    }

    /// Unreadable stored data reads as "nobody is blocked", which is the
    /// reading that shows content a hiker asked not to see — so it must at
    /// least not take the app down with it, and must not erase what it could
    /// not read.
    @Test("unreadable stored blocks leave the list empty rather than failing")
    func corruptStorageIsSurvivable() throws {
        let defaults = try Self.defaults()
        defaults.set(Data("not json".utf8), forKey: SettingsKey.communityBlockedAuthors)

        #expect(CommunityBlockList(defaults: defaults).isEmpty)
        #expect(defaults.data(forKey: SettingsKey.communityBlockedAuthors) != nil)
    }
}
