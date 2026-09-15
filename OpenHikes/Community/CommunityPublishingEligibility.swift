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
    static func of(
        importedFromListingID: String?,
        importedAuthorName: String?,
        distanceMeters: Double
    ) -> Self {
        if let importedFromListingID {
            // A curated route is imported with no author name — see
            // ``CommunityImport/importHike(_:into:store:libraryWriter:saveDate:save:)``
            // — but the id is what actually settles it, because a hiker *can*
            // publish without typing a name and that hike still has an author.
            return .refused(
                CommunityIdentity.isCurated(importedFromListingID)
                    ? .savedFromOpenStreetMap
                    : .savedFromTheCommunity(author: importedAuthorName)
            )
        }
        if distanceMeters < minimumDistanceMeters {
            return .refused(.tooShort(meters: distanceMeters))
        }
        return .eligible
    }

    var isEligible: Bool { self == .eligible }

    var reason: Reason? {
        guard case .refused(let reason) = self else { return nil }
        return reason
    }
}

// MARK: - What the screen says

nonisolated extension CommunityPublishingEligibility.Reason {
    /// The headline, which is the part a hiker reads first and often only.
    var title: String {
        switch self {
        case .savedFromTheCommunity: "This hike isn't yours to share"
        case .savedFromOpenStreetMap: "This trail is already public"
        case .tooShort: "This walk is too short to share"
        case .retreads: "You've already shared this trail"
        }
    }

    /// What happened and what to do instead, in that order.
    ///
    /// Every one of these names the thing the hiker can still do, because a
    /// refusal with no next step reads as the feature being broken. Saving
    /// somebody else's hike, walking a short loop and walking a trail twice
    /// are all perfectly good things to have done; none of them is a thing to
    /// publish.
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
            \(who), and publishing it again would send their route, their notes and \
            their photographs under your name. If you walk this trail yourself, record \
            it and share that — your walk is yours.
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
            publishing a copy would put the same trail in this list twice. If you walk \
            it yourself, record that walk and share it: your route, your photographs \
            and your notes are yours to publish.
            """
        case .retreads(let title):
            return """
            \(title) covers the same ground, and two listings for one trail make it \
            harder for anyone to find either. If this walk is the better record of it, \
            ask for the earlier one to be removed first.
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
    /// - Parameter context: Where the already-shared hikes are.
    static func eligibility(
        of hike: Hike,
        in context: ModelContext
    ) async -> CommunityPublishingEligibility {
        let cheap = CommunityPublishingEligibility.of(
            importedFromListingID: hike.importedFromListingID,
            importedAuthorName: hike.importedAuthorName,
            distanceMeters: hike.distanceMeters
        )
        guard cheap.isEligible else { return cheap }

        let route = hike.route
        let others = alreadyShared(in: context, excluding: hike)
        guard !others.isEmpty else { return .eligible }

        if let retread = await firstRetread(of: route, among: others) {
            return .refused(.retreads(title: retread))
        }
        return .eligible
    }

    /// Every hike this hiker has sent, as values rather than as models.
    ///
    /// Read on the main actor because SwiftData is, and handed on as
    /// `Sendable` pairs so the comparison itself can leave it — the same shape
    /// ``GPXExport/Track/init(hike:)`` takes, and for the same reason.
    ///
    /// A hike is a candidate if it carries a submission id, which covers both
    /// *awaiting review* and *published*: a submission a reviewer has not
    /// reached yet is still a listing this trail is about to have.
    static func alreadyShared(
        in context: ModelContext,
        excluding hike: Hike
    ) -> [(title: String, route: [RouteCoordinate])] {
        let descriptor = FetchDescriptor<Hike>(
            predicate: #Predicate { $0.communitySubmissionID != nil }
        )
        let shared = (try? context.fetch(descriptor)) ?? []
        return shared
            .filter { $0.persistentModelID != hike.persistentModelID }
            .map { (title: $0.displayTitle, route: $0.route) }
    }

    /// The title of the first already-shared hike this route retraces.
    ///
    /// `@concurrent` for the reason ``CommunityPublisher/sendablePhotoCount(of:store:)``
    /// is: this runs because a sheet is opening, and a pass over several
    /// routes is not work the main actor should be doing while it draws.
    @concurrent
    static func firstRetread(
        of route: [RouteCoordinate],
        among others: [(title: String, route: [RouteCoordinate])]
    ) async -> String? {
        others.first { CommunityRouteOverlap.isDuplicate(route, of: $0.route) }?.title
    }
}
