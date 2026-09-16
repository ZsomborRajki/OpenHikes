//
//  CommunityPublishingEligibility.swift
//  OpenHikes
//
//  Whether a hike is this hiker's to publish, and whether it is worth
//  publishing at all.
//
//  ``CommunityPublicationState`` answers a different question — where a hike is
//  on the trip from private to published — and answers it about hikes that are
//  *allowed* to make that trip. This is the gate in front of it.
//
//  Three rules, and the order matters because the first one that applies is
//  the one a hiker is told about. They are also three different kinds of
//  certainty, which is why they are three cases rather than a `Bool`:
//
//  1. **It is somebody else's.** ``Hike/importedFromListingID`` is set only by
//     ``CommunityImport``, so this is the one case where the app *knows* the
//     answer rather than asking the hiker to judge. The terms already say a
//     hiker may publish only what is theirs, and the share form repeats it as
//     advice; this is the case where advice was the wrong instrument.
//  2. **It retraces something already shared.** The same walk sent twice is
//     two listings of one trail, which is the shape a browsable list degrades
//     into first.
//  3. **It is too short to be a walk anyone is looking for.**
//
//  ## Why the first two are no longer refusals
//
//  Because what they actually establish is that the **route** is already in
//  the community list — and the photographs are not. A hiker who saved a trail
//  from OpenStreetMap, walked it and came back with twenty pictures was being
//  told to record the same walk again and publish a second copy of a line that
//  is already there; a hiker who published a trail last spring and walked it
//  again in autumn was told to ask for the first one to be taken down. Both
//  were the app refusing the only part of the upload nobody else had.
//
//  So the first two rules answer ``photographsOnly(_:because:)`` — the route
//  stays where it is, and the pictures go on the hike that already exists. See
//  ``CommunityPhotoTarget`` for what that hike is and how one string names
//  both kinds of it, and ``CommunityPhotoPublisher`` for what is then sent.
//
//  Only the third is still a plain refusal, and it stays one because there is
//  nothing to attach to: a short walk that retraces nothing is a walk with no
//  trail in the list behind it. The retread rule is the case that can be
//  either, and the deciding fact is whether the earlier hike has actually been
//  **published** — a submission still waiting for review is not a listing, and
//  photographs cannot be aimed at a hike nobody can open yet.
//
//  ## What this is deliberately not
//
//  It is not a quality bar, and it must not become one. Every submission is
//  read by a person before it is published, and that is where taste, accuracy
//  and whether a trail is worth walking are decided. What is decided here is
//  only what a program can be right about: provenance, duplication, and a
//  floor low enough that clearing it says nothing except that this was a walk.
//
//  It is also **not a rule about imported files.** A GPX from another provider
//  — a route somebody downloaded, walked, and put their own photographs on —
//  is exactly the kind of hike this feature exists to carry, and carries no
//  ``Hike/importedFromListingID``. Only a hike saved out of this app's own
//  community is refused, because only there is the original a listing that
//  already exists.
//

import Foundation
import SwiftData

/// Whether this hike may be offered to the community, and why not.
nonisolated enum CommunityPublishingEligibility: Equatable, Sendable {
    case eligible
    /// The trail is already in the list; the photographs are what is new.
    ///
    /// Carries both halves because a screen needs both: the **target** is
    /// where the pictures would go, and the **reason** is why the route is
    /// staying behind — which is still the sentence the hiker has to read, and
    /// still one of ``Reason``'s. An offer that did not explain itself would
    /// read as the app quietly deciding to send something smaller than what
    /// was asked for.
    case photographsOnly(CommunityPhotoTarget, because: Reason)
    case refused(Reason)

    /// Why a hike cannot be published, in the words the screen uses.
    ///
    /// Carries the specifics — the original author, the distance, the title it
    /// retraces — because a refusal that cannot say *which* hike or *how far*
    /// is one the hiker cannot act on.
    ///
    /// Cases are alphabetical because the linter asks for that. The order they
    /// are *applied* in is the file header's, and is decided by ``of(importedFromListingID:importedAuthorName:distanceMeters:)``
    /// and ``CommunityPublishingCheck/eligibility(of:in:)``.
    enum Reason: Equatable, Sendable {
        /// Substantially the same ground as a hike this hiker has already
        /// sent. `title` is that hike's, so the refusal can name it.
        case retreads(title: String)
        /// Saved from a route OpenStreetMap already had, rather than from
        /// somebody's upload.
        ///
        /// Its own case rather than ``savedFromTheCommunity(author:)`` with a
        /// `nil` author, because that one's whole argument is about a person —
        /// "publishing it again would send their route, their notes and their
        /// photographs under your name" — and there is no *their* here. What
        /// is true instead is that the trail is already public, and already
        /// in this list, which is a different sentence and a friendlier one.
        case savedFromOpenStreetMap
        /// Saved from another hiker's listing. `author` is
        /// ``Hike/importedAuthorName``, absent for a listing shared without a
        /// name.
        case savedFromTheCommunity(author: String?)
        /// Below ``minimumDistanceMeters``.
        case tooShort(meters: Double)
    }

    /// One kilometre.
    ///
    /// A floor rather than a judgement. It is set where it is because below it
    /// a track is almost never a walk somebody went looking for — a lap of a
    /// car park, a recording left running between the car and the trailhead,
    /// a test of the record button — and because every number above it starts
    /// excluding real short walks: a gorge path, a summit scramble from a high
    /// car park, a town circuit somebody's grandmother can manage. The
    /// reviewer decides whether a walk is worth publishing; this decides only
    /// whether it is a walk.
    static let minimumDistanceMeters: Double = 1000

    /// The cheap half: what can be answered from this hike alone.
    ///
    /// Separate from the retread check because that one needs every hike this
    /// hiker has already sent and a pass over their routes, which is a
    /// question for a screen that has opened rather than for a toolbar glyph
    /// being laid out.
    ///
    /// The distance floor is checked **after** the provenance rule and
    /// therefore never applies to a saved trail, which is not an oversight in
    /// the ordering: the floor asks *is this a walk worth listing*, and a
    /// contribution is not listing a walk. Half a mile up a gorge on a trail
    /// somebody else published can still come back with the photograph that
    /// trail was missing.
    ///
    /// - Parameter title: What the hiker's own copy of the hike is called,
    ///   which is what a contribution names its target by. Only read on the
    ///   saved-trail path; see ``CommunityPhotoTarget/title``.
    static func of(
        importedFromListingID: String?,
        importedAuthorName: String?,
        distanceMeters: Double,
        title: String = ""
    ) -> Self {
        if let importedFromListingID {
            // A curated route is imported with no author name — see
            // ``CommunityImport/importHike(_:into:store:libraryWriter:saveDate:alreadyImported:save:)``
            // — but the id is what actually settles it, because a hiker *can*
            // publish without typing a name and that hike still has an author.
            let saved: Reason = CommunityIdentity.isCurated(importedFromListingID)
                ? .savedFromOpenStreetMap
                : .savedFromTheCommunity(author: importedAuthorName)
            let target = CommunityPhotoTarget(
                listingID: importedFromListingID,
                title: title,
                authorName: saved.creditedAuthor
            )
            return .photographsOnly(target, because: saved)
        }
        if distanceMeters < minimumDistanceMeters {
            return .refused(.tooShort(meters: distanceMeters))
        }
        return .eligible
    }

    var isEligible: Bool { self == .eligible }

    /// Why the route is not going, whether that ends in a refusal or in an
    /// offer to send the photographs instead.
    ///
    /// One property for both cases on purpose: every screen that explains a
    /// decision needs the same sentence, and the *shape* of the decision is
    /// read off ``photoTarget`` beside it. Splitting them would have made
    /// every caller ask twice to say one thing.
    var reason: Reason? {
        switch self {
        case .eligible: nil
        case .photographsOnly(_, let reason): reason
        case .refused(let reason): reason
        }
    }

    /// The hike the photographs would go on, or `nil` when there is not one.
    var photoTarget: CommunityPhotoTarget? {
        guard case .photographsOnly(let target, _) = self else { return nil }
        return target
    }

    /// Whether the photographs can go even though the route cannot.
    var offersPhotographs: Bool { photoTarget != nil }
}

// MARK: - What the screen says

nonisolated extension CommunityPublishingEligibility.Reason {
    /// The headline, which is the part a hiker reads first and often only.
    ///
    /// Three of these used to open with what could not happen. They open with
    /// what is already true instead, because that is the fact the offer
    /// underneath them rests on: the trail is here, and it is the pictures
    /// that are missing.
    var title: String {
        switch self {
        case .savedFromTheCommunity: "This trail is already shared"
        case .savedFromOpenStreetMap: "This trail is already public"
        case .tooShort: "This hike is too short to share"
        case .retreads: "You've already shared this trail"
        }
    }

    /// Who published the trail these photographs would join, or `nil` when
    /// there is nobody to name.
    ///
    /// `nil` for OpenStreetMap, which nobody published, and `nil` for a hike
    /// the hiker published themselves — naming them back to themselves would
    /// read as a stranger. See ``CommunityPhotoTarget/authorName``.
    var creditedAuthor: String? {
        guard case .savedFromTheCommunity(let author) = self else { return nil }
        let trimmed = author?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// What happened and what to do instead, in that order.
    ///
    /// Every one of these names the thing the hiker can still do, because a
    /// refusal with no next step reads as the feature being broken. Saving
    /// somebody else's hike, walking a short loop and walking a trail twice
    /// are all perfectly good things to have done; none of them is a thing to
    /// publish.
    ///
    /// For three of the four, the thing they can still do is now the button
    /// underneath — so the sentence stops at what is true about the route and
    /// hands the next step to the control rather than describing a different
    /// walk they would have to go and do. What it must not do is *promise*
    /// the photographs go: a hike with no pictures on it takes the same path
    /// here and is told so by the form. See ``CommunityPhotoShareSheet``.
    ///
    /// The `locale` parameter is a test seam, as it is on ``HikeFormat/speed(_:locale:)``
    /// and ``HikeFormat/elevation(_:locale:)`` and for the same reason: the
    /// distances below are `usage: .road` and therefore regional, so a suite
    /// that could only ask about the simulator's own region would assert
    /// whatever the machine happened to be set to. This one did — it pinned
    /// the floor as "1 km", which is what a metric machine renders and what a
    /// US runner does not.
    func explanation(locale: Locale = .autoupdatingCurrent) -> String {
        switch self {
        case .savedFromTheCommunity(let author):
            let who = author.map { "\($0) shared it" } ?? "Another hiker shared it"
            return """
            \(who), and publishing it again would send their route and their notes \
            under your name. Your photographs are a different matter — they're yours, \
            and they can go on the trail that's already here.
            """
        case .tooShort(let meters):
            // `usage: .road`, which is what every other distance in the app
            // uses and therefore what the hiker just read on the stat grid
            // above. A floor quoted in a different unit from the figure it is
            // being compared against is a refusal nobody can check.
            let floor = Self.road(CommunityPublishingEligibility.minimumDistanceMeters, locale)
            let walked = Self.road(meters, locale)
            return """
            Community hikes start at \(floor); this one is \(walked). Short walks stay \
            in your own list, where they're still yours to keep, export and sync.
            """
        case .savedFromOpenStreetMap:
            return """
            You saved this from OpenStreetMap, where anybody can already find it — \
            publishing a copy would put the same trail in this list twice. What \
            OpenStreetMap hasn't got is a single photograph of it, and yours can go \
            on the trail that's already here.
            """
        case .retreads(let title):
            // The one reason that reaches both cases — an earlier hike that
            // is published is a target, and one still waiting for review is
            // not — so this says what is true of the route either way and
            // leaves the offer to the control under it. Promising the
            // photographs here would be a promise the waiting-for-review half
            // cannot keep.
            return """
            \(title) covers the same ground, and two listings for one trail make it \
            harder for anyone to find either. This walk stays in your own list, where \
            it's still yours to keep, export and sync.
            """
        }
    }

    private static func road(_ meters: Double, _ locale: Locale) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(
                .measurement(width: .abbreviated, usage: .road).locale(locale)
            )
    }

    /// Read out after the glyph on the hike's own screen, where there is no
    /// room for the sentences above.
    ///
    /// Still about the *route*, in every case. What a tap will actually do is
    /// on the button's own label and hint — see
    /// ``HikeDetailView/communityShareButton`` — because the same reason can
    /// end in an offer or in a refusal and this string cannot tell which.
    var shortLabel: String {
        switch self {
        case .savedFromTheCommunity: "Saved from the community"
        case .savedFromOpenStreetMap: "Saved from OpenStreetMap"
        case .tooShort: "Too short to share"
        case .retreads: "Already shared"
        }
    }
}

// MARK: - Asking it of a hike

/// Works out a hike's eligibility, including the half that needs the rest of
/// the library.
///
/// Separate from the rules themselves for the reason ``CommunityPublicationCheck``
/// is separate from ``CommunityPublicationState``: the rules are a pure
/// function a suite can exercise without a `@Model` or a container, and this is
/// the part that has to go and look.
@MainActor
enum CommunityPublishingCheck {
    /// Cheap first, and then only if it has to.
    ///
    /// The retread check reads every hike this hiker has already sent and
    /// walks their routes, so it is not asked of a hike that is already
    /// refused for a reason needing no fetch at all. Ordering the rules by
    /// cost is also ordering them by certainty, which is the order a hiker
    /// should be told them in.
    ///
    /// One already-shared hike, as much of it as the comparison and the offer
    /// need.
    ///
    /// A named type rather than the labelled tuple this used to be, because it
    /// grew a third member whose *absence is meaningful*: a hike with a
    /// submission and no listing is one a reviewer has not reached, and
    /// photographs cannot be aimed at a hike nobody can open. A tuple carrying
    /// an optional third slot reads as an afterthought; this reads as the
    /// question it is.
    struct SharedHike: Sendable {
        var title: String
        /// The published listing, or `nil` while it is still waiting for
        /// review — see ``Hike/communityListingID``, which is careful about
        /// the same distinction.
        var listingID: String?
        var route: [RouteCoordinate]
    }

    /// - Parameter context: Where the already-shared hikes are.
    static func eligibility(
        of hike: Hike,
        in context: ModelContext
    ) async -> CommunityPublishingEligibility {
        let cheap = CommunityPublishingEligibility.of(
            importedFromListingID: hike.importedFromListingID,
            importedAuthorName: hike.importedAuthorName,
            distanceMeters: hike.distanceMeters,
            title: hike.displayTitle
        )
        guard cheap.isEligible else { return cheap }

        let route = hike.route
        let others = alreadyShared(in: context, excluding: hike)
        guard !others.isEmpty else { return .eligible }

        guard let retread = await firstRetread(of: route, among: others) else {
            return .eligible
        }
        let reason = CommunityPublishingEligibility.Reason.retreads(title: retread.title)
        // Published, so there is a hike on other people's screens for these
        // photographs to land on. A submission still waiting for review is not
        // one — nobody can open it, a contribution aimed at it would be
        // invisible for as long as it stayed unpublished, and if it is
        // declined it would be invisible for good.
        guard let listingID = retread.listingID else { return .refused(reason) }
        return .photographsOnly(
            // The *earlier* hike's title, because that is the trail the
            // pictures are joining and the name the hiker will recognise on
            // the community list. No author: it is their own hike, and naming
            // them back to themselves would read as a stranger.
            CommunityPhotoTarget(listingID: listingID, title: retread.title, authorName: nil),
            because: reason
        )
    }

    /// Every hike this hiker has sent, as values rather than as models.
    ///
    /// Read on the main actor because SwiftData is, and handed on as
    /// `Sendable` values so the comparison itself can leave it — the same
    /// shape ``GPXExport/Track/init(hike:)`` takes, and for the same reason.
    ///
    /// A hike is a candidate if it carries a submission id, which covers both
    /// *awaiting review* and *published*: a submission a reviewer has not
    /// reached yet is still a listing this trail is about to have. Which of
    /// the two it is decides what a retread can *do*, not whether it is one —
    /// see ``SharedHike/listingID``.
    static func alreadyShared(
        in context: ModelContext,
        excluding hike: Hike
    ) -> [SharedHike] {
        let descriptor = FetchDescriptor<Hike>(
            predicate: #Predicate { $0.communitySubmissionID != nil }
        )
        let shared = (try? context.fetch(descriptor)) ?? []
        return shared
            .filter { $0.persistentModelID != hike.persistentModelID }
            .map { other in
                SharedHike(
                    title: other.displayTitle,
                    listingID: other.communityListingID,
                    route: other.route
                )
            }
    }

    /// The first already-shared hike this route retraces.
    ///
    /// `@concurrent` for the reason ``CommunityPublisher/sendablePhotoCount(of:store:)``
    /// is: this runs because a sheet is opening, and a pass over several
    /// routes is not work the main actor should be doing while it draws.
    @concurrent
    static func firstRetread(
        of route: [RouteCoordinate],
        among others: [SharedHike]
    ) async -> SharedHike? {
        others.first { CommunityRouteOverlap.isDuplicate(route, of: $0.route) }
    }
}
