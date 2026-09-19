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
    let pending: CommunityPendingPhotos
    let transport: any CommunityTransporting
    var queue: CommunityReviewQueue
    /// Written, never read: it is what puts these photographs' places on the
    /// map behind the sheet. See this file's header.
    var browser: CommunityBrowser
    /// Pops the screen. Run after a decision has landed, and after nothing
    /// else — a reviewer who backs out has decided nothing.
    let onFinished: () -> Void

    /// The phase, the removals and the tasks — shared with
    /// ``CommunityReviewView``, which decides the same way about a different
    /// thing. See ``CommunityReviewDecisions``.
    @State private var decisions: CommunityReviewDecisions<CommunityPhotoContribution>

    init(
        pending: CommunityPendingPhotos,
        transport: any CommunityTransporting,
        queue: CommunityReviewQueue,
        browser: CommunityBrowser,
        onFinished: @escaping () -> Void
    ) {
        self.pending = pending
        self.transport = transport
        self.queue = queue
        self.browser = browser
        self.onFinished = onFinished
        _decisions = State(
            initialValue: CommunityReviewDecisions(listing: pending.prospectiveListing)
        )
    }

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
        decisions.canDecide && !pending.authorID.isEmpty && decisions.keptPhotoCount > 0
    }

    var body: some View {
        Form {
            contributionSection
            switch decisions.phase {
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
            await decisions.begin(loading: download, thenShowing: showOnMap)
        }
        .onDisappear {
            browser.previewClosed(pending.prospectiveListing)
            decisions.end()
        }
        .confirmationDialog(
            "Decline these photos?",
            isPresented: $decisions.isConfirmingDecline,
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
                get: { decisions.decisionFailure != nil },
                set: { if !$0 { decisions.decisionFailure = nil } }
            ),
            presenting: decisions.decisionFailure
        ) { _ in
            Button("OK", role: .cancel) { decisions.decisionFailure = nil }
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

    /// The photographs, each one removable on its own. See
    /// ``CommunityReviewPhotoStrip``, which draws the same strip on
    /// ``CommunityReviewView``.
    func photosSection(_ contribution: CommunityPhotoContribution) -> some View {
        CommunityReviewPhotoStrip(
            subject: contribution,
            decisions: decisions,
            // On a hike, leaving every photograph out still publishes the
            // walk. Here the photographs *are* the submission, so an empty
            // set is a decline. See this file's header.
            emptiedMessage: "Nothing left to publish. Decline these instead.",
            emptyMessage: "None arrived.",
            showOnMap: showOnMap
        )
    }

    /// ``CommunityRetryableFailureSection`` is shared with the other
    /// review screen and the two share sheets; the retry is this
    /// screen's, because the load it re-runs is.
    func failureSection(_ failure: CommunityFailure) -> some View {
        CommunityRetryableFailureSection(failure: failure, identifier: "photo-review-failure") {
            decisions.retry(loading: download, thenShowing: showOnMap)
        }
    }
}

// MARK: - Deciding

private extension CommunityPhotoReviewView {
    var decisionSection: some View {
        Section {
            Button {
                publish()
            } label: {
                if decisions.isDeciding {
                    ProgressView()
                } else {
                    Text("Publish")
                }
            }
            .disabled(!canPublish)
            .accessibilityIdentifier("photo-review-publish")

            Button("Decline", role: .destructive) { decisions.isConfirmingDecline = true }
                .disabled(decisions.isDeciding)
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
        } else if !decisions.hasLoaded {
            Text("Publishing waits for the photos to load.")
        } else if decisions.keptPhotoCount == 0 {
            Text("Every photo is left out, so there is nothing to publish.")
        } else {
            Text("Publishing puts these on the trail for everybody, immediately.")
        }
    }

    /// Downloads the contribution into the staging directory this visit owns.
    func download(into staging: URL) async throws -> CommunityPhotoContribution {
        try await transport.photos(ofPending: pending, downloadingInto: staging)
    }

    /// Where the photographs that are still going were taken.
    ///
    /// No opener: this screen's strip decides what stays rather than showing
    /// what is there, so its pins have no gallery to open.
    func showOnMap(_ contribution: CommunityPhotoContribution) {
        browser.previewPhotosLoaded(
            decisions.keptPreviewPhotos(of: contribution),
            of: pending.prospectiveListing,
            onOpen: nil
        )
    }

    func publish() {
        guard canPublish, let contribution = decisions.subject else { return }
        decisions.decide {
            let count = try await decisions.publishedPhotoCount(of: contribution) { kept, staging in
                try await transport.keepOnlyPhotos(kept, ofPending: pending, staging: staging)
            }
            var decided = pending
            decided.photoCount = count
            _ = try await transport.publishPhotos(decided)
        } thenFinishing: {
            finish()
        }
    }

    func decline() {
        decisions.decide {
            try await transport.declinePhotos(pending)
        } thenFinishing: {
            finish()
        }
    }

    /// The decision landed: take the row away and go back.
    func finish() {
        queue.forget(pending)
        onFinished()
    }
}
