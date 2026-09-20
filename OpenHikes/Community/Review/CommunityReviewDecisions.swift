//
//  CommunityReviewDecisions.swift
//  OpenHikes
//
//  The machinery both review screens run on: what has arrived, what the
//  reviewer has struck off, and the load, publish and decline that move
//  between those states.
//
//  ``CommunityReviewView`` and ``CommunityPhotoReviewView`` are deliberately
//  different screens — one is built around a hike and the other around a set
//  of photographs, and each file's header argues for its own shape. What they
//  are not different about is any of this: the same four pieces of state, the
//  same two retained tasks for the same reason, the same staging directory per
//  visit, the same silence on cancellation, the same "leave everything as it
//  was" on failure. That was written twice, and the second copy's comments
//  say so in a dozen places.
//
//  ## Why the operations are passed per call rather than held
//
//  This type holds no transport, no queue and no browser, and takes no
//  closures at construction. Every method that needs one takes it at the call
//  site instead. The reason is the hike screen's editable title: a closure
//  captured when the screen was built would publish the title as it was then,
//  and a reviewer's correction would silently not be written. Building the
//  closure inside a method on the view — which SwiftUI recreates with current
//  state on every pass — cannot go stale, whatever it reads.
//
//  ## Why an @Observable class rather than @State on each screen
//
//  Because there is one of it per screen and both screens' bodies read all of
//  it. The render-isolation rule this repository enforces is about *high
//  frequency* state, which this is not: it changes when a download lands, when
//  a tile is tapped, and when a decision is made. A body that redraws on those
//  is a body that is doing its job.
//

import Foundation
import SwiftUI

/// What a review screen needs from the thing it is deciding about.
///
/// Conformed to by ``CommunityHikeDetail`` and ``CommunityPhotoContribution``,
/// which are otherwise unalike: one carries a route and a description, the
/// other a credit and a target trail. The photographs are the overlap, and
/// they are the overlap because they are what the strip and the map both draw.
nonisolated protocol CommunityReviewSubject: Sendable {
    /// The downloaded copies, owned by the screen that asked for them.
    var photoFileURLs: [URL] { get }
    /// How many the record actually carries — see ``hasEveryPhoto``.
    var photosOnRecord: Int { get }
    /// Whether every photograph on the record reached this device. Removal is
    /// withheld when it did not: a rewrite is built from the copies here, so
    /// doing it with one missing would delete that one too.
    var hasEveryPhoto: Bool { get }
    /// Which of the downloaded photographs to keep, as the rewrite wants them.
    func keptPhotos(at indexes: Set<Int>) -> [CommunityKeptPhoto]
    /// Where each photograph was taken, for the pins on the map behind the
    /// sheet.
    var reviewPreviewPhotos: [CommunityPreviewPhoto] { get }
}

@MainActor
@Observable
final class CommunityReviewDecisions<Subject: CommunityReviewSubject> {
    enum Phase {
        case loading
        case loaded(Subject)
        case failed(CommunityFailure)
    }

    private(set) var phase: Phase = .loading
    /// How many photographs arrived. Zero until they do, because that is the
    /// only moment it can be known — a queue entry cannot say.
    private(set) var photoCount = 0
    /// Which photographs the reviewer has struck off, by their index in the
    /// downloaded set.
    ///
    /// Indexes rather than files, because the index is what pairs a
    /// photograph with its pin and with its asset, and it is the one thing
    /// that survives the set changing. Nothing has happened to any of them
    /// until Publish: a removal is reversible for exactly as long as the
    /// decision is.
    private(set) var removedPhotos: Set<Int> = []
    private(set) var isDeciding = false
    var isConfirmingDecline = false
    var decisionFailure: CommunityFailure?

    /// Where the downloads for this visit go.
    ///
    /// Per visit, told apart from any other visit to the same submission — the
    /// rule ``CommunityHikeView`` follows, and for its reason: two visits must
    /// not share a directory that either can delete.
    let staging: URL

    private var loadTask: Task<Void, Never>?
    /// The publish or decline in flight, held for the reason ``loadTask`` is,
    /// and for one more: a publish that takes photographs off the submission
    /// uploads the kept ones **from the staging directory**, so a reviewer who
    /// swipes back mid-decision would have the files pulled out from under the
    /// upload.
    private var decisionTask: Task<Void, Never>?

    init(listing: CommunityListing) {
        staging = CommunityStaging.previewDirectory(of: listing, in: UUID())
    }

    /// Whether the thing being decided about has actually arrived.
    var hasLoaded: Bool {
        if case .loaded = phase { return true }
        return false
    }

    /// The subject, once there is one.
    var subject: Subject? {
        if case .loaded(let subject) = phase { return subject }
        return nil
    }

    /// How many photographs would go.
    var keptPhotoCount: Int { photoCount - removedPhotos.count }

    /// Everything but the screen's own extra condition: loaded, not already
    /// deciding. Each screen ands its own on — a title that is not empty, or a
    /// set that is not entirely struck off.
    var canDecide: Bool { hasLoaded && !isDeciding }

    // MARK: - Arriving and leaving

    /// Downloads the subject, then tells the map what is now on screen.
    ///
    /// Awaited by the caller's `.task`, and retained so that leaving can
    /// cancel it and the staging sweep can wait for it.
    func begin(
        loading download: @escaping @Sendable (URL) async throws -> Subject,
        thenShowing show: @escaping (Subject) -> Void
    ) async {
        loadTask = Task { await load(download, then: show) }
        await loadTask?.value
    }

    /// Cancels the load and deletes the downloads behind whatever is still
    /// using them.
    func end() {
        loadTask?.cancel()
        CommunityHikeView.discardDownloads(at: staging, after: [loadTask, decisionTask])
    }

    private func load(
        _ download: @Sendable (URL) async throws -> Subject,
        then show: (Subject) -> Void
    ) async {
        guard case .loading = phase else { return }
        CommunityStaging.sweep()
        do {
            let arrived = try await download(staging)
            try Task.checkCancellation()
            phase = .loaded(arrived)
            photoCount = arrived.photoFileURLs.count
            show(arrived)
        } catch is CancellationError {
            // The screen has gone. Nothing to report a failure on, and nobody
            // waiting — the silence ``CommunityHikeView/load()`` keeps.
            return
        } catch {
            phase = .failed(Self.failure(error))
        }
    }

    /// Back to `.loading`, for a *Try Again* on a failed load.
    func retry(
        loading download: @escaping @Sendable (URL) async throws -> Subject,
        thenShowing show: @escaping (Subject) -> Void
    ) {
        phase = .loading
        loadTask = Task { await load(download, then: show) }
    }

    // MARK: - Deciding

    /// Strikes a photograph off, or puts it back, and tells the map either way
    /// so the pins and the strip never describe different sets.
    func toggleRemoval(of index: Int, thenShowing show: (Subject) -> Void) {
        if removedPhotos.contains(index) {
            removedPhotos.remove(index)
        } else {
            removedPhotos.insert(index)
        }
        guard case .loaded(let subject) = phase else { return }
        show(subject)
    }

    /// The photographs that are still going, of the ones `subject` carries.
    func keptPreviewPhotos(of subject: Subject) -> [CommunityPreviewPhoto] {
        subject.reviewPreviewPhotos.filter { !removedPhotos.contains($0.index) }
    }

    /// Runs a decision, and reports it.
    ///
    /// A throw is a decision that did not land: it says so and leaves
    /// everything as it was, with every removal still struck off, because
    /// trying again is the whole of the recovery and is safe to — the kept set
    /// is the same set and the files behind it are the same files.
    func decide(
        _ work: @escaping @MainActor () async throws -> Void,
        thenFinishing finish: @escaping () -> Void
    ) {
        isDeciding = true
        decisionTask = Task { @MainActor in
            do {
                try await work()
            } catch {
                isDeciding = false
                decisionFailure = Self.failure(error)
                return
            }
            isDeciding = false
            finish()
        }
    }

    /// What the record will serve after this publish, having first rewritten
    /// its photographs if the reviewer took any out.
    ///
    /// Both halves of what happens to the photographs, decided together:
    /// which of them the record keeps, and what the published record may then
    /// claim. An incomplete download answers *keep the record as it is* — the
    /// rewrite is built from the copies on this device and would delete the
    /// missing one too — and the count follows that rather than the strip on
    /// screen. See ``CommunityPublishedPhotos``.
    ///
    /// The rewrite happens before the published record exists, never after:
    /// until one does, nothing can reach this submission but the reviewer
    /// holding its record name.
    func publishedPhotoCount(
        of subject: Subject,
        rewritingWith keepOnly: ([CommunityKeptPhoto], URL) async throws -> Void
    ) async throws -> Int {
        let photos = CommunityPublishedPhotos(
            photosOnRecord: subject.photosOnRecord,
            downloaded: subject.photoFileURLs.count,
            removing: removedPhotos
        )
        if case .keepOnly(let keeping) = photos.rewrite {
            try await keepOnly(subject.keptPhotos(at: keeping), staging)
        }
        return photos.count
    }

    private static func failure(_ error: any Error) -> CommunityFailure {
        error as? CommunityFailure ?? .unavailable(error.localizedDescription)
    }
}
