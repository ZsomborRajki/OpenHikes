//
//  CommunityPhotoReviewView.swift
//  OpenHikes
//
//  Where one set of contributed photographs is looked at and published or
//  declined.
//
//  ## Why this is not ``CommunityReviewView`` with the route rows hidden
//
//  That screen is built around a hike: a title the reviewer may correct, a
//  distance, a description that is most of what there is to judge, and a route
//  drawn on the map behind. A contribution has **none of those**. It has
//  pictures, a credit, and the trail they claim to be of. A screen that kept
//  the other's shape would be four rows saying *not applicable* between the
//  reviewer and the only thing they are deciding about.
//
//  So this is shorter on purpose, and the one thing it adds is the one thing
//  the other cannot have: **where the photographs claim to be**. A hike
//  submission is judged against its own route; a contribution is judged
//  against a trail it names, and the honest question is whether these pictures
//  were taken on it. The map behind the sheet is what answers that — the pins
//  go up through ``CommunityBrowser/previewPhotosLoaded(_:of:)``, exactly as
//  they do for a hike under review, and a contribution whose pictures stand
//  three valleys away is visible rather than described.
//
//  No route goes with them, and that absence is deliberate rather than
//  missing: this app does not fetch the target trail here. Drawing it would
//  mean a second query per queue entry, of a listing the reviewer can open
//  from the community list in one tap, to answer a question the pins already
//  answer to within a few hundred metres.
//
//  ## The one thing a reviewer may change
//
//  Which photographs go. There is no title to correct — a contribution has no
//  title — so the strike-off is the whole of the correction available, and it
//  is the same gesture, the same fade and the same undo the hike's review
//  screen gives. What it cannot do is publish nothing: on a hike, leaving
//  every photograph out still publishes the walk, and here the photographs
//  *are* the submission. An empty set is a decline, and the screen says so
//  rather than offering a publish that would create a record of nothing.
//

import Foundation
import SwiftUI

/// One contributed set, and the decision about it.
struct CommunityPhotoReviewView: View {
    /// Tiles big enough to judge a photograph by rather than to recognise one
    /// — ``CommunityReviewView``'s size, because it is the same judgement.
    private static let photoTileSize: CGFloat = 220
    /// How faint a photograph goes once it has been struck off. Still legible
    /// on purpose: the tile is the only handle for putting it back.
    private static let removedTileOpacity: Double = 0.3

    let pending: CommunityPendingPhotos
    let transport: any CommunityTransporting
    var queue: CommunityReviewQueue
    /// Written, never read: it is what puts these photographs' places on the
    /// map behind the sheet. See this file's header.
    var browser: CommunityBrowser
    /// Pops the screen. Run after a decision has landed, and after nothing
    /// else — a reviewer who backs out has decided nothing.
    let onFinished: () -> Void

    private enum Phase {
        case loading
        case loaded(CommunityPhotoContribution)
        case failed(CommunityFailure)
    }

    @State private var phase: Phase = .loading
    /// How many photographs arrived. Zero until they do, because that is the
    /// only moment it can be known — see
    /// ``CommunityPendingPhotos/photoCount``.
    @State private var photoCount = 0
    /// Which photographs the reviewer has struck off, by their index in the
    /// downloaded set.
    @State private var removedPhotos: Set<Int> = []
    @State private var isDeciding = false
    @State private var isConfirmingDecline = false
    @State private var decisionFailure: CommunityFailure?
    @State private var loadTask: Task<Void, Never>?
    /// The publish or decline in flight, held for the reason ``loadTask`` is,
    /// and for one more: a publish that takes photographs off the submission
    /// uploads the kept ones **from the download directory**, so a reviewer
    /// who swipes back mid-decision would have the files pulled out from under
    /// the upload.
    @State private var decisionTask: Task<Void, Never>?
    /// This visit, told apart from any other visit to the same submission —
    /// the per-visit rule ``CommunityHikeView`` follows, and for the same
    /// reason: two visits must not share a directory that either can delete.
    @State private var previewSession = UUID()

    private var downloadDirectory: URL {
        CommunityStaging.previewDirectory(of: pending.prospectiveListing, in: previewSession)
    }

    private var hasLoaded: Bool {
        if case .loaded = phase { return true }
        return false
    }

    /// How many photographs would go.
    private var keptPhotoCount: Int { photoCount - removedPhotos.count }

    /// Whether publishing this would produce a record anybody can use.
    ///
    /// Three conditions and each is its own kind of impossible. Nothing has
    /// arrived yet, so there is nothing to judge. The submission has no
    /// creator, so nobody could block the contributor — the guard
    /// ``CommunityReviewView`` keeps for the same reason and which should be
    /// unreachable for the same reason. Or every photograph has been struck
    /// off, which is a decline rather than a publication; see this file's
    /// header.
    private var canPublish: Bool {
        hasLoaded && !pending.authorID.isEmpty && !isDeciding && keptPhotoCount > 0
    }

    var body: some View {
        Form {
            contributionSection
            switch phase {
            case .loading:
                Section { ProgressView("Loading photos…") }
            case .failed(let failure):
                failureSection(failure)
            case .loaded(let contribution):
                photosSection(contribution)
            }
            decisionSection
        }
        .navigationTitle("Review Photos")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            browser.previewOpened(pending.prospectiveListing)
            loadTask = Task { await load() }
            await loadTask?.value
        }
        .onDisappear {
            browser.previewClosed(pending.prospectiveListing)
            loadTask?.cancel()
            CommunityHikeView.discardDownloads(
                at: downloadDirectory,
                after: [loadTask, decisionTask]
            )
        }
        .confirmationDialog(
            "Decline these photos?",
            isPresented: $isConfirmingDecline,
            titleVisibility: .visible
        ) {
            Button("Decline and Delete", role: .destructive) { decline() }
            Button("Cancel", role: .cancel) { /* the dialog closing is the whole action */ }
        } message: {
            Text(
                """
                The photos are deleted for good. The hiker is not told, and their \
                app goes on reading “waiting for review”. The trail itself is not \
                touched.
                """
            )
        }
        .alert(
            "Couldn't finish",
            isPresented: Binding(
                get: { decisionFailure != nil },
                set: { if !$0 { decisionFailure = nil } }
            ),
            presenting: decisionFailure
        ) { _ in
            Button("OK", role: .cancel) { decisionFailure = nil }
        } message: { failure in
            Text(failure.recoverySuggestion ?? failure.localizedDescription)
        }
    }
}

// MARK: - What is being decided

private extension CommunityPhotoReviewView {
    /// Who sent these, when the walk was, and which trail they claim to be of.
    ///
    /// The trail is the identity rather than a name, and that is deliberate:
    /// a contribution carries no title — see ``CommunitySchema/PhotoSubmission``
    /// — and a name copied off the target at upload time would be a claim the
    /// contributor wrote rather than a fact. The identity is what publishing
    /// actually writes, so the identity is what a reviewer is shown.
    var contributionSection: some View {
        Section {
            LabeledContent("Credit") {
                Text(pending.authorName.isEmpty ? "None given" : pending.authorName)
                    .foregroundStyle(pending.authorName.isEmpty ? .secondary : .primary)
            }
            LabeledContent("Walked") {
                Text(pending.takenOn.formatted(date: .abbreviated, time: .omitted))
            }
            LabeledContent("Trail") {
                Text(pending.listingID)
                    .font(.caption.monospaced())
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            .accessibilityIdentifier("photo-review-target")
        } header: {
            Text(pending.isCurated ? "Photos for an OpenStreetMap trail" : "Photos for a hike")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sent \(pending.noticedAt.formatted(date: .abbreviated, time: .shortened))")
                // The one sentence this screen exists to put in front of
                // somebody: the pins on the map behind are the whole of the
                // evidence that these pictures are of this trail.
                Text("Their places are on the map behind this sheet.")
            }
        }
    }

    /// The photographs, each one removable on its own.
    func photosSection(_ contribution: CommunityPhotoContribution) -> some View {
        Section {
            if contribution.photoFileURLs.isEmpty {
                Text("None arrived.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("photo-review-empty")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    // Lazy for the reason ``HikePhotoSection/gallery(_:)`` is: an eager
                    // stack starts a decode for every tile at once, for a row that shows
                    // a handful.
                    LazyHStack(spacing: 12) {
                        ForEach(
                            Array(contribution.photoFileURLs.enumerated()),
                            id: \.offset
                        ) { index, url in
                            photoTile(at: index, url: url, removable: contribution.hasEveryPhoto)
                        }
                    }
                }
                .accessibilityIdentifier("photo-review-photos")
            }
        } header: {
            // Two numbers only once they differ, so the ordinary case reads
            // exactly as it did on the hike's review screen.
            Text(
                removedPhotos.isEmpty
                    ? "Photos (\(contribution.photoFileURLs.count))"
                    : "Photos (\(keptPhotoCount) of \(contribution.photoFileURLs.count))"
            )
        } footer: {
            photosFooter(contribution)
        }
    }

    func photoTile(at index: Int, url: URL, removable: Bool) -> some View {
        let isRemoved = removedPhotos.contains(index)
        return CommunityPhotoTile(url: url, size: Self.photoTileSize)
            .opacity(isRemoved ? Self.removedTileOpacity : 1)
            .overlay(alignment: .topTrailing) {
                if removable {
                    Button {
                        toggleRemoval(of: index)
                    } label: {
                        Image(
                            systemName: isRemoved
                                ? "arrow.uturn.backward.circle.fill"
                                : "xmark.circle.fill"
                        )
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isRemoved ? Color.accentColor : Color.red)
                    }
                    // `.borderless` rather than `.plain`: a `Form` row holding
                    // a single plain button hands the whole row's taps to it,
                    // and this row is a scrollable strip of several.
                    .buttonStyle(.borderless)
                    .padding(8)
                    .disabled(isDeciding)
                    .accessibilityLabel(
                        isRemoved
                            ? Text("Keep photo \(index + 1)")
                            : Text("Leave photo \(index + 1) out")
                    )
                    .accessibilityIdentifier(
                        isRemoved ? "photo-review-restore" : "photo-review-remove"
                    )
                }
            }
    }

    @ViewBuilder
    func photosFooter(_ contribution: CommunityPhotoContribution) -> some View {
        if !contribution.hasEveryPhoto, !contribution.photoFileURLs.isEmpty {
            // The one state where removal is withheld, and it is withheld
            // rather than risked: publishing rebuilds the record's photographs
            // out of the copies on this device, so doing it with one missing
            // would delete that one as well. ``CommunityReviewView`` makes the
            // same refusal in the same words for the same reason.
            Text(
                CommunityPublishedPhotos.incompleteDownload(
                    missing: contribution.photosOnRecord - contribution.photoFileURLs.count
                )
            )
            .accessibilityIdentifier("photo-review-incomplete")
        } else if removedPhotos.isEmpty {
            Text("Leave out any photo that shouldn't be published. The rest still go.")
        } else if keptPhotoCount == 0 {
            // Not a warning about a removal but a description of what the
            // screen has become: a submission with every photograph struck off
            // has nothing left to publish. See this file's header.
            Text("Nothing left to publish. Decline these instead.")
                .accessibilityIdentifier("photo-review-emptied")
        } else {
            Text(CommunityPublishedPhotos.removalWarning(count: removedPhotos.count))
                .accessibilityIdentifier("photo-review-removed")
        }
    }

    func failureSection(_ failure: CommunityFailure) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(failure.localizedDescription)
                if let suggestion = failure.recoverySuggestion {
                    Text(suggestion)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("Try Again") {
                    phase = .loading
                    loadTask = Task { await load() }
                }
            }
        }
        .accessibilityIdentifier("photo-review-failure")
    }
}

// MARK: - Deciding

private extension CommunityPhotoReviewView {
    var decisionSection: some View {
        Section {
            Button {
                publish()
            } label: {
                if isDeciding {
                    ProgressView()
                } else {
                    Text("Publish")
                }
            }
            .disabled(!canPublish)
            .accessibilityIdentifier("photo-review-publish")

            Button("Decline", role: .destructive) { isConfirmingDecline = true }
                .disabled(isDeciding)
                .accessibilityIdentifier("photo-review-decline")
        } footer: {
            decisionFooter
        }
    }

    @ViewBuilder var decisionFooter: some View {
        if pending.authorID.isEmpty {
            Text(
                """
                This submission has no creator recorded, so nobody could block \
                whoever sent it. It cannot be published.
                """
            )
        } else if !hasLoaded {
            Text("Publishing waits for the photos to load.")
        } else if keptPhotoCount == 0 {
            Text("Every photo is left out, so there is nothing to publish.")
        } else {
            Text("Publishing puts these on the trail for everybody, immediately.")
        }
    }

    /// Strikes a photograph off, or puts it back.
    ///
    /// The map is told either way, so the pins and the strip never describe
    /// different sets.
    func toggleRemoval(of index: Int) {
        if removedPhotos.contains(index) {
            removedPhotos.remove(index)
        } else {
            removedPhotos.insert(index)
        }
        guard case .loaded(let contribution) = phase else { return }
        // No opener: this screen's strip decides what stays rather than
        // showing what is there, so its pins have no gallery to open.
        browser.previewPhotosLoaded(
            keptPreviewPhotos(of: contribution),
            of: pending.prospectiveListing,
            onOpen: nil
        )
    }

    /// Where the photographs that are still going were taken.
    ///
    /// Numbered from zero, because on this screen there is nothing before them
    /// — a contribution under review is not sitting after a hike's own
    /// pictures the way it will be once it is published.
    func keptPreviewPhotos(of contribution: CommunityPhotoContribution) -> [CommunityPreviewPhoto] {
        contribution.previewPhotos(startingAt: 0)
            .filter { !removedPhotos.contains($0.index) }
    }

    func publish() {
        guard canPublish, case .loaded(let contribution) = phase else { return }
        isDeciding = true
        decisionTask = Task {
            // Both halves of what happens to the photographs, decided
            // together: which of them the record keeps, and what the published
            // record may then claim. An incomplete download answers *keep the
            // record as it is*. See ``CommunityPublishedPhotos``.
            let photos = CommunityPublishedPhotos(
                photosOnRecord: contribution.photosOnRecord,
                downloaded: contribution.photoFileURLs.count,
                removing: removedPhotos
            )
            if case .keepOnly(let keeping) = photos.rewrite {
                do {
                    // Before the published record exists, never after: until
                    // one does, nothing can reach this submission but the
                    // reviewer holding its record name.
                    try await transport.keepOnlyPhotos(
                        contribution.keptPhotos(at: keeping),
                        ofPending: pending,
                        staging: downloadDirectory
                    )
                } catch {
                    // Nothing has been published, so this is a failed edit
                    // rather than a failed publication. Trying again is the
                    // whole of the recovery and is safe to: the kept set is
                    // the same set and the files behind it are the same files.
                    fail(error)
                    return
                }
            }

            var decided = pending
            decided.photoCount = photos.count
            do {
                _ = try await transport.publishPhotos(decided)
            } catch {
                fail(error)
                return
            }
            finish()
        }
    }

    func decline() {
        isDeciding = true
        decisionTask = Task {
            do {
                try await transport.declinePhotos(pending)
            } catch {
                fail(error)
                return
            }
            finish()
        }
    }

    /// A decision that did not land: say so, and leave everything as it was.
    func fail(_ error: any Error) {
        isDeciding = false
        decisionFailure = error as? CommunityFailure
            ?? .unavailable(error.localizedDescription)
    }

    /// The decision landed: take the row away and go back.
    func finish() {
        isDeciding = false
        queue.forget(pending)
        onFinished()
    }

    func load() async {
        guard case .loading = phase else { return }
        CommunityStaging.sweep()
        do {
            let contribution = try await transport.photos(
                ofPending: pending,
                downloadingInto: downloadDirectory
            )
            try Task.checkCancellation()
            phase = .loaded(contribution)
            photoCount = contribution.photoFileURLs.count
            // No opener, for the reason `toggleRemoval(of:)` gives.
            browser.previewPhotosLoaded(
                keptPreviewPhotos(of: contribution),
                of: pending.prospectiveListing,
                onOpen: nil
            )
        } catch is CancellationError {
            // The screen has gone. Nothing to report a failure on, and nobody
            // waiting — the silence ``CommunityHikeView/load()`` keeps.
            return
        } catch {
            phase = .failed(
                error as? CommunityFailure ?? .unavailable(error.localizedDescription)
            )
        }
    }
}
