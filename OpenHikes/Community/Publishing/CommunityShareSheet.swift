//
//  CommunityShareSheet.swift
//  OpenHikes
//
//  What the share button opens: the one screen where a hiker decides to make
//  a private walk public.
//
//  It is a form rather than a confirmation alert, and the difference is the
//  point. Publishing a hike hands over a route somebody walked, the
//  photographs they took on it, and a name to put beside both — and an alert
//  with "Share" and "Cancel" would be asking for that without ever showing it.
//  So the screen says what goes, says what happens next, and asks for the name
//  in the same breath.
//
//  The notes are the newest thing it asks for, and the one place in this app a
//  hiker can write about a walk at all. ``Hike/trackDescription`` had exactly
//  three sources — a GPX file's `<desc>`, a hike imported from one, and a hike
//  saved from somebody else's community listing — and no screen that could put
//  anything in it. So a walk recorded on this phone, which is every walk this
//  feature is for, could only ever be published with nothing written about it,
//  and the reviewer read "Nothing written." every time. The field was already
//  here as a read-only row warning about text an imported file had brought
//  along; it is the same row, now able to answer.
//
//  What it must not say is that the hike is now visible. It is not: a
//  submission waits for a person to review it, and at the moment the upload
//  lands nothing has happened beyond that. The success state therefore says
//  *sent*, which is the only thing true then.
//
//  Later is a different question, and the hike's own screen asks it rather
//  than this one — ``CommunityPublicationCheck`` looks for a listing published
//  from the submission and remembers a yes. That is the single thing the app
//  can observe: a reviewer who has not looked and one who declined leave the
//  same absence behind. See ``CommunityPublicationState``.
//

import SwiftData
import SwiftUI

struct CommunityShareSheet: View {
    let hike: Hike
    let transport: any CommunityTransporting
    /// Where the photo files are, so the form can ask which of this hike's
    /// pictures this device actually holds. Injected rather than reached for,
    /// like every other store this app hands a view.
    var store: HikePhotoStore = .shared

    @Environment(\.dismiss)
    private var dismiss
    @Environment(\.modelContext)
    private var modelContext
    @AppStorage(SettingsKey.communityAuthorName)
    private var authorName = ""
    @State private var phase: CommunitySendPhase = .editing
    /// What the hiker has written about this walk, held here and committed to
    /// the hike rather than bound straight through to it.
    ///
    /// A `@Model`'s property is a store write on every keystroke, which is the
    /// wrong shape for prose; and this is text a hiker is composing rather
    /// than a setting they are flipping. See ``commitNotes()`` for when it
    /// lands.
    @State private var notesDraft = ""
    /// Whether ``notesDraft`` has been filled from the hike yet.
    ///
    /// The seeding happens on appearance rather than in an initializer,
    /// because this is a sheet and SwiftUI may build its body before it is
    /// presented; without the flag, a second pass would overwrite what the
    /// hiker had started typing with what the hike still says.
    @State private var hasSeededNotes = false
    /// What the hike will be called, held here and committed for the reason
    /// ``notesDraft`` is: a `@Model`'s property is a store write per
    /// keystroke.
    ///
    /// This one renames the hike itself rather than only the copy that goes
    /// public — see ``commitTitle()``. A hiker who is about to publish
    /// "Morning walk" is looking at the name for the first time in a while and
    /// is the most likely person in the world to fix it, and a correction that
    /// only the strangers saw would leave their own library still wrong.
    @State private var titleDraft = ""
    @State private var hasSeededTitle = false
    /// The photographs struck off the strip, by id.
    ///
    /// Held by id rather than by index, because the list is re-derived on
    /// every pass and an index would follow whatever moved into that slot.
    /// Empty is the starting state and the ordinary one: sharing a hike shares
    /// its pictures, and this is the exception the hiker reaches for.
    @State private var excludedPhotoIDs: Set<UUID> = []
    /// How many photographs this device can send, once the disk has been
    /// asked. `nil` until then. Kept and written here rather than inside
    /// ``CommunitySharePhotoTally`` because it is the answer to a `.task`,
    /// which is this view's to own — see
    /// ``SwiftUI/View/countsSendablePhotos(of:excluding:store:into:)``.
    @State private var sendablePhotoCount: Int?
    /// Whether this hike may be published at all, once the library has been
    /// asked. `nil` until then, and the Share button waits for it: offering a
    /// send that the answer is about to withdraw is worse than offering it a
    /// moment late.
    @State private var eligibility: CommunityPublishingEligibility?
    /// The trail this hike's photographs would go on instead, once the hiker
    /// has asked for that. `nil` is the ordinary state, including while the
    /// offer is merely being drawn.
    ///
    /// Only ever set from ``CommunityPublishingEligibility/photoTarget``,
    /// which is the single thing that decides where a contribution may be
    /// aimed.
    @State private var contributionTarget: CommunityPhotoTarget?

    /// Where this hike already is on the way to being published, which decides
    /// whether the form warns about making a second copy of it.
    private var publication: CommunityPublicationState {
        CommunityPublicationState(
            submissionID: hike.communitySubmissionID,
            listingID: hike.communityListingID
        )
    }

    /// What this share would actually carry, and what it would leave behind.
    ///
    /// ``CommunitySharePhotoTally`` rather than four members of this screen's
    /// own: the contribution form asks exactly the same question about exactly
    /// the same files, and the number under the strip has to be the number
    /// that goes on both.
    private var photos: CommunitySharePhotoTally {
        CommunitySharePhotoTally(
            hike: hike,
            excluding: excludedPhotoIDs,
            sendableCount: sendablePhotoCount
        )
    }

    /// The name this share is published under.
    ///
    /// Bounded and not merely trimmed, which is ``HikeTitle``'s rule applied
    /// to the other piece of free text a person types into this app — and the
    /// one that goes furthest, since it is written to a record in the public
    /// database and drawn in every other hiker's list. See ``TextBound/credit``.
    private var boundedAuthorName: String {
        BoundedText.boundedOrEmpty(authorName, to: .credit)
    }

    /// The description this share would publish, as the field currently
    /// stands.
    ///
    /// Read off the draft rather than off the hike, so the disclosure sentence
    /// below the form describes what is in the box: the promise and the
    /// payload being written in two places is the failure
    /// ``CommunityShareDisclosure`` exists to catch, and a footer that only
    /// noticed notes after they were committed would be a fresh instance of
    /// it.
    ///
    /// Editable rather than merely shown, which is the whole of this row's
    /// second job. Its first is unchanged and still worth having: a hike
    /// imported from a GPX file carries whatever its author wrote in it, which
    /// can be personal notes nothing in this app has displayed since the
    /// import, and it goes to the public database either way — see
    /// ``CommunityPublisher/share``, which copies `trackDescription` into the
    /// draft. The row is where a hiker finds that out in time to delete it.
    private var sharedDescription: String? {
        CommunityShareDisclosure.notes(from: notesDraft)
    }

    /// Which sections are up, which is entirely a question about ``phase`` and
    /// ``eligibility``.
    ///
    /// Extracted from `body` rather than written inline, because the form grew
    /// a title field and a photo strip and the `NavigationStack` closure
    /// around it went past what the linter allows. The seam is a good one
    /// anyway: what this screen *is* and what it *does when it appears* are
    /// two different lists to read.
    @ViewBuilder private var formContent: some View {
        switch phase {
        case .sent:
            sentSection
        default:
            // A refusal replaces the form rather than sitting above it. The
            // rest of this screen asks for a display name and explains what
            // will be published, and both are questions about a send that is
            // not going to happen — leaving them drawn and greyed would be the
            // app pretending to still be considering it.
            if let reason = eligibility?.reason {
                refusalSection(reason)
                // The offer the refusal leaves unspoken, where there is one.
                // See ``contributeSection(_:)``.
                if let target = eligibility?.photoTarget {
                    contributeSection(target)
                }
                contentsSection
            } else {
                duplicateSection
                contentsSection
                nameSection
                reviewSection
                if case .failed(let failure) = phase {
                    failureSection(failure)
                }
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form { formContent }
            .navigationTitle("Share Hike")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbarContent }
            .interactiveDismissDisabled(phase.isSending)
            .onAppear {
                seedNotes()
                seedTitle()
            }
            .onDisappear {
                commitNotes()
                commitTitle()
            }
            // Over this sheet rather than in place of it, because the hiker
            // has not left the decision this screen is about: backing out of
            // the photo form puts them back on the explanation they were
            // reading. The same form the hike's own toolbar opens for the two
            // saved-trail refusals — this is the third way in, and the only
            // one that needs a fetch to know it exists.
            .sheet(item: $contributionTarget) { target in
                CommunityPhotoShareSheet(
                    hike: hike,
                    target: target,
                    transport: transport,
                    store: store
                )
            }
            .countsSendablePhotos(
                of: hike,
                excluding: excludedPhotoIDs,
                store: store,
                into: $sendablePhotoCount
            )
            // Asked here as well as on the hike's own screen, and not merely
            // trusted from there: the button is drawn from the two cheap rules
            // alone, and the retread check needs a fetch and a pass over every
            // route this hiker has already sent. This is the screen that can
            // afford it, and the one where a refusal has room to explain
            // itself.
            .task {
                eligibility = await CommunityPublishingCheck.eligibility(
                    of: hike,
                    in: modelContext
                )
            }
        }
    }
}

// MARK: - Sections

private extension CommunityShareSheet {
    var contentsSection: some View {
        Section {
            // Editable, where it used to be a `LabeledContent` reporting the
            // name back. A hiker about to publish is looking at their hike's
            // name for the first time in a while and is the likeliest person
            // to want it fixed — and a walk called "Morning walk" used to cost
            // a reviewer the choice between publishing that and declining the
            // whole upload. See ``CommunityReviewView``, which can still
            // correct a title and now has fewer reasons to.
            VStack(alignment: .leading, spacing: 4) {
                Text("Title")
                TextField("What was this hike?", text: $titleDraft)
                    .disabled(phase.isSending)
                    .accessibilityLabel("Hike title")
                    .accessibilityIdentifier("community-share-title")
            }
            LabeledContent("Route", value: hike.subtitle)
            // Always drawn, where it used to appear only for a hike that
            // already had a description. An empty box is an invitation and an
            // absent row is nothing at all — and absent was every hike anybody
            // recorded in this app, which is the gap this closes. See the
            // file's header.
            //
            // Vertical and multi-line, because the point of the row is the
            // prose: a hiker writing about a walk in a field that scrolls
            // sideways one line at a time is a hiker writing one sentence.
            VStack(alignment: .leading, spacing: 4) {
                Text("Notes")
                TextField(
                    "What was this hike like?",
                    text: $notesDraft,
                    axis: .vertical
                )
                .lineLimit(3...8)
                .disabled(phase.isSending)
                .accessibilityLabel("Notes about this hike")
                .accessibilityIdentifier("community-share-notes")
            }
            LabeledContent(
                "Photos",
                value: photos.count == 0 ? "None" : "\(photos.count)"
            )
            // One element with an explicit value, rather than the pair
            // `LabeledContent` composes on its own. An identifier on a
            // container is pushed down onto every descendant, so without this
            // the name matches the "Photos" caption first and a reader asking
            // for the row's value gets nothing — see ``CommunityPhotoViewer``
            // for where that lesson was learned.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Photos")
            .accessibilityValue(photos.count == 0 ? "None" : "\(photos.count)")
            .accessibilityIdentifier("community-share-photo-count")
            photoPicker
            if photos.unsendableCount > 0 {
                // Said here rather than left to the footer, because it is
                // about the row directly above it: the number there is
                // smaller than the strip on the hike screen, and a hiker who
                // is not told why will read it as the app having lost their
                // pictures.
                //
                // Same shape as everywhere else a photo's pixels are missing
                // — see ``PhotoUnavailability/notOnThisDevice``, which the
                // gallery, the map callout and the viewer all speak through.
                Label {
                    Text(CommunitySharePhotoTally.onAnotherDevice(count: photos.unsendableCount))
                } icon: {
                    Image(systemName: "icloud.slash")
                        .foregroundStyle(.secondary)
                }
                .font(.footnote)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("community-share-photos-elsewhere")
            }
        } header: {
            Text("What gets shared")
        } footer: {
            // Said plainly because it is the one surprise in the feature: a
            // hiker who has not thought about it assumes a shared trail is a
            // line on a map, and the photographs are the part they would want
            // to have been asked about.
            //
            // It has to be *complete* as well as plain, which is the harder
            // half. A submission carries the description and the date shown
            // above, and the route it carries is the recorded one — every
            // point with the time it was reached, so the pace of the walk goes
            // with the line. Saying "nothing else from this hike" while
            // sending those was a promise the upload did not keep.
            Text(
                CommunityShareDisclosure.text(
                    hasNotes: sharedDescription != nil,
                    photoCount: photos.count
                )
            )
        }
    }

    /// The hike's photographs, each one a tap away from being left out.
    ///
    /// Drawn by ``CommunitySharePhotoStrip``, which is shared with the
    /// contribution form — see that file for the three rules the two screens
    /// have to agree about and why a second spelling of any of them would make
    /// the same tap mean two things.
    @ViewBuilder var photoPicker: some View {
        CommunitySharePhotoStrip(
            photos: CommunityPublisher.shareablePhotos(of: hike),
            excluded: $excludedPhotoIDs,
            store: store,
            isSending: phase.isSending
        )
    }

    /// What the hike is credited to, asked for as the display name it is.
    ///
    /// It used to be labelled "Name", which left the hiker to decide whether
    /// they were being asked for the name on their Apple Account. Nothing in
    /// this app ever wanted that — ``CommunityListing/authorName`` has said
    /// "a credit and not an identity" since it was written, blank has always
    /// been allowed, and what it sits beside is a walk rather than a profile.
    /// The field now says so, which is also what settles how it is declared:
    /// Apple's definitions put a handle under `NSPrivacyCollectedDataTypeUserID`
    /// and a person's name under Contact Info. See `PrivacyInfo.xcprivacy`.
    ///
    /// Still capitalised by word. A display name is far more often "Anna" or
    /// "Ridge Walker" than a lowercase handle, and a keyboard can be overruled
    /// where a wrong guess about what is being asked for cannot be.
    var nameSection: some View {
        Section {
            TextField("Display name", text: $authorName)
                .accessibilityIdentifier("community-author-field")
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.words)
                #endif
                .disabled(phase.isSending)
        } header: {
            Text("Shared as")
        } footer: {
            Text("""
            Shown publicly next to your hike. It doesn't have to be your real \
            name, and you can leave it blank to share without one.
            """)
        }
    }

    /// The two things a hiker should know before the Share button, in the
    /// order they matter: that a person looks at this first, and what they are
    /// agreeing to by sending it.
    ///
    /// The terms were published from the day Community shipped and linked from
    /// nowhere in the app. That is the gap this closes. They are not boilerplate
    /// about a subscription — they are the rules this screen is the entry point
    /// to: that a hiker may publish only what is theirs to publish, that
    /// publishing grants a licence to show it inside the app, that a route
    /// starting at their front door says where they live, and how to have a
    /// hike taken down afterwards. A page nobody can reach from the screen it
    /// governs is a page nobody has agreed to.
    ///
    /// Stated beside Share rather than gated behind a checkbox. Apple mandates
    /// no particular control here, an unticked box on a form with one action is
    /// a tap spent on a sentence the hiker has already read, and what makes
    /// consent mean anything is that the rules were in front of them and
    /// reachable — which a `Link` is and a modal they have to dismiss is not.
    var reviewSection: some View {
        Section {
            Label {
                Text("Every community hike is checked by a person before anyone else can see it.")
            } icon: {
                Image(systemName: "checkmark.shield")
                    .foregroundStyle(.tint)
            }
            .font(.footnote)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                // What the list is *for*, said before what it forbids.
                //
                // The three rules `CommunityPublishingEligibility` enforces
                // are the mechanical half of this, and a hiker meets them by
                // not being refused. This is the half no program can check and
                // a reviewer decides: that the list reads like somebody local
                // pointing at walks worth doing, rather than like an export of
                // everything anybody ever recorded.
                Text("""
                Community hikes are walks worth someone else's day out — a whole route, \
                walked by you, that isn't already on the list.
                """)
                Text("""
                Share only a route, photos and notes that are yours to publish. A hike that \
                starts at your front door shows where you live.
                """)
                // The frame is what makes it line up. A `Link`'s label is
                // sized to its own text and centred inside whatever width it
                // is given, while the two paragraphs above fill the footer —
                // so the one line that is shorter than the column sat in the
                // middle of it, out of step with everything around it (#389).
                // Filling the width and aligning leading puts it back on the
                // same edge as the sentences it belongs to.
                Link(destination: MapPurchaseLinks.termsAndConditions) {
                    Text("By sharing, you agree to the Terms & Conditions.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                }
                .accessibilityIdentifier("community-terms-link")
            }
        }
    }

    /// Shown only for a hike that has already been sent, which the share
    /// button normally keeps out of here — it is disabled while a submission
    /// is waiting. What reaches this is the published case, where sharing
    /// again is a legitimate thing to want (it is the only way to publish an
    /// amended route) and also the one way to end up with two of the same walk
    /// in the list.
    ///
    /// A warning rather than a refusal, because the app cannot tell an
    /// accidental second tap from a deliberate re-share of a corrected
    /// route — and it cannot offer the thing that would make the choice
    /// unnecessary, since ``CommunityTransporting`` has no method to replace
    /// or withdraw a submission. So it says exactly what will happen and lets
    /// the hiker decide.
    @ViewBuilder var duplicateSection: some View {
        if publication.wouldDuplicate {
            Section {
                Label {
                    Text(
                        """
                        You've already shared this hike. Sending it again adds a \
                        second copy for other hikers — it doesn't replace or update \
                        the first, and this app can't take that one down. Ask for it \
                        to be removed by reporting it from its own screen.
                        """
                    )
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                .font(.footnote)
                .accessibilityIdentifier("community-share-duplicate")
            }
        }
    }

    /// Why this hike is not going anywhere, in place of the form.
    ///
    /// Warning-shaped rather than error-shaped: nothing has gone wrong, and
    /// none of the three reasons is the hiker having done something careless.
    /// Saving somebody else's walk, walking a short loop and walking a trail
    /// twice are all ordinary things; what the screen has to say is only that
    /// none of them is a thing to publish, and what they can do instead.
    func refusalSection(_ reason: CommunityPublishingEligibility.Reason) -> some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(reason.title)
                        .font(.callout.weight(.medium))
                    Text(reason.explanation())
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "person.2.slash")
                    .foregroundStyle(.orange)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("community-share-refusal")
        }
    }

    /// What the hiker can still do about a trail that is already in the list.
    ///
    /// The refusal above says the route is not going anywhere; this is the
    /// half that is, and without it the sentence *your photographs are a
    /// different matter* points at nothing. A hike saved from OpenStreetMap or
    /// from another hiker reaches the contribution form straight from the
    /// toolbar, because the cheap half of the eligibility can answer from the
    /// hike alone. A hike that **retraces one this hiker already published**
    /// cannot: that answer needs every other hike they have sent and a pass
    /// over the routes, which is this screen's fetch and nobody else's. So
    /// this is where that case is offered, and it is the only place it can be.
    ///
    /// Drawn whenever there is a target rather than only for the retread — one
    /// rule is easier to hold than an exception, and a second door to the same
    /// form cannot say anything different about it.
    func contributeSection(_ target: CommunityPhotoTarget) -> some View {
        Section {
            Button {
                contributionTarget = target
            } label: {
                Label("Add Your Photos Instead", systemImage: "photo.badge.plus")
            }
            .accessibilityIdentifier("community-share-contribute")
        } footer: {
            Text("""
            Your photographs are yours, and \(target.title) is already in the list. \
            They go on it with the spot each one was taken, and a person reviews them \
            before anybody else sees them.
            """)
        }
    }

    func failureSection(_ failure: CommunityFailure) -> some View {
        CommunityFailureNotice(failure: failure, identifier: "community-share-failure")
    }

    var sentSection: some View {
        CommunitySentSection(
            detail: "It'll appear for other hikers once it's been checked.",
            identifier: "community-share-sent"
        )
    }

    @ToolbarContentBuilder var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            // Committed here as well as in `onDisappear`, and this is the one
            // that can be relied on. A sheet's content is not guaranteed to be
            // torn down when it is dismissed — SwiftUI may keep the view
            // around — so `onDisappear` is a hook that sometimes runs rather
            // than a commit point. Both calls are idempotent, so the pair
            // costs nothing and closes the case where neither the title nor
            // the notes reach the hike because the screen never went away.
            Button(phase.hasFinished ? "Done" : "Cancel") {
                commitNotes()
                commitTitle()
                dismiss()
            }
            .disabled(phase.isSending)
        }
        ToolbarItem(placement: .confirmationAction) {
            if phase.isSending {
                ProgressView()
                    .accessibilityLabel("Sending")
            } else if !phase.hasFinished, eligibility?.reason == nil {
                Button("Share") { share() }
                    .accessibilityIdentifier("community-share-confirm")
                    // The same floor ``CommunityPublisher/share`` refuses
                    // below, so a hike with no route cannot start an upload
                    // that was always going to come back as a failure. Also
                    // held while eligibility is still `nil`, which is the one
                    // window in which a tap could start a send the next line
                    // of this screen is about to forbid.
                    .disabled(hike.pointCount < 2 || eligibility == nil)
            }
        }
    }
}

// MARK: - Sharing

private extension CommunityShareSheet {
    func share() {
        // Before the upload, not after: ``CommunityPublisher/share`` reads
        // `trackDescription` off the hike, so this is the line that decides
        // whether what the hiker just typed goes with it.
        commitNotes()
        // And the title, for the same reason and in the same breath:
        // ``CommunityPublisher/share`` reads `displayTitle` off the hike, so
        // this is the line that decides whether the correction goes with it.
        commitTitle()
        phase = .sending
        Task {
            let outcome = await CommunityPublisher.share(
                hike,
                authorName: boundedAuthorName,
                transport: transport,
                excludingPhotos: excludedPhotoIDs
            )
            phase = CommunitySendPhase(outcome)
        }
    }

    /// Fills the notes field from the hike, once.
    ///
    /// A hike imported from a GPX file arrives with its author's words already
    /// in it, and this is what puts them in front of the person about to
    /// publish them. Guarded rather than bound, for the reason
    /// ``hasSeededNotes`` gives.
    func seedNotes() {
        guard !hasSeededNotes else { return }
        hasSeededNotes = true
        notesDraft = hike.trackDescription ?? ""
    }

    /// Fills the title field from the hike, once, for the reason
    /// ``seedNotes()`` is guarded.
    func seedTitle() {
        guard !hasSeededTitle else { return }
        hasSeededTitle = true
        titleDraft = hike.displayTitle
    }

    /// Renames the hike, if the field says something the hike does not.
    ///
    /// The whole rule is ``HikeTitleEdit``, which is where it can be tested —
    /// a `View` is not somewhere a suite can ask whether leaving a field alone
    /// writes to the store. The two cases it separates both matter here:
    /// untouched text must not turn a hike's own title into a custom name that
    /// merely matches it, and an emptied field means "go back to what this was
    /// called" rather than "call it nothing".
    ///
    /// Idempotent, like ``commitNotes()``, and called in the same two places:
    /// before the upload reads ``Hike/displayTitle``, and on the way out — so
    /// a hiker who fixes the name and then thinks better of publishing still
    /// keeps the name.
    func commitTitle() {
        guard hasSeededTitle else { return }
        guard case .renamed(let name) = HikeTitleEdit.of(titleDraft, against: hike.displayTitle)
        else { return }
        hike.customName = name
    }

    /// Puts the draft on the hike, bounded the way every other piece of free
    /// text entering this app is.
    ///
    /// ``TextBound/notes`` and ``BoundedText/bounded(_:to:)``, which is what
    /// makes the answer a `String?`: an absent description and an empty one
    /// are the same thing, and the optional is what says so once. So clearing
    /// the box clears the hike's description rather than storing a blank.
    ///
    /// Idempotent, which it has to be: ``share()`` calls it before the upload
    /// reads the hike, and `onDisappear` calls it again on the way out — so
    /// the notes belong to the walk whether or not the share happened, and a
    /// hiker who thinks better of publishing keeps what they wrote.
    func commitNotes() {
        guard hasSeededNotes else { return }
        let bounded = BoundedText.bounded(notesDraft, to: .notes)
        // Compared before assigning, so leaving the sheet untouched is not a
        // write to the store: SwiftData mirrors this column, and a no-op
        // change is a sync the hike did not need.
        guard hike.trackDescription != bounded else { return }
        hike.trackDescription = bounded
    }
}

// MARK: - What the footer promises

/// The sentence under *What gets shared*, worked out apart from the view that
/// draws it.
///
/// Its own type so a suite can hold it against what ``CommunityPublisher``
/// actually uploads. That is the only way this stays true: the promise and the
/// payload are written in two different files, and the first version of this
/// screen said "nothing else from this hike" while the upload carried the
/// description, the date and a timestamp on every point of the route. A
/// wording that cannot be tested is a wording that drifts the next time a
/// field is added to ``CommunitySubmissionDraft``.
nonisolated enum CommunityShareDisclosure {
    /// The description a share would publish, or `nil` for a hike whose
    /// description is absent or blank.
    ///
    /// Here rather than in the view so that the row showing it and the
    /// sentence promising it cannot disagree about what counts as having one
    /// — and so a suite can ask the same question of a draft.
    static func notes(from trackDescription: String?) -> String? {
        guard let notes = trackDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
              !notes.isEmpty
        else { return nil }
        return notes
    }

    /// - Parameters:
    ///   - hasNotes: Whether the hike has a description, which is uploaded and
    ///     shown publicly — see ``CommunityShareSheet``'s `sharedDescription`.
    ///   - photoCount: How many photographs this share would carry, already
    ///     capped at ``CommunityPublisher/maximumPhotos``.
    static func text(hasNotes: Bool, photoCount: Int) -> String {
        // Assembled rather than written out four times: notes and photographs
        // are each present or not, and four separate spellings is how one of
        // them ends up describing an upload that has moved on.
        var sentences = [
            """
            Your route — each point on it with the time you reached it — \
            its name, its length and the date you walked it.
            """,
        ]
        if hasNotes {
            sentences.append("The notes above go with it.")
        }
        if photoCount > 0 {
            // The time as well as the place, because a pin is both. The
            // sentence used to name only the coordinate while
            // ``CommunityPhotoPin`` carried `capturedAt` too — uploaded in the
            // pins asset, where the re-encode that strips EXIF never reaches
            // it — so the reassurance that followed read as a promise in the
            // other direction. *Taken* is the word the rest of the app already
            // uses for that timestamp: see `PhotoDiscoverySheet` and
            // ``HikePhotoViewer``.
            //
            // Number-neutral after the count, so one photograph reads as
            // written English rather than as a template with a 1 in it.
            let photos = photoCount == 1
                ? "One photo goes with it, with the spot on the trail and the time it was taken at"
                : """
                \(photoCount) photos go with it, each with the spot on the trail \
                and the time it was taken at
                """
            sentences.append(
                """
                \(photos) — resized before sending, with camera details and original \
                location data removed.
                """
            )
        }
        sentences.append("Nothing else from this hike.")
        return sentences.joined(separator: " ")
    }
}
