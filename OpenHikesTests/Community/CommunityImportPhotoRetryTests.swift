//
//  CommunityImportPhotoRetryTests.swift
//  OpenHikesTests
//
//  What a community import says about the photographs it could not copy, and
//  what trying them again does.
//
//  ## The bug these were written against
//
//  Saving a community hike whose photograph would not save came back as an
//  ordinary `.imported`, holding none of its photographs. Saving it again
//  answered `.alreadyImported` without trying the missing ones, so a
//  transient failure on one tap was a permanent hole in the saved hike, and
//  the only way out was to delete the route and save it again.
//
//  ## What has to stay true
//
//  **The route survives a failed photograph.** That bargain is deliberate —
//  see ``CommunityImport`` — and these only make it visible.
//
//  **A retry copies only what is missing,** so nothing lands twice, and each
//  photograph comes back with the credit and the place it would have had the
//  first time.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@MainActor
@Suite("Community import photo retry")
struct CommunityImportPhotoRetryTests {
    private static let takenOn = Date(timeIntervalSince1970: 1_700_000_000)

    private static let hut = TrailPlace(
        latitude: 47.61,
        longitude: 12.98,
        name: "Kärlingerhaus",
        symbol: .shelter,
        note: ""
    )

    /// A directory of real JPEGs, removed when the test leaves. Real bytes
    /// because the store refuses anything it cannot decode, which is one of
    /// the failures under test.
    private final class Staging {
        let directory: URL

        init() {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "CommunityImportPhotoRetryTests-\(UUID().uuidString)",
                    isDirectory: true
                )
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        func files(_ names: [String]) -> [URL] {
            names.map { name in
                let url = directory.appendingPathComponent("\(name).jpeg", isDirectory: false)
                try? PhotoDiscoveryFixture.sampleImageData().write(to: url)
                return url
            }
        }

        func notAnImage(_ name: String) -> URL {
            let url = directory.appendingPathComponent("\(name).jpeg", isDirectory: false)
            try? Data("not a picture".utf8).write(to: url)
            return url
        }

        func missing(_ name: String) -> URL {
            directory.appendingPathComponent("\(name).jpeg", isDirectory: false)
        }
    }

    /// A commit that refuses the saves it is told to, counting from the first
    /// — which is the route's.
    private final class Refusals {
        private var remaining: Set<Int>
        private var calls = 0

        init(_ refused: Set<Int>) { remaining = refused }

        func save(_ context: ModelContext) throws {
            defer { calls += 1 }
            if remaining.remove(calls) != nil {
                throw CocoaError(.fileWriteNoPermission)
            }
            try context.save()
        }
    }

    private static func pin(_ index: Int, placeID: UUID? = nil) -> CommunityPhotoPin {
        CommunityPhotoPin(
            capturedAt: takenOn.addingTimeInterval(Double(index) * 60),
            coordinate: CLLocationCoordinate2D(latitude: 47.6 + Double(index) / 1000, longitude: 12.8),
            placeID: placeID
        )
    }

    private static func detail(
        ownFiles: [URL] = [],
        ownPins: [CommunityPhotoPin] = [],
        places: [TrailPlace] = [],
        contributions: [CommunityPhotoContribution] = []
    ) -> CommunityHikeDetail {
        CommunityHikeDetail(
            listing: .stub(),
            route: Fixture.ridgeRoute,
            places: places,
            trackDescription: nil,
            photoPins: ownPins.isEmpty ? ownFiles.indices.map { pin($0) } : ownPins,
            photoFileURLs: ownFiles,
            photosOnRecord: ownFiles.count,
            contributions: contributions
        )
    }

    private static func contribution(id: String, author: String, files: [URL]) -> CommunityPhotoContribution {
        CommunityPhotoContribution(
            id: id,
            photoSubmissionID: "\(id)-submission",
            authorName: author,
            authorID: "\(id)-author",
            publishedAt: takenOn,
            photoPins: files.indices.map { pin($0) },
            photoFileURLs: files,
            photosOnRecord: files.count
        )
    }

    private func imported(
        _ detail: CommunityHikeDetail,
        in sandbox: PhotoStoreSandbox,
        save: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) async throws -> (Hike, CommunityPhotoCopy) {
        let context = try Fixture.modelContext()
        let outcome = await CommunityImport.importHike(
            detail,
            into: context,
            store: sandbox.store,
            libraryWriter: StubPhotoLibraryWriter(),
            save: save
        )
        guard case let .imported(hike, photos) = outcome else {
            Issue.record("the route should have been kept")
            throw CancellationError()
        }
        return (hike, photos)
    }

    private func retried(
        _ detail: CommunityHikeDetail,
        onto hike: Hike,
        after previous: CommunityPhotoCopy,
        in sandbox: PhotoStoreSandbox
    ) async -> CommunityPhotoCopy {
        await CommunityImport.copyPhotos(
            of: detail,
            onto: hike,
            after: previous,
            store: sandbox.store,
            libraryWriter: StubPhotoLibraryWriter()
        )
    }

    // MARK: Saying so

    @Test("an import whose photographs all copied says it is complete")
    func cleanImportIsComplete() async throws {
        let staging = Staging()
        let sandbox = PhotoStoreSandbox()
        let (hike, photos) = try await imported(
            Self.detail(ownFiles: staging.files(["own-0", "own-1"])),
            in: sandbox
        )

        #expect(photos.isComplete)
        #expect(photos.copied.count == 2)
        #expect(hike.photos.count == 2)
    }

    /// The reported bug: the route commits, the photograph's commit is
    /// refused, and the outcome used to be indistinguishable from a clean one.
    @Test("a refused photograph save keeps the route and reports the photograph missing")
    func refusedPhotoSaveIsReported() async throws {
        let staging = Staging()
        let sandbox = PhotoStoreSandbox()
        let refusals = Refusals([1])
        let (hike, photos) = try await imported(
            Self.detail(ownFiles: staging.files(["own-0"])),
            in: sandbox,
            save: refusals.save
        )

        #expect(hike.isAttached, "the route is kept whatever the photograph did")
        #expect(hike.photos.isEmpty)
        #expect(!photos.isComplete)
        #expect(photos.failed.count == 1)
    }

    @Test("bytes that are not an image, and a file that is not there, are reported missing")
    func unreadableAndUndecodableAreReported() async throws {
        let staging = Staging()
        let sandbox = PhotoStoreSandbox()
        let (hike, photos) = try await imported(
            Self.detail(ownFiles: [
                staging.notAnImage("broken"),
                staging.files(["good"])[0],
                staging.missing("gone"),
            ]),
            in: sandbox
        )

        #expect(hike.photos.count == 1, "the good photograph between them still copies")
        #expect(photos.copied == [.init(contributionID: nil, index: 1)])
        #expect(photos.failed == [.init(contributionID: nil, index: 0), .init(contributionID: nil, index: 2)])
    }

    /// A set whose pins and files disagree is left out on purpose, and would
    /// be every time — so counting it would offer a retry that cannot work.
    @Test("a set whose pins and files disagree is not counted as a failure")
    func inconsistentSetIsNotAFailure() async throws {
        let staging = Staging()
        let sandbox = PhotoStoreSandbox()
        let (hike, photos) = try await imported(
            Self.detail(ownFiles: staging.files(["own-0", "own-1"]), ownPins: [Self.pin(0)]),
            in: sandbox
        )

        #expect(hike.photos.isEmpty)
        #expect(photos.isComplete)
    }

    // MARK: Trying again

    @Test("a retry copies what was missed, and nothing twice")
    func retryCopiesOnlyWhatWasMissed() async throws {
        let staging = Staging()
        let sandbox = PhotoStoreSandbox()
        let detail = Self.detail(ownFiles: staging.files(["own-0", "own-1", "own-2"]))
        // The route, then the first photograph, then the second is refused.
        let refusals = Refusals([2])
        let (hike, first) = try await imported(detail, in: sandbox, save: refusals.save)
        #expect(hike.photos.count == 2)
        #expect(first.failed == [.init(contributionID: nil, index: 1)])

        let second = await retried(detail, onto: hike, after: first, in: sandbox)

        #expect(second.isComplete)
        #expect(second.copied.count == 3)
        #expect(hike.photos.count == 3, "not five: the two already copied are not copied again")
        #expect(Set(hike.photos.map(\.capturedAt)).count == 3)
    }

    @Test("a retry that fails again still says so")
    func retryThatFailsAgainIsReported() async throws {
        let staging = Staging()
        let sandbox = PhotoStoreSandbox()
        let detail = Self.detail(ownFiles: [staging.notAnImage("broken")])
        let (hike, first) = try await imported(detail, in: sandbox)

        let second = await retried(detail, onto: hike, after: first, in: sandbox)

        #expect(second.failed.count == 1)
        #expect(hike.photos.isEmpty)
    }

    /// A photograph the hiker removed from the saved hike after the first
    /// attempt is one they chose not to keep, not one the retry should find.
    @Test("a retry does not bring back a copied photograph the hiker has since removed")
    func retryLeavesRemovedPhotographsRemoved() async throws {
        let staging = Staging()
        let sandbox = PhotoStoreSandbox()
        let detail = Self.detail(ownFiles: staging.files(["own-0", "own-1"]))
        let refusals = Refusals([2])
        let (hike, first) = try await imported(detail, in: sandbox, save: refusals.save)
        let kept = try #require(hike.photos.first)
        HikePhotoImport.remove(kept, from: hike, store: sandbox.store)

        _ = await retried(detail, onto: hike, after: first, in: sandbox)

        #expect(hike.photos.count == 1)
        #expect(!hike.photos.contains { $0.capturedAt == kept.capturedAt })
    }

    @Test("a contributed photograph copied on retry keeps its contributor's credit")
    func retriedContributionKeepsItsCredit() async throws {
        let staging = Staging()
        let sandbox = PhotoStoreSandbox()
        let detail = Self.detail(
            ownFiles: staging.files(["own-0"]),
            contributions: [Self.contribution(id: "c1", author: "Bence", files: staging.files(["c1-0"]))]
        )
        // The route, the author's photograph, then the contribution's refused.
        let refusals = Refusals([2])
        let (hike, first) = try await imported(detail, in: sandbox, save: refusals.save)
        #expect(first.failed == [.init(contributionID: "c1", index: 0)])

        let second = await retried(detail, onto: hike, after: first, in: sandbox)

        #expect(second.isComplete)
        #expect(hike.photos.count == 2)
        #expect(hike.photos.compactMap(\.importedAuthorName) == ["Bence"])
        #expect(hike.photos.allSatisfy { $0.importedFromListingID == detail.listing.id })
    }

    /// The saved hike's places carry ids of their own, so the second attempt
    /// has to file the photograph under the same copy the first would have.
    @Test("an author's photograph copied on retry is filed under the saved copy of its place")
    func retriedPhotoKeepsItsPlace() async throws {
        let staging = Staging()
        let sandbox = PhotoStoreSandbox()
        let detail = Self.detail(
            ownFiles: staging.files(["own-0"]),
            ownPins: [Self.pin(0, placeID: Self.hut.id)],
            places: [Self.hut]
        )
        let refusals = Refusals([1])
        let (hike, first) = try await imported(detail, in: sandbox, save: refusals.save)
        #expect(hike.photos.isEmpty)

        _ = await retried(detail, onto: hike, after: first, in: sandbox)

        let saved = try #require(hike.places.first)
        #expect(saved.id != Self.hut.id)
        #expect(hike.photos(ofPlace: saved.id).count == 1)
    }
}
