//
//  CommunityReviewView.swift
//  OpenHikes
//
//  Where one submission is looked at and published or declined.
//
//  ## Why this is not the preview screen with two extra buttons
//
//  ``CommunityHikeView`` draws a hike the way somebody deciding whether to
//  *walk* it wants to see one: an elevation profile, a surface breakdown, a
//  difficulty grade, a stat grid, and an OpenStreetMap analysis fetched per
//  open to produce them. None of that is what a reviewer is deciding. The
//  question here is whether a stranger's title, words and photographs can go
//  in front of everybody, and every derived section is a row between the
//  reviewer and the three things they actually have to read.
//
//  So this screen shows those three, large, and stops. It is deliberately
//  shorter than the screen the hike will eventually get, and the difference is
//  not a gap to be closed later. Adding *Save* or *Report* here would be worse
//  than redundant: a reviewer cannot report a hike to themselves, and saving
//  one nobody can see yet would write a ``Hike/importedFromListingID`` naming
//  a record that does not exist.
//
//  ## The route is drawn on the map behind, as it is for a published hike
//
//  Same mechanism, same reason — see ``CommunityHikeView``'s header. It is
//  handed over through ``CommunityPendingSubmission/prospectiveListing``,
//  which is what lets a screen with no listing use an API keyed on one.
//
//  ## What a failure does here, and why it is the opposite of the queue's
//
//  Loudly. ``CommunityReviewQueue`` swallows a failed load because every
//  hiker's app runs that query and almost none of them have a queue. By the
//  time somebody is on this screen they are demonstrably in the role, looking
//  at a hike they chose, and waiting on an answer — so a failed publish says
//  so and leaves the row where it is.
//

import Foundation
import SwiftUI

/// One submission, and the decision about it.
struct CommunityReviewView: View {
    /// Tiles big enough to judge a photograph by rather than to recognise one.
    ///
    /// Larger than ``CommunityHikeView``'s, and that difference is the whole
    /// argument of this screen in one number: there, a strip of thumbnails
    /// says *this hike has photographs*; here, the photograph **is** the
    /// thing being decided about.
    private static let photoTileSize: CGFloat = 220
    private static let routePointsWorthDrawing = 2

    let pending: CommunityPendingSubmission
    let transport: any CommunityTransporting
    var queue: CommunityReviewQueue
    /// Written, never read: it is what puts this submission's route on the map
    /// behind the sheet. See this file's header.
    var browser: CommunityBrowser
    /// Pops the screen. Run after a decision has landed, and after nothing
    /// else — a reviewer who backs out has decided nothing.
    let onFinished: () -> Void

    private enum Phase {
        case loading
        case loaded(CommunityHikeDetail)
        case failed(CommunityFailure)
    }

    @State private var phase: Phase = .loading
    /// The count that will be written onto the listing.
    ///
    /// Zero until the photographs arrive, because that is the only moment it
    /// can be known — see ``CommunityPendingSubmission/photoCount``. Held here
    /// rather than read off the detail at the tap so that what is published is
    /// a value this screen watched arrive.
    @State private var photoCount = 0
    @State private var isDeciding = false
    @State private var isConfirmingDecline = false
    @State private var decisionFailure: CommunityFailure?
    @State private var loadTask: Task<Void, Never>?
    /// This visit, told apart from any other visit to the same submission —
    /// the same per-visit rule ``CommunityHikeView`` follows, and for the same
    /// reason: two visits must not share a directory that either can delete.
    @State private var previewSession = UUID()

    private var downloadDirectory: URL {
        CommunityStaging.previewDirectory(of: pending.prospectiveListing, in: previewSession)
    }

    /// Whether publishing this would produce a listing anybody can see.
    ///
    /// ``CommunityListing/init(record:)`` drops a listing whose `authorID` is
    /// blank, so publishing without one writes a record that is live, costs
    /// storage, and is invisible to every client including this one — the
    /// exact silent failure that publishing by hand in the Console made easy.
    /// It cannot happen here, because the field is read off the submission's
    /// creator rather than typed. The guard stays because *cannot happen* and
    /// *is not checked* are different things, and this is the one failure
    /// nothing downstream would ever report.
    private var canPublish: Bool {
        !pending.authorID.isEmpty && !isDeciding
    }

    var body: some View {
        Form {
            submissionSection
            switch phase {
            case .loading:
                Section { ProgressView("Loading submission…") }
            case .failed(let failure):
                failureSection(failure)
            case .loaded(let detail):
                contentSections(detail)
            }
            decisionSection
        }
        .navigationTitle("Review")
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
            CommunityHikeView.discardDownloads(at: downloadDirectory, after: [loadTask])
        }
        .confirmationDialog(
            "Decline this submission?",
            isPresented: $isConfirmingDecline,
            titleVisibility: .visible
        ) {
            Button("Decline and Delete", role: .destructive) { decline() }
            Button("Cancel", role: .cancel) { /* the dialog closing is the whole action */ }
        } message: {
            Text(
                """
                The route and photographs are deleted for good. \
                The hiker is not told, and their app goes on reading \
                “waiting for review”.
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

    // MARK: - What is being decided

    /// The title and credit, which are what a listing is found and read by.
    private var submissionSection: some View {
        Section {
            LabeledContent("Title") { Text(pending.title) }
            LabeledContent("Credit") {
                // An empty credit is ordinary rather than wrong — the field is
                // optional on the share form — so it says so rather than
                // leaving a blank the reviewer has to interpret.
                Text(pending.authorName.isEmpty ? "None given" : pending.authorName)
                    .foregroundStyle(pending.authorName.isEmpty ? .secondary : .primary)
            }
            LabeledContent("Walked") {
                Text(pending.hikeDate.formatted(date: .abbreviated, time: .omitted))
            }
            LabeledContent("Distance") {
                // The same measurement, width and usage ``CommunityHikeRow``
                // formats with, so the figure a reviewer approves reads
                // identically to the one the row will show.
                Text(
                    Measurement(value: pending.distanceMeters, unit: UnitLength.meters)
                        .formatted(.measurement(width: .abbreviated, usage: .road))
                )
            }
        } header: {
            Text("Submission")
        } footer: {
            Text("Sent \(pending.noticedAt.formatted(date: .abbreviated, time: .shortened))")
        }
    }

    @ViewBuilder
    private func contentSections(_ detail: CommunityHikeDetail) -> some View {
        Section("Description") {
            if let description = detail.trackDescription, !description.isEmpty {
                Text(description)
            } else {
                Text("Nothing written.")
                    .foregroundStyle(.secondary)
            }
        }

        if detail.photoFileURLs.isEmpty {
            Section("Photos") {
                Text("None.")
                    .foregroundStyle(.secondary)
            }
        } else {
            Section("Photos (\(detail.photoFileURLs.count))") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(detail.photoFileURLs, id: \.self) { url in
                            CommunityPhotoTile(url: url, size: Self.photoTileSize)
                        }
                    }
                }
                .accessibilityIdentifier("review-photos")
            }
        }

        Section {
            // Nothing is drawn here. The line is on the map under this sheet,
            // which is where a route is looked at in this app — see the header
            // — and a second, smaller map would be a worse view of the same
            // thing plus a second tile budget.
            Text(
                detail.route.count >= Self.routePointsWorthDrawing
                    ? "Drawn on the map behind this sheet."
                    : "Too short to draw."
            )
                .foregroundStyle(.secondary)
        } header: {
            Text("Route")
        }
    }

    private func failureSection(_ failure: CommunityFailure) -> some View {
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
        .accessibilityIdentifier("review-failure")
    }

    // MARK: - Deciding

    private var decisionSection: some View {
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
            .accessibilityIdentifier("review-publish")

            Button("Decline", role: .destructive) { isConfirmingDecline = true }
                .disabled(isDeciding)
                .accessibilityIdentifier("review-decline")
        } footer: {
            if pending.authorID.isEmpty {
                // Reachable only from a submission CloudKit did not stamp with
                // a creator, which should be impossible — the type grants
                // create to `_icloud` and nothing else. Saying so beats a
                // disabled button with no explanation.
                Text(
                    """
                    This submission has no creator recorded, so a published \
                    listing would be invisible and nobody could block its \
                    author. It cannot be published.
                    """
                )
            } else {
                Text("Publishing makes this visible to everybody, immediately.")
            }
        }
    }

    private func publish() {
        guard canPublish else { return }
        isDeciding = true
        Task {
            var decided = pending
            // The count the photographs actually arrived with, rather than a
            // number off the record: a listing claiming photographs it has not
            // got is a row that promises a gallery and opens an empty one.
            decided.photoCount = photoCount
            do {
                _ = try await transport.publish(decided)
            } catch {
                isDeciding = false
                decisionFailure = error as? CommunityFailure
                    ?? .unavailable(error.localizedDescription)
                return
            }
            finish()
        }
    }

    private func decline() {
        isDeciding = true
        Task {
            do {
                try await transport.decline(pending)
            } catch {
                isDeciding = false
                decisionFailure = error as? CommunityFailure
                    ?? .unavailable(error.localizedDescription)
                return
            }
            finish()
        }
    }

    /// The decision landed: take the row away and go back.
    ///
    /// The queue is told rather than re-asked, for the reason
    /// ``CommunityReviewQueue/forget(_:)`` gives.
    private func finish() {
        isDeciding = false
        queue.forget(pending)
        onFinished()
    }

    private func load() async {
        guard case .loading = phase else { return }
        CommunityStaging.sweep()
        do {
            let detail = try await transport.detail(
                ofPending: pending,
                downloadingInto: downloadDirectory
            )
            try Task.checkCancellation()
            phase = .loaded(detail)
            photoCount = detail.photoFileURLs.count
            browser.previewLoaded(detail.route, of: pending.prospectiveListing)
        } catch is CancellationError {
            // The screen has gone. Nothing to report a failure on, and nobody
            // waiting — the same silence ``CommunityHikeView/load()`` keeps.
            return
        } catch {
            phase = .failed(
                error as? CommunityFailure ?? .unavailable(error.localizedDescription)
            )
        }
    }
}
