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
//  - *published* has two — share again, or ask for removal — and is a `Menu`,
//    which is the shape for a control that genuinely offers a choice. The
//    warning about a second copy is still the share form's own business.
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
            communityControl(publication)
                .accessibilityLabel(Self.shareButtonLabel(publication))
                // What a tap will do is invisible in a toolbar glyph, so the
                // hint is the only place it can be explained.
                .accessibilityHint(Self.shareButtonHint(publication))
                .accessibilityIdentifier("community-share-button")
                .disabled(hike.pointCount < 2)
                // Asks once per appearance, and only for a hike that has been
                // sent and not yet seen live — see
                // ``CommunityPublicationCheck``. Here rather than on the detail
                // view's body because this control is the only thing that reads
                // the answer.
                .task(id: hike.id) {
                    await CommunityPublicationCheck.refresh(hike, transport: transport)
                }
                .sheet(isPresented: $isSharingToCommunity) {
                    CommunityShareSheet(hike: hike, transport: transport)
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
        }
    }

    /// A button where there is one thing to do, a menu where there are two.
    @ViewBuilder
    private func communityControl(_ publication: CommunityPublicationState) -> some View {
        switch publication {
        case .notShared:
            Button { isSharingToCommunity = true } label: {
                Self.shareButtonGlyph(publication)
            }
            .buttonStyle(.plain)
        case .awaitingReview:
            Button { isWithdrawingFromCommunity = true } label: {
                Self.shareButtonGlyph(publication)
            }
            .buttonStyle(.plain)
        case .published:
            Menu {
                Button("Share Again", systemImage: "person.2.badge.plus") {
                    isSharingToCommunity = true
                }
                Button("Ask for Removal", systemImage: "envelope", role: .destructive) {
                    isWithdrawingFromCommunity = true
                }
                .accessibilityIdentifier("community-withdraw-button")
            } label: {
                Self.shareButtonGlyph(publication)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
        }
    }

    private static func shareButtonGlyph(_ publication: CommunityPublicationState) -> some View {
        Image(systemName: shareButtonSymbol(publication))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .minimumTapTarget()
    }

    /// Three glyphs for three states, because a badge on one glyph would be
    /// unreadable at the size a toolbar draws this.
    private static func shareButtonSymbol(_ publication: CommunityPublicationState) -> String {
        switch publication {
        case .notShared: "person.2"
        case .awaitingReview: "hourglass"
        case .published: "person.2.fill"
        }
    }

    /// Says *waiting for review* and never *rejected*: the absence of a
    /// listing covers a reviewer who has not looked and one who declined, and
    /// this app cannot tell those apart. See ``Hike/communityListingID``.
    private static func shareButtonLabel(_ publication: CommunityPublicationState) -> String {
        switch publication {
        case .notShared: "Share with the community"
        case .awaitingReview: "Waiting for review"
        case .published: "Published to the community"
        }
    }

    /// Spoken after the button, for the two states where the glyph alone does
    /// not say what a tap will do.
    private static func shareButtonHint(_ publication: CommunityPublicationState) -> String {
        switch publication {
        case .notShared:
            ""
        case .awaitingReview:
            "Sent. It appears for other hikers once a person has checked it."
                + " Opens a request to withdraw it."
        case .published:
            "Share it again, or ask for it to be taken down."
        }
    }
}
