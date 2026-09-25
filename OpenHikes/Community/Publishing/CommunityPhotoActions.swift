//
//  CommunityPhotoActions.swift
//  OpenHikes
//
//  Report, Block and Take Down, about one photograph rather than about a hike.
//
//  ## Why these have to exist at all
//
//  Guideline 1.2's two halves are already built for a shared hike: reporting
//  (#248) and blocking (#249), both in ``CommunityHikeView``'s toolbar menu,
//  both keyed on the hike's author. A contributed photograph breaks the
//  assumption every one of those rests on — that a hike's content has one
//  author. It does not any more: the trail is one person's and the picture on
//  it is somebody else's, so blocking the hike's author hides nothing about
//  the photograph, and reporting the hike points a reviewer at the wrong two
//  records.
//
//  So the affordances follow the content. A photograph somebody contributed
//  gets its own Report, its own Block and — for a reviewer — its own Take
//  Down, and all three name the contribution's records rather than the hike's.
//  The hike's own menu is untouched and still means what it meant.
//
//  ## Why it is a view rather than three closures
//
//  Because the three actions need four things between them that the gallery
//  has no other use for — the block list, the transport, whether this account
//  reviews, and the listing the photograph sits on — and threading four
//  dependencies through ``CommunityPhotoViewer`` for a menu that is absent on
//  most photographs would put them on every page the viewer draws. A view
//  takes them where they are used.
//
//  It is also where `@Environment(\.dismiss)` belongs if it is ever needed:
//  that property invalidates the view declaring it whether or not its body
//  reads it, which is the reason ``ShowPhotoSpotButton`` is its own type on a
//  screen that re-decodes a photograph on every pass.
//
//  ## What a block does here, and what it deliberately does not
//
//  It hides that contributor's photographs, everywhere, for this hiker —
//  ``CommunityBlockList`` is keyed on the creator CloudKit stamps, and
//  ``CommunityTransporting/contributedPhotos(for:excluding:downloadingInto:)``
//  takes the set. What it does not do is pop the screen the way blocking a
//  hike's author does. Blocking there leaves the hiker looking at the whole of
//  what they just hid; here the hike is somebody else's and stays perfectly
//  visible, so the honest behaviour is to go back one screen to the trail and
//  let the reopened gallery come back without those pictures.
//
//  **Going back is not a refetch, and that is why both actions here are read
//  on the far side too.** The trail's detail was downloaded when it opened and
//  is not asked for again, so a block or a takedown decided in this gallery
//  would otherwise leave the pictures drawn in the strip behind it and the
//  gallery one tap from reopening on them. ``CommunityHikeView`` filters what
//  it draws against the block list and
//  ``CommunityReviewQueue/takenDownContributions`` for exactly this reason —
//  the exclusion the *request* takes cannot help a screen that is not going to
//  make one.
//

import OpenHikesShared
import SwiftUI

/// The menu a contributed photograph carries, and the sheets behind it.
struct CommunityPhotoActions: View {
    /// Who contributed the photograph on screen.
    let contribution: CommunityPhotoAttribution
    /// The hike it was contributed to, which the report names as context.
    let listing: CommunityListing
    /// The hiker's own block list.
    let blockList: CommunityBlockList
    /// Needed only by the takedown, which only a reviewer can perform.
    let transport: any CommunityTransporting
    /// The reviewer's own state: whether this account may take a contribution
    /// down, and where a takedown is recorded once the server has accepted
    /// one.
    ///
    /// A fact about the account rather than about this photograph — see
    /// ``CommunityReviewQueue/isReviewer``, and note that forging it buys
    /// nothing, since the server refuses the write.
    var review: CommunityReviewQueue?
    /// Leaves the gallery, because what it is showing has just been hidden or
    /// removed.
    let onLeave: () -> Void

    @State private var isReporting = false
    @State private var isConfirmingBlock = false
    @State private var isConfirmingTakeDown = false
    @State private var isTakingDown = false
    @State private var takeDownFailure: CommunityFailure?

    var body: some View {
        Menu {
            Button {
                isReporting = true
            } label: {
                Label("Report Photo", systemImage: "exclamationmark.bubble")
            }
            .accessibilityIdentifier("community-photo-report")

            Button(role: .destructive) {
                isConfirmingBlock = true
            } label: {
                Label(blockTitle, systemImage: "hand.raised")
            }
            .accessibilityIdentifier("community-photo-block")

            if review?.isReviewer ?? false {
                Button(role: .destructive) {
                    isConfirmingTakeDown = true
                } label: {
                    Label("Take These Photos Down", systemImage: "trash")
                }
                .accessibilityIdentifier("community-photo-take-down")
            }
        } label: {
            if isTakingDown {
                ProgressView()
            } else {
                Image(systemName: "ellipsis.circle")
            }
        }
        .disabled(isTakingDown)
        .accessibilityLabel("Photo actions")
        .accessibilityIdentifier("community-photo-actions")
        .sheet(isPresented: $isReporting) {
            CommunityReportSheet(listing: listing, contribution: contribution)
        }
        // Presented from here rather than from inside the menu's closure: a
        // `.confirmationDialog` attached within a `Menu` goes with the menu
        // when it dismisses, which is the moment the item is tapped. The same
        // lesson ``CommunityHikeView`` records.
        .confirmationDialog(
            blockPrompt,
            isPresented: $isConfirmingBlock,
            titleVisibility: .visible
        ) {
            Button("Block", role: .destructive) { block() }
                .accessibilityIdentifier("community-photo-block-confirm")
            Button("Cancel", role: .cancel) { /* the dialog closing is the whole action */ }
        } message: {
            Text("""
            Their photos stop appearing on any hike, on this device. You can undo \
            this in Settings. Blocking doesn't report them or take anything down.
            """)
        }
        .confirmationDialog(
            "Take these photos down?",
            isPresented: $isConfirmingTakeDown,
            titleVisibility: .visible
        ) {
            Button("Take Down", role: .destructive) { takeDown() }
                .accessibilityIdentifier("community-photo-take-down-confirm")
            Button("Cancel", role: .cancel) { /* the dialog closing is the whole action */ }
        } message: {
            Text("""
            They're removed for everybody and deleted for good. The hike itself \
            isn't touched.
            """)
        }
        .communityFailureAlert("Couldn't take them down", failure: $takeDownFailure)
    }
}

// MARK: - What the menu says

private extension CommunityPhotoActions {
    /// "Block Anna", or "Block This Hiker" when they contributed without a
    /// name.
    ///
    /// The name is a credit rather than an identity — the block is keyed on
    /// ``CommunityPhotoAttribution/authorID`` — but it is what the hiker
    /// recognises, and the fallback avoids an item reading "Block This Hiker"
    /// about nobody. The rule ``CommunityHikeView`` already applies to a hike's
    /// author.
    var blockTitle: String {
        contribution.credit.map { String(localized: "Block \($0)") }
            ?? String(localized: "Block This Hiker")
    }

    var blockPrompt: String {
        contribution.credit.map { String(localized: "Block \($0)?") }
            ?? String(localized: "Block this hiker?")
    }
}

// MARK: - Doing it

private extension CommunityPhotoActions {
    /// Hides this contributor, then leaves the gallery.
    ///
    /// The gallery is the one screen still showing what was just hidden, and
    /// everything behind it filters on read — the lists, and now the trail's
    /// own strip and pins. So going back is what makes the block visible
    /// rather than a refresh, which is just as well: nothing refetches.
    func block() {
        blockList.block(contribution.authorID, name: contribution.credit)
        onLeave()
    }

    /// Deletes the contribution and its submission, then leaves.
    ///
    /// A reviewer's action and gated by the server rather than by
    /// ``isReviewer``: a build that forced the item on gets a permission
    /// failure, which is reported here on the screen that asked — the rule
    /// ``CommunityReviewView`` states about a reviewer's actions, as against
    /// the queue's deliberate silence.
    func takeDown() {
        isTakingDown = true
        Task {
            do {
                try await transport.takeDownPhotos(
                    CommunityPhotoContribution(
                        id: contribution.contributionID,
                        photoSubmissionID: contribution.photoSubmissionID,
                        authorName: contribution.credit ?? "",
                        authorID: contribution.authorID,
                        publishedAt: .now,
                        photoPins: [],
                        photoFileURLs: []
                    )
                )
            } catch {
                isTakingDown = false
                takeDownFailure = CommunityFailure(error)
                HapticMoment.outcomeFailed.play()
                return
            }
            isTakingDown = false
            // Said here rather than left to the screen that follows: the
            // success of a take-down *is* this screen going away, and a screen
            // on its way out is no place to hang a confirmation.
            HapticMoment.outcomeSucceeded.play()
            // Before the screen goes, because the screen it goes *to* is the
            // one still drawing these photographs: the trail's detail was
            // downloaded when it opened and nothing fetches it again on the
            // way back. See ``CommunityReviewQueue/tookDown(contribution:)``.
            review?.tookDown(contribution: contribution.contributionID)
            onLeave()
        }
    }
}
