//
//  StagedFilesTests.swift
//  OpenHikesTests
//
//  The launch sweep the Commons photographs' two controllers share: what it
//  removes, and the one directory it has to leave alone.
//
//  Each controller's own suite holds it to its own parent and its own kept
//  directory. What neither can show is the keeping itself, because there the
//  sweep usually lists the parent before the first search has written
//  anything. Here the kept directory is full before the sweep starts.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Staged files")
struct StagedFilesTests {
    /// A parent of the suite's own, so its sweep never reaches another's.
    private final class Parent {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StagedFilesTests-\(UUID().uuidString)", isDirectory: true)

        deinit { try? FileManager.default.removeItem(at: url) }
    }

    private static func directory(holdingAFileIn parent: URL) throws -> URL {
        let directory = StagedFiles.freshDirectory(in: parent)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("staged".utf8).write(to: directory.appendingPathComponent("photo.jpeg"))
        return directory
    }

    @Test("a fresh directory is inside its parent, new every time, and not yet made")
    func freshDirectoriesAreNamedOnly() {
        let parent = Parent()

        let first = StagedFiles.freshDirectory(in: parent.url)
        let second = StagedFiles.freshDirectory(in: parent.url)

        #expect(first.deletingLastPathComponent().standardizedFileURL == parent.url.standardizedFileURL)
        #expect(first != second)
        #expect(!FileManager.default.fileExists(atPath: first.path))
    }

    /// The sweep runs off the main actor, so a search can be writing into the
    /// current directory by the time it lists the parent. Waited out whole:
    /// the current directory can be the last one it reaches.
    @Test("a sweep removes everything an earlier launch left, and keeps the current directory")
    func sweepKeepsTheCurrentDirectory() async throws {
        let parent = Parent()
        let earlier = try Self.directory(holdingAFileIn: parent.url)
        let alsoEarlier = try Self.directory(holdingAFileIn: parent.url)
        let current = try Self.directory(holdingAFileIn: parent.url)

        await StagedFiles.sweep(parent.url, keeping: current).value

        #expect(!FileManager.default.fileExists(atPath: earlier.path))
        #expect(!FileManager.default.fileExists(atPath: alsoEarlier.path))
        #expect(FileManager.default.fileExists(atPath: current.appendingPathComponent("photo.jpeg").path))
    }

    @Test("a sweep of a parent no launch has made yet is not an error")
    func sweepOfAMissingParent() async {
        let parent = Parent()

        await StagedFiles.sweep(parent.url, keeping: StagedFiles.freshDirectory(in: parent.url)).value

        #expect(!FileManager.default.fileExists(atPath: parent.url.path))
    }

    @Test("removing a directory takes what is in it")
    func removeTakesTheContents() async throws {
        let parent = Parent()
        let directory = try Self.directory(holdingAFileIn: parent.url)

        await StagedFiles.remove(directory).value

        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
