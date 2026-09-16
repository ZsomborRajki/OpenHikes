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
    /// How faint a photograph goes once it has been struck off.
    ///
    /// Still legible on purpose. The tile is the only handle for putting it
    /// back, and a reviewer who removed the wrong one has to be able to see
    /// which one they removed.
    private static let removedTileOpacity: Double = 0.3

    let pending: CommunityPendingSubmission
    let transport: any CommunityTransporting
    var queue: CommunityReviewQueue
    /// Written, never read: it is what puts this submission's route and the
    /// places its photographs were taken on the map behind the sheet. See this
    /// file's header.
    var browser: CommunityBrowser
    /// Pops the screen. Run after a decision has landed, and after nothing
    /// else — a reviewer who backs out has decided nothing.
    let onFinished: () -> Void

    /// Seeds the title field from the submission.
    ///
    /// A hand-written initializer for that one line. The alternative is
    /// copying the title into the field from `.task`, which runs again on
    /// every appearance and would quietly undo an edit the reviewer had
    /// already made.
    init(
        pending: CommunityPendingSubmission,
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
        _titleDraft = State(initialValue: pending.title)
    }

    private enum Phase {
        case loading
        case loaded(CommunityHikeDetail)
        case failed(CommunityFailure)
    }

    @State private var phase: Phase = .loading
    /// How many photographs arrived.
    ///
    /// Zero until they do, because that is the only moment it can be known —
    /// see ``CommunityPendingSubmission/photoCount``. Held here rather than
    /// read off the detail at the tap so that what is published is a value
    /// this screen watched arrive.
    ///
    /// Not the number written onto the listing, and not the one in the strip's
    /// header either: the listing's is ``CommunityPublishedPhotos/count``,
    /// which describes the *record*, and the header's is ``keptPhotoCount``,
    /// which describes what is on screen.
    @State private var photoCount = 0
    /// The title as it will be published, which starts as the one that was
    /// sent.
    ///
    /// Only ever the *listing's* title. The submission keeps what its author
    /// wrote — see this file's header for why that is both possible and
    /// deliberate.
    @State private var titleDraft: String
    /// Which photographs the reviewer has struck off, by their index in the
    /// detail.
    ///
    /// Indexes rather than files, because the index is what pairs a
    /// photograph with its pin and with its asset, and it is the one thing
    /// that survives the set changing. Nothing has happened to any of them
    /// until Publish: a removal is reversible for exactly as long as the
    /// decision is.
    @State private var removedPhotos: Set<Int> = []
    /// Whether the title field has the keyboard.
    ///
    /// Written by the *Done* button above the keyboard and by nothing else —
    /// see ``submissionSection`` for why that button is here rather than
    /// being a convenience.
    @FocusState private var isEditingTitle: Bool
    @State private var isDeciding = false
    @State private var isConfirmingDecline = false
    @State private var decisionFailure: CommunityFailure?
    @State private var loadTask: Task<Void, Never>?
    /// The publish or decline in flight, held for the same reason
    /// ``loadTask`` is: the downloads are deleted behind whatever is still
    /// using them.
    ///
    /// It matters more here than it reads. A publish that takes photographs
    /// off the submission uploads the kept ones **from that directory**, so a
    /// reviewer who swipes back mid-decision would have the files pulled out
    /// from under the upload. The save is one record and atomic, so the worst
    /// case was always a failed edit rather than half a hike — but a failed
    /// edit nobody is on screen to see is worth not arranging.
    @State private var decisionTask: Task<Void, Never>?
    /// This visit, told apart from any other visit to the same submission —
    /// the same per-visit rule ``CommunityHikeView`` follows, and for the same
    /// reason: two visits must not share a directory that either can delete.
    @State private var previewSession = UUID()

    private var downloadDirectory: URL {
        CommunityStaging.previewDirectory(of: pending.prospectiveListing, in: previewSession)
    }

    /// Whether the thing being decided about has actually arrived.
    ///
    /// Publishing waits on it for two reasons, and each would be enough on its
    /// own. Nothing knows how many photographs there are until the detail
    /// arrives — a queue entry cannot, see
    /// ``CommunityPendingSubmission/photoCount`` — so a publish before then
    /// writes *no photos* onto a listing that has some, which is a row that
    /// hides a gallery it could have shown. And a screen still loading, or one
    /// that failed to load, has shown the reviewer a title and nothing else:
    /// the description and the photographs are what they are here to judge.
    ///
    /// The title is the exception, and deliberately so — it is editable from
    /// the moment the screen opens, because the queue entry carries it and a
    /// reviewer can perfectly well fix a name while the pictures arrive.
    private var hasLoaded: Bool {
        if case .loaded = phase { return true }
        return false
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
        hasLoaded && !pending.authorID.isEmpty && !isDeciding && !publishedTitle.isEmpty
    }

    /// The title this would be published under, bounded the way every other
    /// piece of free text reaching the public database is.
    ///
    /// Bounded here rather than on the field, so the reviewer types against no
    /// resistance and the ceiling applies to what is written — the same
    /// division ``HikeTitle`` makes, and the same ``TextBound/title`` the
    /// queue already bounded the submitted title to.
    ///
    /// Empty is possible, by clearing the field, and is refused rather than
    /// falling back to the submitted title: a reviewer who has emptied the box
    /// is mid-edit, and quietly publishing the name they just deleted is the
    /// app deciding something they did not.
    private var publishedTitle: String {
        BoundedText.boundedOrEmpty(titleDraft, to: .title)
    }

    /// How many photographs would go with the hike.
    private var keptPhotoCount: Int {
        photoCount - removedPhotos.count
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
            CommunityHikeView.discardDownloads(
                at: downloadDirectory,
                after: [loadTask, decisionTask]
            )
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
}

// MARK: - What is being decided

private extension CommunityReviewView {
    /// The title and credit, which are what a listing is found and read by.
    ///
    /// The title is a field rather than a label, and it is the only editable
    /// thing on this screen that is not a photograph — see this file's header.
    var submissionSection: some View {
        Section {
            LabeledContent("Title") {
                TextField("Title", text: $titleDraft)
                    .multilineTextAlignment(.trailing)
                    .disabled(isDeciding)
                    .focused($isEditingTitle)
                    .submitLabel(.done)
                    // The same *Done* the hike's own title field carries, and
                    // here it is the difference between reaching the decision
                    // and not. This screen is a `Form` in a sheet that rests
                    // at half height: the keyboard covers what is left of it,
                    // *Publish* and *Decline* are at the foot, and a `Form`
                    // builds its rows lazily — so a reviewer who has just
                    // corrected a name can be left with neither the room to
                    // scroll to the decision nor a row down there to scroll
                    // to. `CommunityReviewUITests` failed on both halves of
                    // that before this button existed.
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { isEditingTitle = false }
                        }
                    }
                    .accessibilityIdentifier("review-title-field")
            }
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
            VStack(alignment: .leading, spacing: 4) {
                Text("Sent \(pending.noticedAt.formatted(date: .abbreviated, time: .shortened))")
                if publishedTitle != pending.title {
                    // What the hiker called it, kept in front of the reviewer
                    // rather than replaced by the edit. It is the thing being
                    // corrected, so it is the thing an edit has to be judged
                    // against — and a reviewer who has second thoughts should
                    // not have to leave the screen to recover it.
                    Text("Sent as “\(pending.title)”")
                        .accessibilityIdentifier("review-original-title")
                }
            }
        }
    }

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

    /// The photographs, each one removable on its own.
    ///
    /// Struck off rather than deleted as they are tapped: nothing leaves the
    /// submission until Publish, so a reviewer who hits the wrong tile puts it
    /// back with the same tap. That is also why the removed ones stay in the
    /// strip, faded — a tile that vanished would take its own undo with it.
    func photosSection(_ detail: CommunityHikeDetail) -> some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(detail.photoFileURLs.enumerated()), id: \.offset) { index, url in
                        photoTile(at: index, url: url, removable: detail.hasEveryPhoto)
                    }
                }
            }
            .accessibilityIdentifier("review-photos")
        } header: {
            // Two numbers only once they differ, so the ordinary case reads
            // exactly as it did.
            Text(
                removedPhotos.isEmpty
                    ? "Photos (\(detail.photoFileURLs.count))"
                    : "Photos (\(keptPhotoCount) of \(detail.photoFileURLs.count))"
            )
        } footer: {
            photosFooter(detail)
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
                        isRemoved ? "review-photo-restore" : "review-photo-remove"
                    )
                }
            }
    }

    /// What the strip needs saying about it, in the order it matters.
    @ViewBuilder
    func photosFooter(_ detail: CommunityHikeDetail) -> some View {
        if !detail.hasEveryPhoto {
            // The one state where removal is withheld, and it is withheld
            // rather than risked: publishing rebuilds the record's photographs
            // out of the copies on this device, so doing it with one missing
            // would delete that one as well — a photograph nobody decided
            // anything about, gone for good. See
            // ``CommunityHikeDetail/hasEveryPhoto``.
            Text(Self.incompleteDownload(missing: detail.photosOnRecord - detail.photoFileURLs.count))
                .accessibilityIdentifier("review-photos-incomplete")
        } else if removedPhotos.isEmpty {
            Text("Leave out any photo that shouldn't be published. The hike still goes.")
        } else {
            // Said plainly because it is the only irreversible thing on this
            // screen short of declining, and because the strip above is still
            // showing the pictures it is about.
            Text(Self.removalWarning(count: removedPhotos.count))
                .accessibilityIdentifier("review-photos-removed")
        }
    }

    /// Why nothing can be left out, when a download came back short.
    ///
    /// Number-neutral after the count, the rule ``CommunityShareDisclosure``
    /// already follows: one photograph reads as written English rather than as
    /// a template with a 1 in it.
    static func incompleteDownload(missing: Int) -> String {
        missing == 1
            ? String(
                localized: """
                One of this submission's photos didn't download, so none can be \
                left out here — leaving one out rewrites the whole set from the \
                copies on this device. Publish it as it is, decline it, or open \
                it again.
                """
            )
            : String(
                localized: """
                \(missing) of this submission's photos didn't download, so none \
                can be left out here — leaving one out rewrites the whole set \
                from the copies on this device. Publish it as it is, decline it, \
                or open it again.
                """
            )
    }

    static func removalWarning(count: Int) -> String {
        count == 1
            ? String(
                localized: """
                Publishing deletes the faded photo from the submission for good. \
                The rest go with the hike.
                """
            )
            : String(
                localized: """
                Publishing deletes the \(count) faded photos from the submission \
                for good. The rest go with the hike.
                """
            )
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
        .accessibilityIdentifier("review-failure")
    }
}

// MARK: - Deciding

private extension CommunityReviewView {
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
            } else if !hasLoaded {
                // The same rule the button is disabled by, said out loud —
                // see ``hasLoaded``. Declining stays available, because a
                // submission that will not load is a perfectly good reason to.
                Text("Publishing waits for the description and photographs to load.")
            } else if publishedTitle.isEmpty {
                // A reviewer mid-edit rather than a submission with a problem,
                // which is why it says what to do rather than what is wrong.
                Text("A hike needs a title. Put one back to publish this.")
            } else {
                Text("Publishing makes this visible to everybody, immediately.")
            }
        }
    }

    /// Strikes a photograph off, or puts it back.
    ///
    /// The map is told either way, so the pins and the strip never describe
    /// different sets — a reviewer who has just removed the picture of the
    /// gate should not still see a camera standing at the gate.
    func toggleRemoval(of index: Int) {
        if removedPhotos.contains(index) {
            removedPhotos.remove(index)
        } else {
            removedPhotos.insert(index)
        }
        guard case .loaded(let detail) = phase else { return }
        browser.previewPhotosLoaded(keptPreviewPhotos(of: detail), of: pending.prospectiveListing)
    }

    /// Where the photographs that are still going were taken.
    func keptPreviewPhotos(of detail: CommunityHikeDetail) -> [CommunityPreviewPhoto] {
        detail.previewPhotos.filter { !removedPhotos.contains($0.index) }
    }

    func publish() {
        guard canPublish, case .loaded(let detail) = phase else { return }
        isDeciding = true
        decisionTask = Task {
            // Both halves of what happens to the photographs, decided
            // together: which of them the record keeps, and what the listing
            // may then claim. An incomplete download answers *keep the record
            // as it is* — the rewrite is built from the copies on this device
            // and would delete the missing one too — and the count follows
            // that rather than the strip on screen. See
            // ``CommunityPublishedPhotos``.
            let photos = CommunityPublishedPhotos(
                photosOnRecord: detail.photosOnRecord,
                downloaded: detail.photoFileURLs.count,
                removing: removedPhotos
            )
            if case .keepOnly(let keeping) = photos.rewrite {
                do {
                    // Before the listing exists, never after: until one does,
                    // nothing can reach this submission but the reviewer
                    // holding its record name. See
                    // ``CommunityTransporting/keepOnlyPhotos(_:of:staging:)``.
                    try await transport.keepOnlyPhotos(
                        detail.keptPhotos(at: keeping),
                        of: pending,
                        staging: downloadDirectory
                    )
                } catch {
                    // Nothing has been published, so this is a failed edit
                    // rather than a failed publication, and the screen stays
                    // where it is with every removal still struck off. Trying
                    // again is the whole of the recovery, and it is safe to:
                    // the kept set is the same set and the files behind it are
                    // the same files, so a second attempt writes what the
                    // first one meant to — including after an edit that
                    // landed and a publication that did not.
                    fail(error)
                    return
                }
            }

            var decided = pending
            // The reviewer's title, which is the listing's alone — see this
            // file's header.
            decided.title = publishedTitle
            // What the record will serve, which is the only number a row can
            // promise: a listing claiming photographs it has not got opens a
            // shorter gallery than it advertised, and one claiming fewer than
            // the record holds hides a stranger's photograph that anybody
            // opening the hike can still fetch. The second is what a download
            // that came back short used to write.
            decided.photoCount = photos.count
            do {
                _ = try await transport.publish(decided)
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
                try await transport.decline(pending)
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
    ///
    /// The queue is told rather than re-asked, for the reason
    /// ``CommunityReviewQueue/forget(_:)`` gives.
    func finish() {
        isDeciding = false
        queue.forget(pending)
        onFinished()
    }

    func load() async {
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
            // And where each photograph was taken, which is half of what a
            // reviewer is judging one by — see this file's header. Filtered
            // through the removals for the same reason every later republish
            // is, even though there can be none this early: one expression for
            // *what the map shows* is one fewer place for the strip and the
            // pins to drift apart.
            browser.previewPhotosLoaded(
                keptPreviewPhotos(of: detail),
                of: pending.prospectiveListing
            )
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
