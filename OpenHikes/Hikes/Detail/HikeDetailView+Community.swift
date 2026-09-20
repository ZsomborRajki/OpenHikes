//
//  HikeDetailView+Community.swift
//  OpenHikes
//
//  The community share control on the hike detail screen.
//
//  Split out for the reason the offline-storage helpers next door are: the
//  detail view is the largest screen in the app and the linter holds it to a
//  file length, so a subject that can stand on its own does.
//
//  The subject here is one button and the two things it has to answer before
//  it opens anything: where this hike is on the trip from private to published
//  (``CommunityPublicationState``), and whether there is a transport at all.
//
//  The button is not a single control with a badge on it. Its three states do
//  three different things, and until recently the middle one did nothing at
//  all: a hike waiting for review was a disabled glyph, because this app
//  cannot amend a submission or hurry anybody along, and leaving the tap live
//  so it opened a form that would send a *second* copy is the duplicate that
//  state exists to prevent.
//
//  What it *can* do is ask for the submission back. `docs/privacy` and
//  `docs/terms` both promise a hiker can have a shared hike taken down by
//  email, and both say in the same breath that deleting it from the device
//  does not withdraw it — and the two record names such a request needs live
//  only on the `Hike` row, so a deletion is what destroys them. See
//  ``CommunityWithdrawal``. So the two already-shared states now lead
//  somewhere:
//
//  - *waiting for review* has exactly one thing to do, and opens the request
//    form directly.
//  - *published* is a `Menu`, which is the shape for a control that genuinely
//    offers a choice. What it offers is **not** a second copy of the hike: it
//    used to lead with *Share Again*, and since a submission cannot be
//    amended, that made a second listing of the same walk and left the first
//    one live. The hiker who comes back to a published hike is almost always
//    carrying photographs they did not have on the day, so the item is now
//    *Add Photos to This Trail* — a contribution onto the listing that already
//    exists — beside the two ways to ask for something back, and beside the
//    one item that is about the listing rather than about anything sent to it:
//    *Check Whether It's Still Live*, which is how a hike that was taken down
//    finds its way back to being shareable at all. See
//    ``publishedMenuItems(_:_:)``.
//
//  ## And the state that used to be a dead end
//
//  A hike the app refused to publish drew a slashed glyph and opened a form
//  whose whole content was an explanation. For three of the four refusals that
//  explanation was really about the *route*: the trail is already in the list,
//  from OpenStreetMap or from somebody's upload or from this hiker's own
//  earlier walk. What was never already in the list is the photographs, and
//  those the hiker owns outright.
//
//  So the slashed glyph now splits in two, decided by
//  ``CommunityPublishingEligibility/photographsOnly(_:because:)``:
//
//  - a hike with somewhere for its pictures to go gets its own three states,
//    the same three the route has, read off the *other* pair of columns —
//    ``Hike/communityPhotoSubmissionID`` and
//    ``Hike/communityPhotoContributionID``. An offer, an hourglass, and a
//    menu once they are live.
//  - a hike with nowhere — a short walk that retraces nothing, or one
//    retracing a hike still waiting for review — keeps `person.2.slash` and
//    keeps opening the explanation, because that is still all there is to say.
//
//  The glyphs stay distinguishable from the route's three on purpose. *Sent a
//  hike* and *sent some photographs* are different things a hiker did, and a
//  toolbar that spelled both with `hourglass` would make the one question the
//  control exists to answer — what have I already done with this walk? —
//  unanswerable at a glance.
//

import SwiftUI

extension HikeDetailView {
    /// Offers this hike to the community, beside the GPX export.
    ///
    /// Two share buttons rather than one menu, because they are not two ways
    /// of doing the same thing: the GPX export hands a file to whatever the
    /// hiker chooses and OpenHikes never sees it again, while this publishes
    /// to a database other people read. Folding them into one control would
    /// make the second reachable by a gesture learned for the first, and the
    /// second is the one that cannot be taken back by the person who made it.
    ///
    /// Free, like the rest of the community feature. Publishing sat behind the
    /// subscription once, on the grounds that a published hike is storage and
    /// downloads the developer pays for; what that bought instead was a list
    /// most of the app's hikers could read and not add to, which is the one
    /// shape a shared list cannot recover from. Nothing about payment ever
    /// decided what reaches other people's screens — see ``CommunitySchema``,
    /// where a person reviewing every submission still does.
    ///
    /// Absent rather than disabled when this launch has no transport — a
    /// hosted test or UI automation, which must not write to a real shared
    /// database. A disabled button would be a promise the launch cannot keep.
    @ViewBuilder var communityShareButton: some View {
        if let transport = communityTransport {
            let publication = CommunityPublicationState(
                submissionID: hike.communitySubmissionID,
                listingID: hike.communityListingID
            )
            // The two rules that can be answered from this hike alone. The
            // third — whether it retraces something already sent — needs a
            // fetch and a pass over other routes, so the share form asks that
            // one when it opens; see ``CommunityPublishingCheck``.
            //
            // A refused hike keeps its button and opens the form, which
            // refuses and says why. Disabling the glyph instead would leave a
            // hiker looking at a dimmed control with no explanation anywhere
            // on the screen, which is the dead end the keyless provider rows
            // were fixed for one screen over.
            let eligibility = CommunityPublishingEligibility.of(
                importedFromListingID: hike.importedFromListingID,
                importedAuthorName: hike.importedAuthorName,
                distanceMeters: hike.distanceMeters,
                title: hike.displayTitle
            )
            let contribution = CommunityContributionState(
                submissionID: hike.communityPhotoSubmissionID,
                contributionID: hike.communityPhotoContributionID
            )
            let appearance = CommunityShareButtonAppearance(
                publication: publication,
                eligibility: eligibility,
                contribution: contribution
            )
            communityControl(appearance, publication, eligibility, contribution, transport)
                .accessibilityLabel(appearance.label)
                // What a tap will do is invisible in a toolbar glyph, so the
                // hint is the only place it can be explained.
                .accessibilityHint(appearance.hint)
                .accessibilityIdentifier("community-share-button")
                // A hike with no route can still carry photographs, and the
                // contribution path does not send one — so the floor that
                // holds the share button applies only where a route is what
                // is being sent.
                .disabled(hike.pointCount < 2 && !eligibility.offersPhotographs)
                // Asks once per appearance, and only for a hike that has been
                // sent and not yet seen live — see
                // ``CommunityPublicationCheck``. Here rather than on the detail
                // view's body because this control is the only thing that reads
                // the answer.
                .task(id: hike.id) {
                    await CommunityPublicationCheck.refresh(hike, transport: transport)
                }
                // And the same question about the other pair of columns, which
                // is a *different* request against a different record type and
                // is asked only for a hike that has contributed photographs
                // and not yet seen them live. Both are cheap in the case that
                // matters — a hike that has done neither asks nothing at all.
                .task(id: hike.id) {
                    await CommunityContributionCheck.refresh(hike, transport: transport)
                }
                .sheet(isPresented: $isSharingToCommunity) {
                    CommunityShareSheet(hike: hike, transport: transport)
                }
                .sheet(item: $contributionTarget) { target in
                    CommunityPhotoShareSheet(
                        hike: hike,
                        target: target,
                        transport: transport
                    )
                }
                .sheet(isPresented: $isWithdrawingFromCommunity) {
                    // Built here rather than held in state: the hike is the
                    // source of both record names, and a value captured when
                    // the menu opened could name a listing the refresh above
                    // has since found.
                    if let withdrawal = CommunityWithdrawal(hike: hike) {
                        CommunityWithdrawalSheet(withdrawal: withdrawal)
                    }
                }
                .sheet(isPresented: $isWithdrawingPhotosFromCommunity) {
                    // The same form about the other pair of record names, and
                    // built here for the same reason.
                    if let withdrawal = CommunityWithdrawal(contributedPhotosOf: hike) {
                        CommunityWithdrawalSheet(withdrawal: withdrawal)
                    }
                }
                // An alert rather than a sheet, and the only alert this
                // control raises: all three answers are one sentence, and one
                // of them needs a decision made on top of the sentence. A
                // sheet for that would be a screen whose whole content is a
                // line of text, which is what the refusal form already is and
                // is only tolerable there because it explains a rule.
                .alert(
                    publicationLiveness.map(Self.livenessTitle) ?? "",
                    isPresented: $publicationLiveness.isPresent(),
                    presenting: publicationLiveness
                ) { answer in
                    if answer == .takenDown {
                        // Destructive because it throws away the two record
                        // names a removal request quotes, which is the one
                        // thing here that cannot be undone from this screen.
                        Button("Reset", role: .destructive) {
                            CommunityPublicationCheck.forgetPublication(hike)
                        }
                        .accessibilityIdentifier("community-liveness-reset-button")
                        Button("Cancel", role: .cancel) {
                            // Dismissal is the whole action: the hike keeps
                            // reading published, which is what it read before.
                        }
                    } else {
                        Button("OK", role: .cancel) {
                            // Nothing to decide — these two answers are told,
                            // not acted on.
                        }
                    }
                } message: { answer in
                    Text(Self.livenessMessage(answer))
                }
        }
    }

    /// A button where there is one thing to do, a menu where there are two.
    ///
    /// Eligibility reaches only the *not shared* state. A hike that has
    /// already been sent is past the gate by definition, and the menu it gets
    /// is about the submission rather than about a new one — an import cannot
    /// be in either of those states, since ``CommunityImport`` writes no
    /// submission id.
    ///
    /// Inside *not shared* the question splits again, and the split is the
    /// eligibility's rather than this view's: a hike with somewhere for its
    /// photographs to go gets the contribution control, and one with nowhere
    /// gets the form that explains why. See this file's header.
    @ViewBuilder
    private func communityControl(
        _ appearance: CommunityShareButtonAppearance,
        _ publication: CommunityPublicationState,
        _ eligibility: CommunityPublishingEligibility,
        _ contribution: CommunityContributionState,
        _ transport: any CommunityTransporting
    ) -> some View {
        switch publication {
        case .notShared:
            if let target = eligibility.photoTarget {
                contributionControl(appearance, target, contribution)
            } else {
                Button { isSharingToCommunity = true } label: {
                    Self.shareButtonGlyph(appearance)
                }
                .buttonStyle(.plain)
            }
        case .awaitingReview:
            Button { isWithdrawingFromCommunity = true } label: {
                Self.shareButtonGlyph(appearance)
            }
            .buttonStyle(.plain)
        case .published:
            Menu {
                publishedMenuItems(contribution, transport)
            } label: {
                Self.shareButtonGlyph(appearance)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
        }
    }

    /// What a hike that is already live offers, which is no longer a second
    /// copy of itself.
    ///
    /// *Share Again* used to be the first item here, and it was the duplicate
    /// this whole gate exists to refuse — dressed as an amendment. A
    /// submission cannot be amended, by ``CommunitySchema``'s design, so
    /// sharing again made a **second** listing of the same walk and pointed
    /// this device at it: the original stayed live, stayed findable, and was
    /// now the copy the hiker could no longer see. The one thing a hiker
    /// actually comes back here to do — add the photographs they got off the
    /// camera after the walk went up — went to the wrong place entirely.
    ///
    /// So the item is the contribution: the pictures go onto the listing that
    /// already exists, which is the only shape this schema has for adding
    /// anything to a published hike. See
    /// ``CommunityPhotoTarget/published(listingID:title:)``.
    ///
    /// The three photo states are the same three ``contributionControl``
    /// draws, and the middle one is missing on purpose rather than by
    /// oversight: a set waiting for review must not be joined by a second set,
    /// because neither can be withdrawn from here and the reviewer would be
    /// looking at the same photographs twice. What that state offers instead
    /// is the way to ask for them back.
    ///
    /// An amended *route* has no item any more, and that is a real loss stated
    /// plainly: the walk that is live is the walk that was sent. Sending a
    /// corrected one is a takedown of the first followed by a fresh share,
    /// which is what the removal request is for and what it always had to be —
    /// what changed is that the app no longer offers a shortcut that quietly
    /// skips the takedown.
    ///
    /// That route only leads anywhere because of the third item. A takedown is
    /// something a reviewer does elsewhere, and nothing tells this device — so
    /// without *Check Whether It's Still Live* the hike would read published
    /// forever, aim its photographs at a listing that is gone, and refuse a
    /// re-recording of the same walk as a retread. The fresh share the
    /// paragraph above promises would be unreachable. See
    /// ``checkWhetherStillLive(_:)``, and ``Hike/communityListingID`` for why
    /// the ask is a tap rather than something this screen does on its own.
    @ViewBuilder
    private func publishedMenuItems(
        _ contribution: CommunityContributionState,
        _ transport: any CommunityTransporting
    ) -> some View {
        if let target = CommunityPhotoTarget.published(
            listingID: hike.communityListingID,
            title: hike.displayTitle
        ), contribution != .awaitingReview {
            Button(
                contribution == .published ? "Add More Photos" : "Add Photos to This Trail",
                systemImage: "photo.badge.plus"
            ) {
                contributionTarget = target
            }
            .accessibilityIdentifier("community-add-photos-button")
        }
        if contribution != .notShared {
            Button("Ask for Photo Removal", systemImage: "photo.badge.exclamationmark") {
                isWithdrawingPhotosFromCommunity = true
            }
            .accessibilityIdentifier("community-photo-withdraw-button")
        }
        Button("Check Whether It's Still Live", systemImage: "arrow.clockwise") {
            checkWhetherStillLive(transport)
        }
        .accessibilityIdentifier("community-liveness-button")
        Button("Ask for Removal", systemImage: "envelope", role: .destructive) {
            isWithdrawingFromCommunity = true
        }
        .accessibilityIdentifier("community-withdraw-button")
    }

    /// The same three-state shape, about the photographs rather than the
    /// route.
    ///
    /// The middle state is a button and not a dimmed glyph, for the reason the
    /// route's middle state stopped being one: *asking for them back* is an
    /// action, and it is the only one a set waiting in the queue has. What it
    /// still refuses to do is open the send form — a second tap must not be
    /// able to put a second copy of the same pictures on a stranger's trail.
    @ViewBuilder
    private func contributionControl(
        _ appearance: CommunityShareButtonAppearance,
        _ target: CommunityPhotoTarget,
        _ contribution: CommunityContributionState
    ) -> some View {
        switch contribution {
        case .notShared:
            Button { contributionTarget = target } label: {
                Self.shareButtonGlyph(appearance)
            }
            .buttonStyle(.plain)
        case .awaitingReview:
            Button { isWithdrawingPhotosFromCommunity = true } label: {
                Self.shareButtonGlyph(appearance)
            }
            .buttonStyle(.plain)
        case .published:
            Menu {
                Button("Add More Photos", systemImage: "photo.badge.plus") {
                    contributionTarget = target
                }
                Button("Ask for Removal", systemImage: "envelope", role: .destructive) {
                    isWithdrawingPhotosFromCommunity = true
                }
                .accessibilityIdentifier("community-photo-withdraw-button")
            } label: {
                Self.shareButtonGlyph(appearance)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
        }
    }

    private static func shareButtonGlyph(
        _ appearance: CommunityShareButtonAppearance
    ) -> some View {
        Image(systemName: appearance.symbol)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .minimumTapTarget()
    }

    /// Spends one request to ask whether this hike's listing is still there.
    ///
    /// The tap that the argument in ``Hike/communityListingID`` leaves room
    /// for: publication stays one-way on its own, and this is the hiker
    /// deciding the badge is worth a request. It exists because dropping
    /// *Share Again* made a stale *published* into a dead end rather than a
    /// cosmetic error — a hike whose listing is gone aims its photographs at
    /// nothing and is refused as a retread if the walk is recorded again.
    ///
    /// ``CommunityPublicationCheck/Liveness/notPublished`` says nothing,
    /// because it can only mean the hike stopped being published while the
    /// request was in flight — deleted, or re-shared from another device — and
    /// the menu that raised this has already been rebuilt around that.
    private func checkWhetherStillLive(_ transport: any CommunityTransporting) {
        Task {
            do {
                switch try await CommunityPublicationCheck.liveness(
                    of: hike,
                    transport: transport
                ) {
                case .live: publicationLiveness = .live
                case .takenDown: publicationLiveness = .takenDown
                case .notPublished: publicationLiveness = nil
                }
            } catch {
                publicationLiveness = .failed
            }
        }
    }

    /// Never *rejected*, for the reason the share button's label never is.
    private static func livenessTitle(_ answer: CommunityLivenessAnswer) -> String {
        switch answer {
        case .live: String(localized: "Still published")
        case .takenDown: String(localized: "No longer published")
        case .failed: String(localized: "Couldn't check")
        }
    }

    /// The taken-down message is the only one that asks for anything, and it
    /// says what *Reset* costs before it offers it: the removal request needs
    /// record names that this throws away, so a hiker who taps it cannot then
    /// ask for a hike back. It is safe to offer only because there is nothing
    /// left to ask back — that is what the answer above established.
    private static func livenessMessage(_ answer: CommunityLivenessAnswer) -> String {
        switch answer {
        case .live:
            String(
                localized: """
                This hike is still live for other hikers, so it's still \
                somewhere your photos can go.
                """
            )
        case .takenDown:
            String(
                localized: """
                This hike isn't in the community list any more. You can reset \
                it here, which forgets that it was ever sent and lets you \
                share a corrected walk — but it also forgets the details a \
                removal request needs, so only do it if you no longer want \
                this one back.
                """
            )
        case .failed:
            String(
                localized: """
                Couldn't reach the community list just now, so this hike still \
                reads the way it did. Try again when you're back online.
                """
            )
        }
    }
}

/// What a *still live?* tap came back with, as a screen has to say it.
///
/// ``CommunityPublicationCheck/Liveness`` with a failure added, rather than a
/// fourth case over there: the check throws because it was asked for, and what
/// a throw means to a hiker — *ask again later* — is a fact about this screen
/// and not about the question.
enum CommunityLivenessAnswer: Equatable, Sendable {
    /// The question could not be put at all.
    case failed
    /// A listing still points at this hike's submission.
    case live
    /// None does, and one did once. The only answer that offers an action.
    case takenDown
}
