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

import CoreLocation
import Foundation
import OpenHikesData
import OpenHikesShared
import SwiftUI

/// What a review screen needs from the thing it is deciding about.
///
/// Conformed to by ``CommunityHikeDetail`` and ``CommunityPhotoContribution``,
/// which are otherwise unalike: one carries a route and a description, the
/// other a credit and a target trail. The photographs are the overlap, and
/// they are the overlap because they are what the strip and the map both draw.
nonisolated protocol CommunityReviewSubject: Sendable {
    /// Where each downloaded photograph was taken, in ``photoFileURLs`` order.
    var photoPins: [CommunityPhotoPin] { get }
    /// The downloaded copies, owned by the screen that asked for them.
    var photoFileURLs: [URL] { get }
    /// How many the record actually carries — see ``hasEveryPhoto``.
    var photosOnRecord: Int { get }
    /// Who these photographs belong to, or `nil` when they are the hike
    /// author's own and the listing already says so. See
    /// ``CommunityGalleryPhoto/contribution``.
    var galleryAttribution: CommunityPhotoAttribution? { get }
    /// Where each photograph was taken, for the pins on the map behind the
    /// sheet.
    ///
    /// Still each subject's own, because the two disagree about what a review
    /// screen is looking at: a contribution numbers its pictures from zero,
    /// and a hike detail shows the ones the submission carries.
    var reviewPreviewPhotos: [CommunityPreviewPhoto] { get }
}

/// The pairing itself, which both subjects had written out.
///
/// **A pin is a claim about *which* photograph was taken *where*, and pairing
/// by index is the entirety of what backs that claim.** Everything below turns
/// on that one sentence, which is why it is now said once: the two arrays are
/// checked against each other before any of it, and a subject that cannot
/// support the claim draws no pins rather than pins that might each be about
/// the picture next door.
///
/// `nonisolated` on the extension rather than on the members, which is the
/// spelling the repository instructions require under
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — both conformers are
/// `nonisolated` structs, and an unannotated extension here compiles locally
/// and fails on CI.
nonisolated extension CommunityReviewSubject {
    /// Whether the pins still describe the pictures.
    ///
    /// Asked separately per subject because each is a record of its own: one
    /// set whose pins are wrong must not cost the others their places.
    ///
    /// ``CloudKitCommunityTransport`` builds both arrays from the same
    /// downloaded files, so nothing it hands back can fail this. That is a
    /// reason to keep the check rather than to drop it: the guarantee lives in
    /// one conformance, the consequence of losing it is undetectable and
    /// permanent, and the check costs a comparison on a path that already
    /// walks every photograph.
    var isConsistent: Bool {
        photoPins.count == photoFileURLs.count
    }

    /// Whether every photograph on the record reached this device.
    ///
    /// What a rewrite may only be called behind: it is built out of the copies
    /// on this device, so doing it while one is missing would delete that one
    /// too, permanently, without the reviewer having decided anything about
    /// it.
    var hasEveryPhoto: Bool {
        isConsistent && photoFileURLs.count == photosOnRecord
    }

    /// The photographs at `indexes`, each with the pin that describes it, in
    /// the order they arrived in.
    ///
    /// The order is load-bearing rather than tidy: what comes back is written
    /// straight onto the submission as its two photo fields, and those pair by
    /// position. Sorting by index is what keeps the first picture first after
    /// the third has been taken out.
    ///
    /// Empty when the two arrays disagree — a sharper refusal than
    /// ``previewPhotos(startingAt:)``'s, since this answer is uploaded.
    func keptPhotos(at indexes: Set<Int>) -> [CommunityKeptPhoto] {
        guard isConsistent else { return [] }
        return indexes.sorted().compactMap { index in
            guard photoFileURLs.indices.contains(index) else { return nil }
            return CommunityKeptPhoto(pin: photoPins[index], fileURL: photoFileURLs[index])
        }
    }

    /// The photographs that know where they were taken, ready for the map.
    ///
    /// Unanchored ones are left out rather than pinned somewhere plausible,
    /// which is the rule ``PhotoMapPin`` already follows for the hiker's own
    /// pictures: a photograph with no coordinate is still part of the hike and
    /// still in the strip, it just has nowhere to stand.
    ///
    /// - Parameter offset: Where this set starts in the merged gallery, so a
    ///   pin and a gallery page agree about which picture they are both about.
    ///   See ``CommunityHikeDetail/galleryPhotos``.
    func previewPhotos(startingAt offset: Int) -> [CommunityPreviewPhoto] {
        guard isConsistent else { return [] }
        return zip(photoPins, photoFileURLs).enumerated().compactMap { index, pair in
            guard let coordinate = pair.0.coordinate else { return nil }
            return CommunityPreviewPhoto(
                index: offset + index,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                capturedAt: pair.0.capturedAt,
                fileURL: pair.1
            )
        }
    }

    /// Every downloaded photograph of this set, in the order the strip draws
    /// them.
    ///
    /// Drops nothing, unlike ``previewPhotos(startingAt:)``, because the
    /// gallery is the strip made large: a picture missing from here would make
    /// the fourth tile open the fifth photograph. What an inconsistent set
    /// loses is the *places* rather than the pictures.
    func galleryPhotos(startingAt offset: Int) -> [CommunityGalleryPhoto] {
        let pinned = isConsistent
        return photoFileURLs.enumerated().map { index, url in
            CommunityGalleryPhoto(
                index: offset + index,
                pin: pinned ? photoPins[index] : nil,
                fileURL: url,
                contribution: galleryAttribution
            )
        }
    }
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
                // Both decisions and both outcomes pass through here, which is
                // why the haptic is here rather than on the two buttons: a
                // reviewer taps Publish and waits on a network round trip, and
                // what is worth feeling is which way it went.
                HapticMoment.outcomeFailed.play()
                return
            }
            isDeciding = false
            HapticMoment.outcomeSucceeded.play()
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
