//
//  CommunityShareButtonAppearance.swift
//  OpenHikes
//
//  What the community button on a hike's toolbar looks like and says, worked
//  out once.
//
//  A glyph, a spoken label and a spoken hint are three answers to one question
//  — where is this hike in the community, and what will a tap do about it —
//  and they used to be three functions walking the same precedence in
//  parallel. That precedence is not obvious enough to be safely written three
//  times: the route's answer outranks the photographs' wherever both apply,
//  the ineligible case is told apart from the *has somewhere to contribute*
//  case by ``CommunityPublishingEligibility/offersPhotographs``, and only the
//  first of the three outer states has a fourth branch under it, and an upload
//  the review queue was never told about outranks all of it. A change to any
//  of that had to land in three switches or the button would say one thing and
//  draw another.
//
//  So the walk happens once and produces all three together. Each state names
//  the whole appearance in one place, which is what makes a glyph that
//  disagrees with its label something a reader can see rather than something
//  they have to check.
//
//  **Says *waiting for review* and never *rejected*.** The absence of a
//  listing covers a reviewer who has not looked and one who declined, and this
//  app cannot tell those apart. See ``Hike/communityListingID``.
//
//  **An upload the queue never heard about outranks every other state.** A
//  hike, or a set of photographs, is two saves — the submission and then the
//  note that puts it in front of a reviewer — and the second can fail after
//  the first has landed; see ``CommunityQueueingFailure``. What the hiker holds
//  then is a submission no person will ever be shown, which *waiting for
//  review* would describe as the opposite of the truth. It is asked first
//  because it is the one state in which something is owed, and a button that
//  said *published* or *waiting* over a debt would hide the only way to clear
//  it. The photographs' side of it can stand beside a published hike, so it
//  can win over `person.2.fill`.
//
//  **A glyph per state, rather than a badge on one glyph**, which would be
//  unreadable at the size a toolbar draws this. The slashed one is the state
//  with nothing to offer at all: a hike that can be neither published nor
//  contributed to, which reads as *not shared* to every other part of the app
//  and is not the same thing. The photograph glyphs are a second journey
//  through the same three states and only their two ends are drawn
//  differently — *waiting for a person* is the same fact whichever was sent,
//  so it is the same `hourglass`. The unfinished upload is one glyph for both
//  for the same reason: *uploaded, and the queue has not heard* is one fact
//  whichever was sent, and the label and hint say which.
//

import Foundation

/// The community button's glyph and what VoiceOver says about it.
struct CommunityShareButtonAppearance {
    /// The SF Symbol the toolbar draws.
    let symbol: String
    /// Spoken in place of the glyph, which says nothing on its own.
    let label: String
    /// Spoken after the label, for the states where the glyph alone does not
    /// say what a tap will do. Empty where it does.
    let hint: String

    /// - Parameter unfinished: Which of the hike's uploads is on the server
    ///   without a review-queue entry, if either is — see
    ///   ``CommunityUploadKind/unfinished(of:)``. It is asked before anything
    ///   else.
    init(
        publication: CommunityPublicationState,
        eligibility: CommunityPublishingEligibility,
        contribution: CommunityContributionState,
        unfinished: CommunityUploadKind? = nil
    ) {
        if let unfinished {
            self = Self.uploadedNotQueued(unfinished)
            return
        }
        switch publication {
        case .notShared:
            self = Self.notShared(eligibility: eligibility, contribution: contribution)
        case .awaitingReview:
            self.init(
                symbol: "hourglass",
                label: String(localized: "Waiting for review"),
                hint: String(
                    localized: """
                    Sent. It appears for other hikers once a person has checked it. \
                    Opens a request to withdraw it.
                    """
                )
            )
        case .published:
            // The route's answer wins over the photographs': a hike that is
            // live and has pictures in the queue draws `person.2.fill`,
            // because *published* is the older and larger fact about it. Since
            // ``CommunityPhotoTarget/published(listingID:title:)`` a hike can
            // be in both conversations at once, which is why this precedence
            // is stated rather than assumed. What tells the two apart is the
            // hint, which names whichever is waiting.
            self.init(
                symbol: "person.2.fill",
                label: String(localized: "Published to the community"),
                hint: Self.publishedHint(contribution)
            )
        }
    }

    private init(symbol: String, label: String, hint: String) {
        self.symbol = symbol
        self.label = label
        self.hint = hint
    }

    /// An upload that is on the server and that no reviewer will be shown until
    /// the hiker finishes sending it.
    ///
    /// Worded for what is true rather than for what is reassuring: the upload
    /// *is* there, it has *not* been sent for review, and the hiker can finish
    /// it or take it back. Nothing here says it is waiting, because nobody is
    /// waiting on it.
    private static func uploadedNotQueued(_ kind: CommunityUploadKind) -> Self {
        switch kind {
        case .route:
            Self(
                symbol: "exclamationmark.icloud",
                label: String(localized: "Finish sending to the community"),
                hint: String(
                    localized: """
                    Uploaded, but not yet sent for review, so it can’t appear for \
                    other hikers. Finish sending it, or ask for it to be taken down.
                    """
                )
            )
        case .photos:
            Self(
                symbol: "exclamationmark.icloud",
                label: String(localized: "Finish sending your photos"),
                hint: String(
                    localized: """
                    Your photos are uploaded, but not yet sent for review, so they \
                    can’t appear on the trail. Finish sending them, or ask for them \
                    to be taken down.
                    """
                )
            )
        }
    }

    /// The first outer state, which is the one with four answers under it
    /// rather than one — more than the other two have between them.
    private static func notShared(
        eligibility: CommunityPublishingEligibility,
        contribution: CommunityContributionState
    ) -> Self {
        guard !eligibility.isEligible else {
            return Self(
                symbol: "person.2",
                label: String(localized: "Share with the community"),
                // The glyph and the label already say it, and a hint that
                // repeats the label is a second thing to listen to for no
                // second fact.
                hint: ""
            )
        }
        guard eligibility.offersPhotographs else {
            return Self(
                symbol: "person.2.slash",
                label: eligibility.reason?.shortLabel ?? String(localized: "Can’t be shared"),
                hint: String(localized: "Opens an explanation of why this hike can’t be shared.")
            )
        }
        return switch contribution {
        case .notShared:
            Self(
                symbol: "photo.badge.plus",
                label: String(localized: "Add your photos to this trail"),
                hint: String(
                    localized: """
                    This trail is already in the community list. Opens a form to add \
                    your photos to it.
                    """
                )
            )
        case .awaitingReview:
            Self(
                symbol: "hourglass",
                label: String(localized: "Photos waiting for review"),
                hint: String(
                    localized: """
                    Sent. They appear on the trail once a person has checked them. \
                    Opens a request to withdraw them.
                    """
                )
            )
        case .published:
            Self(
                symbol: "photo.badge.checkmark",
                label: String(localized: "Photos published to this trail"),
                hint: String(localized: "Add more photos, or ask for yours to be taken down.")
            )
        }
    }

    /// What a live hike's menu holds, which depends on where its photographs
    /// are rather than on the hike — the hike is published and stays that way.
    private static func publishedHint(_ contribution: CommunityContributionState) -> String {
        switch contribution {
        case .notShared:
            String(
                localized: """
                Live for other hikers. Add photos you’ve taken since, or ask \
                for the hike to be taken down.
                """
            )
        case .awaitingReview:
            String(
                localized: """
                Live, and the photos you added are waiting for a person to \
                check them. Opens a request to withdraw them, or the hike.
                """
            )
        case .published:
            String(localized: "Add more photos, or ask for them, or the hike, to be taken down.")
        }
    }
}
