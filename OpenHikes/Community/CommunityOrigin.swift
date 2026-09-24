//
//  CommunityOrigin.swift
//  OpenHikes
//
//  Where a hike in the community list came from, and the facts that exist
//  only for that kind of source.
//
//  A sum type rather than a `source` flag beside ``CommunityListing``'s
//  fields, because two of those fields are not merely *unused* for a curated
//  route — they are **unrepresentable** for it, and the empty string that
//  would stand in for each is a value the app already treats as meaningful.
//  ``CommunityBlockList/block(_:at:)`` refuses an empty author id and says
//  why: blocking on one would hide every *other* listing that was also
//  missing it. ``CloudKitCommunityTransport`` builds a `CKRecord.ID` straight
//  out of a submission id, so a placeholder there is a fetch against a record
//  name nobody chose.
//
//  So the compiler is what keeps them apart. A screen that wants an author to
//  block, a record to report or a submission to take down has to unwrap
//  ``CommunityOrigin/published(submissionID:authorID:)`` to get one, and there
//  is nothing to unwrap on a curated route. Every affordance that needs one is
//  therefore *absent* rather than inert — which is the whole point, because an
//  inert *Block This Hiker* naming a hiker who does not exist is a lie inside
//  a Guideline 1.2 affordance rather than a cosmetic bug.
//

import Foundation

/// Where a hike in the community list came from.
nonisolated enum CommunityOrigin: Hashable, Sendable {
    /// A waymarked route OpenStreetMap already had.
    ///
    /// Nobody published it and nobody owns it, which is why there is no author
    /// here to credit, block or report — and why the screen showing one
    /// credits OpenStreetMap's contributors instead. See ``CuratedTrailFacts``
    /// for what such a route carries in place of an author and photographs.
    ///
    /// - Parameters:
    ///   - relationID: The OSM relation's own id, which is what
    ///     ``CommunityIdentity`` builds this listing's stable identity from.
    ///   - facts: What OpenStreetMap says about the route besides its line.
    ///     Carried in the case rather than beside it, so the facts exist
    ///     exactly when there is a route for them to be about — a published
    ///     hike cannot be given a waymark by accident, and a curated one
    ///     cannot lose its own.
    case openStreetMap(relationID: Int64, facts: CuratedTrailFacts)

    /// A hike somebody published and a reviewer approved.
    ///
    /// - Parameters:
    ///   - submissionID: The `CommunityHikeSubmission` record name, which is
    ///     what the route and the photographs are fetched by.
    ///   - authorID: The creator CloudKit stamped on that submission — what a
    ///     block is keyed on, and never shown. See
    ///     ``CommunitySchema/Listing/authorID``.
    case published(submissionID: String, authorID: String)
}

nonisolated extension CommunityOrigin {
    /// Who may be blocked over a hike from this source, or `nil` when there is
    /// nobody.
    ///
    /// The `nil` is the answer rather than a missing one: a curated route has
    /// no author, so there is nothing to block and the menu item is not drawn.
    var blockableAuthorID: String? {
        switch self {
        case .published(_, let authorID): authorID
        case .openStreetMap: nil
        }
    }

    /// The submission behind a hike from this source, or `nil` when there is
    /// not one.
    ///
    /// Read by the two things that need a record name — the detail fetch and
    /// the report's body — and by nothing else. A curated route has neither,
    /// which is why both are gated on this rather than on a flag.
    var submissionID: String? {
        switch self {
        case .published(let submissionID, _): submissionID
        case .openStreetMap: nil
        }
    }

    /// Whether this came from OpenStreetMap rather than from a hiker.
    ///
    /// For the handful of places that need to *say* which kind of row this is
    /// — the badge, the credit line, the attribution — as distinct from the
    /// places above that need a value out of it.
    var isCurated: Bool {
        switch self {
        case .published: false
        case .openStreetMap: true
        }
    }

    /// The OSM relation behind this hike, or `nil` when a person published it.
    var relationID: Int64? {
        switch self {
        case .published: nil
        case .openStreetMap(let relationID, _): relationID
        }
    }

    /// What OpenStreetMap says about this route, or `nil` when a person
    /// published it.
    var curatedFacts: CuratedTrailFacts? {
        switch self {
        case .published: nil
        case .openStreetMap(_, let facts): facts
        }
    }
}

/// How a listing's identity is spelled, whichever source it came from.
///
/// One namespace because one column holds both: ``Hike/importedFromListingID``
/// is what the *Saved* badge and the import's duplicate check are keyed on,
/// and it cannot tell a CloudKit record name from anything else. So a curated
/// route's identity carries a scheme no CloudKit record name can.
nonisolated enum CommunityIdentity {
    /// What a curated route's identity begins with.
    ///
    /// A colon and a slash, neither of which appears in a UUID. CloudKit mints
    /// listing record names itself — `CKRecord(recordType:)` with no name —
    /// so nothing the server generates can collide with this.
    ///
    /// **"Cannot be generated" is not "cannot exist."** A record name can be
    /// typed by hand in the Console, which is how the first listings were made
    /// before there was a review screen. So the separation is *enforced* where
    /// listings enter the app rather than assumed here — see
    /// ``CommunityListing/init(record:)``, which refuses a record carrying
    /// this prefix for the same reason it refuses one with no author: a row
    /// that could impersonate another source is worse than a missing row.
    static let curatedPrefix = "osm:r/"

    /// The identity of the curated route published from `relationID`.
    static func curated(relationID: Int64) -> String {
        "\(curatedPrefix)\(relationID)"
    }

    /// The OSM relation `id` names, or `nil` when it names something else.
    ///
    /// Used to route a per-listing request back to the source that can answer
    /// it — see ``MergedCommunityTransport`` — so a curated id never reaches
    /// CloudKit and a record name never reaches Overpass.
    static func relationID(of id: String) -> Int64? {
        guard id.hasPrefix(curatedPrefix) else { return nil }
        return Int64(id.dropFirst(curatedPrefix.count))
    }

    /// Whether `id` names a curated route.
    static func isCurated(_ id: String) -> Bool {
        relationID(of: id) != nil
    }
}
