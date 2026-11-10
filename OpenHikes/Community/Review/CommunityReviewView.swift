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
//  ## The two things a reviewer may change, and why only those two
//
//  A decision used to be binary: publish this as sent, or delete it. That made
//  the common case of a good walk with one bad thing on it — a title that says
//  "Morning walk", a photograph with a stranger's face in it — into a decline,
//  which is a deletion, of somebody's whole upload, that they are never told
//  about. So the two things a reviewer can act on without throwing the walk
//  away are editable here: the **title**, and **which photographs go**.
//
//  Each is edited where it lives, and the two are not alike.
//
//  The title is the listing's. Nothing reads a submission's title once a hike
//  is published — see ``CloudKitCommunityTransport/contents(of:downloadingInto:)``,
//  which takes the route, the description and the photographs off the record
//  and the name off the listing — so an edited title is written onto
//  ``CommunityPendingSubmission`` before publishing and the submission is
//  never touched. What the hiker wrote survives on their own device and on the
//  record; what everybody else sees is the corrected line.
//
//  A photograph is the submission's, and there is no equivalent trick. The
//  listing carries a count and the pictures are assets on the record it
//  points at, so a photograph "removed" from a listing is still fetchable by
//  anybody who opens the hike. Taking one off means writing the record, which
//  is the one edit in this app that does — see
//  ``CommunityTransporting/keepOnlyPhotos(_:of:staging:)`` for what that costs
//  and why it happens before the listing exists rather than after.
//
//  Both are corrections rather than authorship. A reviewer who wants to
//  rewrite the description or redraw the route is looking at a submission to
//  decline, and neither is offered.
//
//  ## The route is drawn on the map behind, as it is for a published hike
//
//  Same mechanism, same reason — see ``CommunityHikeView``'s header. It is
//  handed over through ``CommunityPendingSubmission/prospectiveListing``,
//  which is what lets a screen with no listing use an API keyed on one.
//
//  The photographs go with it, which is more than the published preview
//  needed and is the point of doing it here: a reviewer deciding whether a
//  picture belongs in a public list is deciding about a picture *of a place*,
//  and the strip below can only say how many there are. See
//  ``MapCommunityPhotoAnnotations``. The pins follow the removals — take a
//  photograph out and its pin goes — so the map and the strip always describe
//  the same set.
//
//  ## What a failure does here, and why it is the opposite of the queue's
//
//  Loudly. ``CommunityReviewQueue`` swallows a failed load because every
//  hiker's app runs that query and almost none of them have a queue. By the
//  time somebody is on this screen they are demonstrably in the role, looking
//  at a hike they chose, and waiting on an answer — so a failed publish says
//  so and leaves the row where it is.
//
//  ## What the form's body reads
//
//  The phase, and what the chrome binds: what changes when the submission
//  arrives and when a decision is made. The title, the keyboard it brings and
//  the order of the places along the route are each read by a section of
//  their own, because a keystroke used to re-run all of this and order the
//  places again with it (#1367) — see `CommunityReviewSections.swift`.
//

import Foundation
import SwiftUI

/// One submission, and the decision about it.
struct CommunityReviewView: View {
    private static let routePointsWorthDrawing = 2

    let pending: CommunityPendingSubmission
    let transport: any CommunityTransporting
    var queue: CommunityReviewQueue
    /// Written, never read: it is what puts this submission's route and the
    /// places its photographs were taken on the map behind the sheet. See this
    /// file's header.
    var browser: CommunityBrowser
    /// The title as it will be published, the phase, the removals, the
    /// tasks and where the places sit along the route, kept by the sheet
    /// rather than here: a turn of the phone builds this screen again in the
    /// other host — see ``CommunityHikeReviewSession``.
    let review: CommunityHikeReviewSession
    /// Pops the screen. Run after a decision has landed, and after nothing
    /// else — a reviewer who backs out has decided nothing.
    let onFinished: () -> Void
    /// Whether the route is still on the stack as this screen goes — see
    /// ``CommunityReviewChrome/remainsPushed``.
    let remainsPushed: () -> Bool

    /// The phase, the removals and the tasks — shared with
    /// ``CommunityPhotoReviewView``, which decides the same way about a
    /// different thing. See ``CommunityReviewDecisions``.
    private var decisions: CommunityReviewDecisions<CommunityHikeDetail> { review.decisions }

    var body: some View {
        Form {
            CommunityReviewSubmissionSection(pending: pending, review: review)
            switch decisions.phase {
            case .loading:
                Section { ProgressView("Loading submission…") }
            case .failed(let failure):
                failureSection(failure)
            case .loaded(let detail):
                contentSections(detail)
            }
            CommunityHikeDecisionSection(pending: pending, review: review, publish: { publish() })
        }
        .modifier(
            CommunityReviewChrome(
                title: "Review",
                listing: pending.prospectiveListing,
                browser: browser,
                declineQuestion: "Decline this submission?",
                declineWarning: """
                The route and photographs are deleted for good. \
                The hiker is not told, and their app goes on reading \
                “waiting for review”.
                """,
                isConfirmingDecline: Bindable(decisions).isConfirmingDecline,
                decisionFailure: Bindable(decisions).decisionFailure,
                begin: { decisions.begin(loading: download, thenShowing: showOnMap) },
                remainsPushed: remainsPushed,
                decline: { decline() }
            )
        )
    }
}

// MARK: - What is being decided

private extension CommunityReviewView {
    @ViewBuilder
    func contentSections(_ detail: CommunityHikeDetail) -> some View {
        Section("Description") {
            if let description = detail.trackDescription, !description.isEmpty {
                Text(description)
            } else {
                Text("Nothing written.")
                    .foregroundStyle(.secondary)
            }
        }

        // The author's words again, and in a section of its own because
        // putting the places in order is a walk of the whole route — see
        // ``CommunityReviewPlaceSection``.
        if !detail.places.isEmpty {
            CommunityReviewPlaceSection(places: detail.places, route: detail.route, review: review)
        }

        if detail.photoFileURLs.isEmpty {
            Section("Photos") {
                Text("None.")
                    .foregroundStyle(.secondary)
            }
        } else {
            photosSection(detail)
        }

        // The route gets a section only when there is something to say that
        // the map cannot say for itself. It is drawn on the map under this
        // sheet, which is where a route is looked at in this app — see the
        // header — so a row announcing that was a row spent telling the
        // reviewer to look at the thing they were already looking at. A route
        // too short to draw is the opposite: nothing appears, and without this
        // the absence reads as a map that failed.
        if detail.route.count < Self.routePointsWorthDrawing {
            Section("Route") {
                Text("Too short to draw.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("review-route-undrawable")
            }
        }
    }

    /// The photographs, each one removable on its own. See
    /// ``CommunityReviewPhotoStrip``, which draws the same strip on
    /// ``CommunityPhotoReviewView``.
    func photosSection(_ detail: CommunityHikeDetail) -> some View {
        CommunityReviewPhotoStrip(
            subject: detail,
            decisions: decisions,
            // No dead end here: leaving every photograph out still publishes
            // the walk, which is what a hike submission is.
            emptiedMessage: nil,
            emptyMessage: nil,
            showOnMap: showPhotosOnMap
        )
    }

    /// ``CommunityRetryableFailureSection`` is shared with the other
    /// review screen and the two share sheets; the retry is this
    /// screen's, because the load it re-runs is.
    func failureSection(_ failure: CommunityFailure) -> some View {
        CommunityRetryableFailureSection(failure: failure, identifier: "review-failure") {
            decisions.retry(loading: download, thenShowing: showOnMap)
        }
    }
}

// MARK: - Deciding

private extension CommunityReviewView {
    /// Downloads the submission into the staging directory this visit owns.
    func download(into staging: URL) async throws -> CommunityHikeDetail {
        try await transport.detail(ofPending: pending, downloadingInto: staging)
    }

    /// The route and the photographs, once the submission has arrived.
    ///
    /// Only on arrival. A removal moves the pins and nothing else — see
    /// ``showPhotosOnMap(_:)`` — because the route it would redraw is the
    /// same route.
    func showOnMap(_ detail: CommunityHikeDetail) {
        browser.previewLoaded(detail.route, of: pending.prospectiveListing)
        showPhotosOnMap(detail)
    }

    /// Where each photograph was taken, which is half of what a reviewer is
    /// judging one by — see this file's header.
    ///
    /// Filtered through the removals for the same reason every later
    /// republish is, even on the first call where there can be none: one
    /// expression for *what the map shows* is one fewer place for the strip
    /// and the pins to drift apart.
    ///
    /// No opener: this screen's strip decides what stays rather than showing
    /// what is there, so its pins have no gallery to open.
    func showPhotosOnMap(_ detail: CommunityHikeDetail) {
        browser.previewPhotosLoaded(
            decisions.keptPreviewPhotos(of: detail),
            of: pending.prospectiveListing,
            onOpen: nil
        )
    }

    func publish() {
        guard review.canPublish(pending), let detail = decisions.subject else { return }
        decisions.decide {
            let count = try await decisions.publishedPhotoCount(of: detail) { kept, staging in
                try await transport.keepOnlyPhotos(kept, of: pending, staging: staging)
            }
            var decided = pending
            // The reviewer's title, which is the listing's alone — see this
            // file's header.
            decided.title = review.publishedTitle
            // What the record will serve, which is the only number a row can
            // promise: a listing claiming photographs it has not got opens a
            // shorter gallery than it advertised, and one claiming fewer than
            // the record holds hides a stranger's photograph that anybody
            // opening the hike can still fetch.
            decided.photoCount = count
            _ = try await transport.publish(decided)
        } thenFinishing: {
            finish()
        }
    }

    func decline() {
        decisions.decide {
            try await transport.decline(pending)
        } thenFinishing: {
            finish()
        }
    }

    /// The decision landed: take the row away and go back.
    ///
    /// The queue is told rather than re-asked, for the reason
    /// ``CommunityReviewQueue/forget(_:)`` gives.
    func finish() {
        queue.forget(pending)
        onFinished()
    }
}
