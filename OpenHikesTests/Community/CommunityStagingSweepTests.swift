//
//  CommunityStagingSweepTests.swift
//  OpenHikesTests
//
//  What clears up after a preview or a share that was killed.
//
//  Both halves of Community remove their own temporary directory on the way
//  out — `onDisappear` for a preview, a `defer` for a share — and both of
//  those are code that has to get to run. Being killed mid-upload is the
//  ordinary end of a long share in the background, and every name is unique
//  per attempt, so an orphan is never reused and never tidied away by the next
//  visit. These are the two things that make the sweep possible: one parent
//  holding everything it may delete, and a date deciding what is finished.
//
//  The lifetime itself is deliberately not asserted here. What it has to be
//  longer than is a download over a bad connection, which no suite can
//  measure; what these can hold it to is the shape — an entry still being
//  written into survives, an entry nothing has touched since before the cutoff
//  does not.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Community staging sweep")
struct CommunityStagingSweepTests {
    private static let listing = CommunityListing.stub(id: "pilis")

    /// The sweep only ever lists one directory, so a name written anywhere
    /// else under `tmp` would outlive every preview and share that could
    /// remove it.
    @Test("both halves stage under the one directory the sweep reaches")
    func bothHalvesStageUnderTheSweptParent() {
        let preview = CommunityStaging.previewDirectory(of: Self.listing, in: UUID())
        let share = CommunityStaging.shareDirectory(of: UUID())

        let parent = CommunityStaging.directory.standardizedFileURL
        #expect(preview.deletingLastPathComponent().standardizedFileURL == parent)
        #expect(share.deletingLastPathComponent().standardizedFileURL == parent)
    }

    /// The half of each name that is not unique, kept because the unique half
    /// says nothing to a person looking at a temporary directory and asking
    /// what left it behind.
    @Test("a staged name says which half of Community wrote it")
    func aStagedNameNamesItsOwner() {
        let preview = CommunityStaging.previewDirectory(of: Self.listing, in: UUID())
        let share = CommunityStaging.shareDirectory(of: UUID())

        #expect(preview.lastPathComponent.hasPrefix("CommunityHike-"))
        #expect(preview.lastPathComponent.contains(Self.listing.id))
        #expect(share.lastPathComponent.hasPrefix("CommunityShare-"))
    }

    /// Moved here from the screen and the publisher, so this is the same
    /// promise each made before: two visits to one listing, and two attempts
    /// at one hike, never share a path. A discard removes a *path* once its
    /// own work has finished, and the work of an attempt that has gone knows
    /// nothing about the one that replaced it.
    @Test("two attempts at the same thing never share a directory")
    func attemptsNeverShareADirectory() {
        let hike = UUID()
        let leftVisit = CommunityStaging.previewDirectory(of: Self.listing, in: UUID())
        let rightVisit = CommunityStaging.previewDirectory(of: Self.listing, in: UUID())
        let leftAttempt = CommunityStaging.shareDirectory(of: hike)
        let rightAttempt = CommunityStaging.shareDirectory(of: hike)

        #expect(leftVisit != rightVisit)
        #expect(leftAttempt != rightAttempt)
    }

    /// And the other side of that: one attempt asking twice is one directory,
    /// or a screen redrawn mid-download would start writing somewhere else.
    @Test("one attempt's directory is the same directory every time it is asked")
    func oneAttemptKeepsOneDirectory() {
        let visit = UUID()
        let hike = UUID()
        let attempt = UUID()
        let onOpening = CommunityStaging.previewDirectory(of: Self.listing, in: visit)
        let onReturning = CommunityStaging.previewDirectory(of: Self.listing, in: visit)
        let onStaging = CommunityStaging.shareDirectory(of: hike, attempt: attempt)
        let onUploading = CommunityStaging.shareDirectory(of: hike, attempt: attempt)

        #expect(onOpening == onReturning)
        #expect(onStaging == onUploading)
    }

    @Test("the sweep takes entries older than the cutoff and leaves the rest")
    func purgesOnlyStaleEntries() throws {
        let parent = try Self.parent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let cutoff = Date.now.addingTimeInterval(-60)
        let abandoned = try Self.stage(
            "CommunityShare-abandoned",
            in: parent,
            modified: cutoff.addingTimeInterval(-60)
        )
        let current = try Self.stage("CommunityHike-current", in: parent)

        CommunityStaging.purgeAbandoned(in: parent, before: cutoff)

        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(FileManager.default.fileExists(atPath: current.path))
    }

    /// The case the lifetime exists for, and the one that costs the hiker
    /// something when it is wrong.
    ///
    /// A preview can be opened over one that is still downloading — a map pin
    /// pushes a second preview over an open one — and the new one sweeps. The
    /// old visit's directory was *created* before the cutoff; what makes it
    /// live is that a stranger's photographs are still landing in it, and each
    /// one moves the directory's own timestamp forward. Deleting it would take
    /// the pictures out from under a screen the hiker is one Back from
    /// returning to.
    @Test("a download still writing survives the next preview's sweep")
    func sparesADownloadStillWriting() throws {
        let parent = try Self.parent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let cutoff = Date.now.addingTimeInterval(-60)
        let slow = try Self.stage(
            "CommunityHike-slow",
            in: parent,
            modified: cutoff.addingTimeInterval(-600)
        )

        // The next photograph of the download lands.
        try Data("jpeg".utf8).write(
            to: slow.appending(path: "2.jpg", directoryHint: .notDirectory)
        )
        CommunityStaging.purgeAbandoned(in: parent, before: cutoff)

        #expect(FileManager.default.fileExists(atPath: slow.path))
    }

    /// A directory that was never created is the state before the first
    /// preview of the run, and every preview starts by sweeping — so this is
    /// the common case rather than an edge one, and it must not fail the fetch
    /// the hiker is waiting on.
    @Test("sweeping a directory that was never created does nothing")
    func purgesMissingParentQuietly() {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "absent-\(UUID().uuidString)", directoryHint: .isDirectory)

        CommunityStaging.purgeAbandoned(in: missing, before: .now)

        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }
}

private extension CommunityStagingSweepTests {
    /// A stand-in for ``CommunityStaging/directory``, so a suite sweeping
    /// never reaches a directory a parallel test is downloading into.
    static func parent() throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appending(path: "staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return parent
    }

    static func stage(_ name: String, in parent: URL, modified: Date? = nil) throws -> URL {
        let directory = parent.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("jpeg".utf8).write(
            to: directory.appending(path: "1.jpg", directoryHint: .notDirectory)
        )
        guard let modified else { return directory }
        try FileManager.default.setAttributes(
            [.modificationDate: modified],
            ofItemAtPath: directory.path
        )
        return directory
    }
}
