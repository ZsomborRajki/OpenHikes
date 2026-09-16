//
//  CommunityReviewQueue.swift
//  OpenHikes
//
//  What a reviewer has left to look at, and — for everybody else — an empty
//  list they never see.
//
//  ## Why this is not a permission check
//
//  Nothing in this app asks whether the hiker *may* review; it asks the server
//  for the queue and reads the answer. The queue is
//  ``CommunitySchema/noticeType``, which grants read to the `reviewer` role
//  and to nobody else, so asking for it *is* the check: the server comes back
//  with rows or refuses, and the refusal is what ``isReviewer`` records.
//
//  ``isReviewer`` is a cached answer rather than a claim, and forging it buys
//  nothing — every action it gates is refused by the server for an account
//  outside the role, so a modified build that sets it gets the buttons and a
//  permission failure behind each of them. It exists because *a reviewer with
//  an empty queue* and *not a reviewer* are different facts, and the second is
//  the only thing that can decide whether to offer a takedown on a hike that
//  is already published — which has no queue row to hang off.
//
//  That also decides where this type sits. It hangs off the *Community* tab
//  being selected, exactly as ``CommunityBrowser`` does, because the tab is
//  the opt-in and the repository's rule is that nothing reaches the network
//  until it is taken. One request per launch rather than one per selection:
//  almost every launch is a hiker who is not a reviewer, and asking again on
//  every tap between the two segments would spend a request on the same empty
//  answer forever. A reviewer who has just acted gets a fresh one on their
//  next selection of the tab — see ``forget(_:)`` — because acting is the
//  thing that changes the answer, and it is the only thing that does.
//
//  That budget is why the rows outlive the tab — see ``stopBrowsing()``. A
//  list held for one request a launch and thrown away on every tap between
//  the segments is a list that is gone for the rest of the launch, which is
//  exactly what it was.
//
//  ## Why a failed load says nothing
//
//  This is the one list in the feature that fails silently, and it is
//  deliberate rather than an oversight of the kind the browse path was fixed
//  for. Every hiker's app runs this query. A phone in a valley would put a
//  *couldn't load the review queue* row in front of somebody who has no queue
//  and no idea what one is — so a failure here draws nothing, exactly as an
//  empty answer draws nothing, and goes to the log instead.
//
//  The *actions* are the opposite and must stay that way. Publishing and
//  declining are done by somebody who is demonstrably in the role, looking at
//  a hike they chose, and a failure there is reported on the screen that asked
//  — see ``CommunityReviewView``. Silence is right for a question nobody
//  asked and wrong for an answer somebody is waiting on.
//

import Foundation
import os

/// The submissions waiting for a person, held for as long as the tab is up.
///
/// A `@MainActor` `@Observable` reference for the reason ``CommunityBrowser``
/// is one: it is read from a SwiftUI body and written from a `Task` that
/// finished a network request.
@MainActor
@Observable
final class CommunityReviewQueue {
    /// Hikes waiting for a person, oldest first. Empty for everybody who is
    /// not a reviewer, which is the whole access control — see this file's
    /// header.
    private(set) var pending: [CommunityPendingSubmission] = []

    /// Photographs waiting for a person, oldest first.
    ///
    /// The second half of one answer rather than a second question — both
    /// arrive from the single ``CommunityTransporting/reviewQueue()`` call
    /// this launch spends, because the queue is asked for by everybody and
    /// almost none of them is a reviewer. See ``CommunityReviewBatch``.
    private(set) var pendingPhotos: [CommunityPendingPhotos] = []

    /// Whether there is anything at all to review.
    ///
    /// What the section is drawn on. Asked of both halves together because
    /// the section is one section: a reviewer with two contributions and no
    /// hikes has work waiting, and a rule that read only ``pending`` would
    /// have hidden it.
    var hasWork: Bool { !pending.isEmpty || !pendingPhotos.isEmpty }

    /// How many things are waiting, which is what the header counts.
    var workCount: Int { pending.count + pendingPhotos.count }

    /// Whether a request is in flight.
    ///
    /// Read only to keep a second one from starting. Nothing draws a spinner
    /// for this: a list that is invisible until it has rows has nothing to
    /// show a spinner *in*, and putting one in the Community tab for every
    /// hiker would advertise a feature almost none of them have.
    private(set) var isLoading = false

    /// Whether the server let this account read the queue at all.
    ///
    /// The one thing on the device that says *reviewer*, and it is not a
    /// stored claim: it is the last answer the server gave, false until one
    /// arrives. A reviewer whose queue is empty is still a reviewer, which is
    /// exactly the case an empty ``pending`` cannot express and the reason
    /// this is separate from it — a hike that is already published has no
    /// queue row, so offering a takedown on one has nothing else to go on.
    ///
    /// Forging it buys nothing: every action it gates is refused by the
    /// server for an account outside the role, so a modified build that sets
    /// it gets the buttons and a permission failure behind each of them.
    private(set) var isReviewer = false

    @ObservationIgnored private let transport: (any CommunityTransporting)?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// Which request the state belongs to.
    ///
    /// A cancelled `Task` still runs to its next suspension point, so the one
    /// ``refresh()`` supersedes comes back after its replacement has already
    /// set ``isLoading``. Without this it would clear the flag out from under
    /// the request in flight, and the guard that keeps two requests from
    /// overlapping would stop holding — for the reader who wonders why the
    /// cancel above is not enough on its own.
    @ObservationIgnored private var loadGeneration = 0
    /// Whether this launch has already asked. See the header for why the
    /// answer is not asked for again on every tab selection.
    @ObservationIgnored private var hasAsked = false
    /// Requests that reached the transport, which is what proves the paragraph
    /// above rather than merely asserting it.
    @ObservationIgnored private(set) var issuedRequests = 0

    private static let logger = Logger(subsystem: "OpenHikes", category: "Community")

    init(transport: (any CommunityTransporting)?) {
        self.transport = transport
    }

    /// The *Community* tab was selected. Asks once per launch.
    func startBrowsing() {
        guard !hasAsked else { return }
        refresh()
    }

    /// Asks again, whatever has been asked before.
    ///
    /// What ``startBrowsing()`` runs once a launch, and what it runs again
    /// after a decision has spent that answer — see ``forget(_:)``.
    func refresh() {
        guard let transport else { return }
        guard !isLoading else { return }
        hasAsked = true
        isLoading = true
        issuedRequests += 1
        loadGeneration += 1
        let generation = loadGeneration
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let result: CommunityReviewBatch
            do {
                result = try await transport.reviewQueue()
            } catch CommunityFailure.notPermitted {
                // The ordinary answer for almost every launch, and not an
                // error in any sense a hiker would recognise: they asked for
                // nothing and are owed nothing. Recorded rather than reported.
                await MainActor.run {
                    guard let self, generation == self.loadGeneration else { return }
                    self.isReviewer = false
                    self.isLoading = false
                }
                return
            } catch {
                // A real failure — no network, a busy service — and still
                // deliberately quiet. See *Why a failed load says nothing*.
                // ``isReviewer`` is left alone rather than set false: a
                // reviewer in a valley is still a reviewer, and dropping the
                // answer would take the takedown action away for the rest of
                // the launch.
                Self.logger.error(
                    """
                    Could not read the review queue: \
                    \(error.localizedDescription, privacy: .public)
                    """
                )
                await MainActor.run {
                    guard let self, generation == self.loadGeneration else { return }
                    self.isLoading = false
                }
                return
            }
            guard !Task.isCancelled else {
                await MainActor.run {
                    guard let self, generation == self.loadGeneration else { return }
                    self.isLoading = false
                }
                return
            }
            await MainActor.run {
                guard let self, generation == self.loadGeneration else { return }
                // The read succeeded, so the account is in the role — however
                // few rows came back with it.
                self.isReviewer = true
                self.pending = result.hikes
                self.pendingPhotos = result.photographs
                self.isLoading = false
            }
        }
    }

    /// The tab was left. Abandons a request still in flight; keeps the rows.
    ///
    /// The rows stay, and this is the one place this type deliberately parts
    /// company with ``CommunityBrowser/stopBrowsing()``, which drops its own.
    /// The browser's results are an answer about *an area of the map*, and the
    /// map moves while the list is away, so holding them would be holding
    /// something that may since have become untrue. A queue is not an answer
    /// about anywhere. Nothing a reviewer does between the two segments can
    /// make it wrong, and the once-a-launch rule means there is no second
    /// request coming to replace what is thrown away.
    ///
    /// Emptying it here is what made the section vanish on the way back and
    /// stay vanished until the app was relaunched: the rows went, and
    /// ``startBrowsing()`` then declined to ask for them again because the
    /// launch had already had its question. The two rules were each defensible
    /// and could not both hold.
    ///
    /// ``isReviewer`` stays for the same reason: it is a fact about the
    /// account rather than about the list.
    func stopBrowsing() {
        loadTask?.cancel()
        loadTask = nil
        // A request cancelled on the way out never answered, so the launch has
        // not in fact asked yet — otherwise leaving the tab during the one
        // request of the launch would lose it, which is the same disappearance
        // in a narrower window.
        if isLoading { hasAsked = false }
        isLoading = false
    }

    /// Takes one entry out, because it has been published or declined.
    ///
    /// Locally and at once, rather than by asking the server again. The
    /// decision has already landed — both actions delete the notice — and a
    /// round trip before the row disappears would leave a reviewer looking at
    /// a hike they have just dealt with, which is the state that invites doing
    /// it twice.
    func forget(_ submission: CommunityPendingSubmission) {
        pending.removeAll { $0.id == submission.id }
        spendTheLaunchsQuestion()
    }

    /// Takes one contributed set out, for the same reason and in the same
    /// breath.
    ///
    /// A second method rather than one taking an id, because the two lists are
    /// keyed on notices of the same type and a single `removeAll` across both
    /// would silently take the wrong row out on the day two notices collide.
    /// See ``CommunityReviewBatch`` for why the two stay apart.
    func forget(_ photos: CommunityPendingPhotos) {
        pendingPhotos.removeAll { $0.id == photos.id }
        spendTheLaunchsQuestion()
    }

    /// The launch's one question is spent: acting is the thing that changes
    /// the answer, so the next time the tab is taken this asks again rather
    /// than redrawing a list from before the decision.
    ///
    /// Not a request *now* — the reviewer is on their way back to a list this
    /// device has already corrected, and a round trip in front of it would buy
    /// them nothing they cannot see.
    private func spendTheLaunchsQuestion() {
        hasAsked = false
    }
}
