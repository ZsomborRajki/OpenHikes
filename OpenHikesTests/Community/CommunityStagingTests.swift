//
//  CommunityStagingTests.swift
//  OpenHikesTests
//

import Foundation
@testable import OpenHikes
import Synchronization
import Testing

/// Where an upload's files go, and that none of them are still there
/// afterwards.
///
/// The half of a submission a suite can check: `submit` itself needs an Apple
/// Account and the public database, and there is no sandbox for the second, so
/// what is held here is the contract between the two files that share the
/// directory — `CommunityPublisher` creates and deletes it,
/// `CloudKitCommunityTransport` writes into it. It used to be an inference
/// from the first photograph's path, which meant a hike with no photographs
/// left its whole route as `route.json` in the process-wide temporary
/// directory: outside the directory the publisher deletes, and under a name
/// every other submission was also writing.
@MainActor
@Suite("Community staging")
struct CommunityStagingTests {
    /// What an upload had on disk while it was in flight.
    ///
    /// Recorded from inside the transport because that is the only moment it
    /// exists — by the time `share` returns, the directory is being deleted.
    nonisolated private struct Upload: Sendable {
        var draft: CommunitySubmissionDraft
        var assets: CloudKitCommunityTransport.StagedAssets
    }

    /// Stages `draft` the way the real transport does, so the suite is
    /// asserting about the code that ships rather than about a copy of it.
    nonisolated private static func stage(_ draft: CommunitySubmissionDraft) -> Upload? {
        guard let assets = try? CloudKitCommunityTransport.stage(draft) else { return nil }
        return Upload(draft: draft, assets: assets)
    }

    private func share(
        _ hike: Hike,
        through transport: StubCommunityTransport,
        store: HikePhotoStore
    ) async -> (outcome: CommunityShareOutcome, upload: Upload?) {
        let recorded = Mutex<Upload?>(nil)
        transport.beforeSubmissionReturns = { draft in
            recorded.withLock { $0 = Self.stage(draft) }
        }
        let outcome = await CommunityPublisher.share(
            hike,
            authorName: "Anna",
            entitlement: .entitled,
            transport: transport,
            store: store
        )
        return (outcome, recorded.withLock { $0 })
    }

    /// The deletion is fire-and-forget off a detached task, so this waits for
    /// the directory to go rather than for a length of time.
    private func settleRemoval(of directory: URL) async {
        await settleDelegateHop(until: "the staging directory to be deleted") {
            !FileManager.default.fileExists(atPath: directory.path)
        }
    }

    /// The reported bug. Nothing about a hike with no pictures makes its route
    /// less of a copy of the walk, and the directory that copy landed in
    /// belonged to nobody.
    @Test("a hike with no photographs stages inside the publisher's directory")
    func routeOfAPhotolessHikeStaysInTheOwnedDirectory() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context)

        let (outcome, upload) = await share(
            hike,
            through: StubCommunityTransport(),
            store: sandbox.store
        )

        #expect(outcome == .submitted)
        let staged = try #require(upload)
        #expect(staged.draft.photoFileURLs.isEmpty, "the case that had nothing to infer a directory from")
        #expect(staged.assets.photoPins == nil)
        #expect(
            staged.assets.route.deletingLastPathComponent().standardizedFileURL.path
                == staged.draft.stagingDirectory.standardizedFileURL.path
        )
        #expect(
            staged.draft.stagingDirectory.standardizedFileURL.path
                != FileManager.default.temporaryDirectory.standardizedFileURL.path,
            "the process-wide temporary directory is nobody's to delete"
        )
    }

    /// A hike whose pictures are all unreadable takes the same path as one
    /// with none: an empty list of photo files, and a route that still has to
    /// go somewhere its owner will collect.
    @Test("photographs that all fail to export still stage the route inside")
    func failedPhotoExportsKeepTheRouteInTheOwnedDirectory() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context)
        // Photographs the store has no file for, which is what an export
        // failure is: `exportCopy` reads the original and answers `nil`.
        hike.photos.append(HikePhoto())
        hike.photos.append(HikePhoto())

        let (outcome, upload) = await share(
            hike,
            through: StubCommunityTransport(),
            store: sandbox.store
        )

        #expect(outcome == .submitted)
        let staged = try #require(upload)
        #expect(staged.draft.photoFileURLs.isEmpty)
        #expect(staged.draft.photoPins.isEmpty, "the pins and the images describe each other")
        #expect(
            staged.assets.route.deletingLastPathComponent().standardizedFileURL.path
                == staged.draft.stagingDirectory.standardizedFileURL.path
        )
    }

    @Test("an accepted upload leaves nothing on the device")
    func acceptedUploadIsCleanedUp() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context)

        let (outcome, upload) = await share(
            hike,
            through: StubCommunityTransport(),
            store: sandbox.store
        )
        let staged = try #require(upload)
        await settleRemoval(of: staged.draft.stagingDirectory)

        #expect(outcome == .submitted)
        #expect(!FileManager.default.fileExists(atPath: staged.assets.route.path))
        #expect(!FileManager.default.fileExists(atPath: staged.draft.stagingDirectory.path))
    }

    /// The half that used to survive longest: a refused upload never reaches
    /// the code that would have cleaned up after itself, so the directory has
    /// to be the publisher's on this path too.
    @Test("a refused upload leaves nothing on the device either")
    func refusedUploadIsCleanedUp() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context)
        let transport = StubCommunityTransport()
        transport.submissionResult = .failure(.unreachable)

        let (outcome, upload) = await share(hike, through: transport, store: sandbox.store)
        let staged = try #require(upload)
        await settleRemoval(of: staged.draft.stagingDirectory)

        #expect(outcome == .refused(.unreachable))
        #expect(!FileManager.default.fileExists(atPath: staged.assets.route.path))
        #expect(!FileManager.default.fileExists(atPath: staged.draft.stagingDirectory.path))
    }

    /// Two shares can overlap — the form allows a re-share while the first
    /// upload is still running — and a directory named after the hike alone
    /// would have both attempts writing `route.json` to one path. An atomic
    /// write makes each file whole; it does not stop the second one being the
    /// file the first attempt uploads.
    @Test("two uploads in flight at once stage into different directories")
    func overlappingUploadsStageApart() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let ridge = Fixture.hike(in: context, title: "Pilis Ridge", route: Fixture.ridgeRoute)
        let loop = Fixture.hike(in: context, title: "Dobogókő", route: Fixture.loopRoute)
        let transport = StubCommunityTransport()
        let gate = AsyncGate()
        let uploads = Mutex<[Upload]>([])
        transport.beforeSubmissionReturns = { draft in
            if let upload = Self.stage(draft) {
                uploads.withLock { $0.append(upload) }
            }
            // Held until both have staged, so the two uploads are on disk at
            // the same moment — which is the moment one shared name loses one
            // of the routes.
            await gate.wait()
        }

        // Started as tasks rather than through `share(_:through:store:)`,
        // which owns the hook this test has already taken.
        let first = Task {
            await CommunityPublisher.share(
                ridge,
                authorName: "Anna",
                entitlement: .entitled,
                transport: transport,
                store: sandbox.store
            )
        }
        let second = Task {
            await CommunityPublisher.share(
                loop,
                authorName: "Anna",
                entitlement: .entitled,
                transport: transport,
                store: sandbox.store
            )
        }
        while uploads.withLock({ $0.count }) < 2 { await Task.yield() }

        let staged = uploads.withLock { $0 }
        #expect(
            Set(staged.map(\.draft.stagingDirectory.standardizedFileURL.path)).count == 2,
            "each attempt stages somewhere of its own"
        )
        for upload in staged {
            let document = try JSONDecoder().decode(
                CommunityRouteDocument.self,
                from: Data(contentsOf: upload.assets.route)
            )
            #expect(
                document.route.count == upload.draft.route.count,
                "an attempt uploads its own route rather than whichever was written last"
            )
            #expect(document.route.first?.latitude == upload.draft.route.first?.latitude)
        }

        await gate.open()
        let ridgeOutcome = await first.value
        let loopOutcome = await second.value
        #expect(ridgeOutcome == .submitted)
        #expect(loopOutcome == .submitted)
        for upload in staged {
            await settleRemoval(of: upload.draft.stagingDirectory)
            #expect(!FileManager.default.fileExists(atPath: upload.draft.stagingDirectory.path))
        }
    }
}
