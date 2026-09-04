//
//  HikeImportTests.swift
//  OpenHikesTests
//
//  What "imported" has to mean before anything is allowed to act on it.
//
//  Parsing is covered by the `GPXImport*` suites; this one owns the half after
//  it, which is the half that can lose a walk. An import that reports success
//  is immediately treated as a hike the walker has — it is selected, drawn,
//  and for a file the system copied into the app, ``GPXInbox`` deletes the
//  only copy OpenHikes controls. An insert alone does not earn that: it is a
//  change pending in a context, and a store that refuses the commit, or a
//  process that ends before autosave reaches it, leaves the walker with a hike
//  that was on screen, is not on disk, and whose source file was thrown away
//  in the meantime.
//
//  So what is checked here is what that reported success stands on: that a
//  hike said to be imported is in a store opened fresh, and that a save the
//  store refused takes the row back out, says *storage* rather than blaming
//  the file, and leaves the copy the app was reading from alone.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Synchronization
import Testing

@Suite("Hike import")
struct HikeImportTests {
    /// Three points in one track: the smallest file that is a route rather
    /// than a pin.
    private static let ridgeGPX = """
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx version="1.1" creator="OpenHikesTests" xmlns="http://www.topografix.com/GPX/1/1">
        <trk><name>Thumsee Loop</name><trkseg>
        <trkpt lat="47.6300" lon="12.8600"/>
        <trkpt lat="47.6310" lon="12.8600"/>
        <trkpt lat="47.6320" lon="12.8600"/>
        </trkseg></trk>
    </gpx>
    """

    /// One point: a pin, and the file the import's own policy refuses.
    private static let singlePointGPX = """
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
        <trk><trkseg><trkpt lat="47.6300" lon="12.8600"/></trkseg></trk>
    </gpx>
    """

    private func writeGPX(_ xml: String, in directory: URL) throws -> URL {
        let url = directory.appending(path: "route-\(UUID().uuidString).gpx")
        try Data(xml.utf8).write(to: url)
        return url
    }

    /// A directory of this test's own, for the store files and the .gpx.
    private func makeSandbox() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "hikeimport-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    /// Runs one import the way `OpenHikesView` does — as an outcome rather
    /// than as a throw — so the rule that decides the copy's fate can be asked
    /// of the result.
    private func outcome(
        importing url: URL,
        into context: ModelContext,
        save: @Sendable (ModelContext) throws -> Void = { try $0.save() }
    ) async -> HikeImportOutcome {
        do throws(HikeImportFailure) {
            return .imported(
                try await HikeImport.hike(from: url, into: context, save: save)
            )
        } catch {
            return .refused(error)
        }
    }

    /// A container over this sandbox's own files. Deliberately not
    /// in-memory: what is being asked is what a relaunch would find.
    private func openStore(in sandbox: URL) throws -> ModelContext {
        ModelContext(
            try ModelContainer.openHikes(
                url: sandbox.appending(path: "OpenHikes.store"),
                localURL: sandbox.appending(path: "OpenHikesLocal.store")
            )
        )
    }

    /// The failure an outcome carries, or `nil` if it produced a hike.
    private func refusal(_ outcome: HikeImportOutcome) -> HikeImportFailure? {
        guard case .refused(let failure) = outcome else { return nil }
        return failure
    }

    // MARK: What a reported success is worth

    /// The claim an import makes by returning a hike, checked against the only
    /// thing that can contradict it: a container opened over the same files
    /// with nothing left in memory to answer from.
    @Test("a hike reported as imported is in a store opened fresh")
    func importedHikeSurvivesAReopen() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let file = try writeGPX(Self.ridgeGPX, in: sandbox)

        let id: UUID
        do {
            let context = try openStore(in: sandbox)
            // Deliberately nothing else: a `save()` from the suite here would
            // be the test passing on the import's behalf.
            id = try await HikeImport.hike(from: file, into: context).id
        }

        let reopened = try openStore(in: sandbox).fetch(
            FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })
        )
        #expect(reopened.count == 1)
        #expect(reopened.first?.route.count == 3)
    }

    // MARK: A store that says no

    @Test("a refused save is reported as a storage failure")
    func refusedSaveIsReportedAsAFailure() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let file = try writeGPX(Self.ridgeGPX, in: sandbox)
        let context = try Fixture.modelContext()

        // Discarded rather than returned: `#expect(throws:)` hands its
        // closure's result back as `sending`, and a `Hike` is main-actor
        // isolated.
        await #expect(throws: HikeImportFailure.notSaved) {
            _ = try await HikeImport.hike(from: file, into: context) { _ in
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    /// The row goes with the failure. Left anywhere a later commit could pick
    /// it up, it is a hike the walker was told they don't have, waiting for
    /// whichever save does succeed to put it on the list without a word.
    @Test("a refused save leaves no hike behind to land later")
    func refusedSaveLeavesNothingInserted() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let file = try writeGPX(Self.ridgeGPX, in: sandbox)

        do {
            let context = try openStore(in: sandbox)
            _ = await outcome(importing: file, into: context) { _ in
                throw CocoaError(.fileWriteUnknown)
            }

            // The fetch the hikes list runs — the screen's own context,
            // which is the one a `@Query` draws from …
            let remaining = try context.fetch(FetchDescriptor<Hike>())
            #expect(remaining.isEmpty)
            // … and then the commit that would have been the quiet second
            // chance: the app saves this context on every autosave tick, and
            // again when the scene leaves the foreground.
            try context.save()
        }

        let afterALaterSave = try openStore(in: sandbox).fetch(FetchDescriptor<Hike>())
        #expect(
            afterALaterSave.isEmpty,
            "a save the walker was told failed must not land at the next one"
        )
    }

    /// Serializing an externally stored route is the longest thing an import
    /// does — hundreds of milliseconds for a walk of a few hundred thousand
    /// points — and it lands while the document picker is still dismissing.
    /// The parse has always been off-main; the commit is the larger half and
    /// has to be as well, which is a property of the seam rather than of any
    /// one file size.
    @Test("the commit does not run on the main thread")
    func commitStaysOffTheMainThread() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let file = try writeGPX(Self.ridgeGPX, in: sandbox)
        let context = try openStore(in: sandbox)

        let sawMainThread = Mutex(true)
        let result = await outcome(importing: file, into: context) { writing in
            sawMainThread.withLock { $0 = Thread.isMainThread }
            try writing.save()
        }

        #expect(result.hike != nil)
        #expect(!sawMainThread.withLock { $0 })
    }

    /// The alert has to name the half that actually failed: a GPX message
    /// sends the walker off to inspect a file that read perfectly. The parse
    /// copy still has to arrive unchanged for the failures that *are* the
    /// file's, which is the whole reason the two are one type.
    @Test("a refused save says storage rather than blaming the file")
    func storageFailureDoesNotBlameTheFile() {
        #expect(
            HikeImportFailure.notSaved.errorDescription
                != HikeImportFailure.file(.unreadable).errorDescription
        )
        for failure in GPXImport.ImportFailure.allCases {
            #expect(
                HikeImportFailure.file(failure).errorDescription
                    == failure.errorDescription
            )
            #expect(
                HikeImportFailure.file(failure).recoverySuggestion
                    == failure.recoverySuggestion
            )
        }
    }

    // MARK: The copy the app owns

    /// The data-loss case the ordering exists for. The file arrived as a copy,
    /// so it is the only source OpenHikes controls, and discarding it on the
    /// strength of an insert that was never committed loses the walk outright.
    @Test("a refused save keeps the inbox copy it was read from")
    func refusedSaveKeepsTheInboxCopy() async throws {
        let inbox = try makeInbox()
        defer { removeInbox(inbox) }
        let copied = try writeGPX(Self.ridgeGPX, in: inbox.directory)
        defer { try? FileManager.default.removeItem(at: copied) }
        let context = try Fixture.modelContext()

        let result = await outcome(importing: copied, into: context) { _ in
            throw CocoaError(.fileWriteUnknown)
        }

        #expect(refusal(result) == .notSaved)
        #expect(!result.discardsSourceCopy)
        // The screen's own rule, applied rather than described: nothing else
        // decides whether the copy goes.
        if result.discardsSourceCopy { await GPXInbox.discardCopy(at: copied) }
        #expect(
            FileManager.default.fileExists(atPath: copied.path),
            "the only copy of a hike that wasn't saved must survive the import"
        )
    }

    /// The other half of the same rule, which has not changed: a file that
    /// could never become a hike still won't on the next launch, so its copy
    /// goes rather than sitting in a directory nothing else reads.
    @Test("a file that can't be read takes its inbox copy with it")
    func unreadableFileDiscardsItsCopy() async throws {
        let inbox = try makeInbox()
        defer { removeInbox(inbox) }
        let copied = try writeGPX("not a GPX file at all", in: inbox.directory)
        defer { try? FileManager.default.removeItem(at: copied) }
        let context = try Fixture.modelContext()

        let result = await outcome(importing: copied, into: context)

        #expect(refusal(result) == .file(.unreadable))
        #expect(result.discardsSourceCopy)
        if result.discardsSourceCopy { await GPXInbox.discardCopy(at: copied) }
        #expect(!FileManager.default.fileExists(atPath: copied.path))
    }

    /// A single point is a pin, not a route, and the import is what refuses it
    /// — the parser hands such a track back happily. Refused before anything
    /// is inserted, so there is nothing to take back out.
    @Test("a one-point file is refused as a file failure")
    func onePointFileIsTooShort() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let file = try writeGPX(Self.singlePointGPX, in: sandbox)
        let context = try Fixture.modelContext()

        let result = await outcome(importing: file, into: context)

        #expect(refusal(result) == .file(.tooShort))
        let remaining = try context.fetch(FetchDescriptor<Hike>())
        #expect(remaining.isEmpty)
    }

    /// The real `Documents/Inbox`, since ``GPXInbox/discardCopy(at:)`` only
    /// acts on a file genuinely inside it — a stand-in directory would make
    /// the assertions above pass for the wrong reason.
    private func makeInbox() throws -> (directory: URL, existed: Bool) {
        let inbox = try #require(GPXInbox.directory)
        let existed = FileManager.default.fileExists(atPath: inbox.path)
        try FileManager.default.createDirectory(
            at: inbox,
            withIntermediateDirectories: true
        )
        return (inbox, existed)
    }

    /// Only tidies away a directory a test brought into being; the host app's
    /// own inbox, if it had one, is not ours to remove.
    private func removeInbox(_ inbox: (directory: URL, existed: Bool)) {
        guard !inbox.existed else { return }
        try? FileManager.default.removeItem(at: inbox.directory)
    }
}
