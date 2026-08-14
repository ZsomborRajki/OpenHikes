//
//  GPXInboxTests.swift
//  OpenHikesTests
//
//  The app now appears in the Files app's "Open With" list, which also opts it
//  into deliveries that copy rather than open in place. What matters here is
//  the distinction: a copy in `Documents/Inbox` is the app's to remove, and a
//  file the user picked from Files is emphatically not — deleting one of those
//  would take a document out of somebody's iCloud Drive.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("GPX inbox cleanup")
struct GPXInboxTests {
    /// A stand-in for the container's `Documents/Inbox`, so the checks below
    /// never depend on — or write into — the test host's real container.
    private func makeInbox() throws -> URL {
        let inbox = FileManager.default.temporaryDirectory
            .appending(path: "Inbox-\(UUID().uuidString)")
            .appending(path: "Inbox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: inbox,
            withIntermediateDirectories: true
        )
        return inbox
    }

    @discardableResult
    private func writeFile(named name: String, in directory: URL) throws -> URL {
        let url = directory.appending(path: name)
        try Data("<gpx/>".utf8).write(to: url)
        return url
    }

    @Test("A file in the inbox is a copy the app owns")
    func recognisesCopy() throws {
        let inbox = try makeInbox()
        let copied = try writeFile(named: "route.gpx", in: inbox)

        #expect(GPXInbox.isCopy(copied, inbox: inbox))
    }

    @Test("A picked file outside the inbox is left alone")
    func ignoresPickedFile() throws {
        let inbox = try makeInbox()
        let picked = try writeFile(
            named: "picked-\(UUID().uuidString).gpx",
            in: FileManager.default.temporaryDirectory
        )
        defer { try? FileManager.default.removeItem(at: picked) }

        #expect(!GPXInbox.isCopy(picked, inbox: inbox))
    }

    /// The two paths reach the same directory by different routes — one
    /// through the resolved container path, one through the symlinked one —
    /// so comparing them unresolved would call a copy a picked file and leak
    /// it.
    @Test("A symlinked inbox path still names a copy")
    func resolvesSymlinks() throws {
        let inbox = try makeInbox()
        let copied = try writeFile(named: "route.gpx", in: inbox)
        let link = FileManager.default.temporaryDirectory
            .appending(path: "link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: inbox
        )
        defer { try? FileManager.default.removeItem(at: link) }

        #expect(GPXInbox.isCopy(link.appending(path: "route.gpx"), inbox: inbox))
        #expect(GPXInbox.isCopy(copied, inbox: link))
    }

    /// Nothing was ever copied in if there's no inbox, so nothing is claimed.
    @Test("No inbox means nothing is a copy")
    func toleratesMissingInbox() throws {
        let picked = try writeFile(
            named: "picked-\(UUID().uuidString).gpx",
            in: FileManager.default.temporaryDirectory
        )
        defer { try? FileManager.default.removeItem(at: picked) }

        #expect(!GPXInbox.isCopy(picked, inbox: nil))
    }

    @Test("Discarding removes a copy from the real inbox")
    func discardsCopy() async throws {
        let inbox = try #require(GPXInbox.directory)
        let existed = FileManager.default.fileExists(atPath: inbox.path)
        try FileManager.default.createDirectory(
            at: inbox,
            withIntermediateDirectories: true
        )
        defer {
            // Only tidy away a directory this test brought into being; the
            // host app's own inbox, if it had one, is not ours to remove.
            if !existed { try? FileManager.default.removeItem(at: inbox) }
        }
        let copied = try writeFile(
            named: "delivered-\(UUID().uuidString).gpx",
            in: inbox
        )

        await GPXInbox.discardCopy(at: copied)

        #expect(!FileManager.default.fileExists(atPath: copied.path))
    }

    @Test("Discarding never touches a picked file")
    func keepsPickedFile() async throws {
        let picked = try writeFile(
            named: "picked-\(UUID().uuidString).gpx",
            in: FileManager.default.temporaryDirectory
        )
        defer { try? FileManager.default.removeItem(at: picked) }

        await GPXInbox.discardCopy(at: picked)

        #expect(FileManager.default.fileExists(atPath: picked.path))
    }
}
