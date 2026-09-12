//
//  CommunitySchema.swift
//  OpenHikes
//
//  The public-database record types, written down once.
//
//  This is a hand-written CloudKit schema and has nothing to do with the
//  mirrored one. `Hike` and `HikeWalk` reach CloudKit because SwiftData
//  mirrors them into the *private* database, where the storage is the
//  hiker's own iCloud quota; these two types live in the **public** database
//  of the same container, where the storage is the developer's. That
//  distinction is the whole reason this feature can carry photographs at all
//  — see *Settled decisions* in the repository instructions for why the
//  private database deliberately does not.
//
//  ## Why two record types rather than one with a status field
//
//  Every submission is reviewed by hand before anybody else can see it, and
//  the gate has to survive a modified client. CloudKit's permissions are
//  granted per *record type*, never per field or per record — so a single type
//  with a `moderationState` field could not express this: whoever may write a
//  submission may write whatever they like into their own state field.
//
//  So the submission and the publication are different types with different
//  permissions:
//
//  - ``submissionType`` — `_world` read, `_icloud` create, `_creator` read.
//    Anybody may *make* one and nobody but the reviewer may *change* one.
//  - ``listingType`` — `_world` read, and create and write granted to a custom
//    admin role and to nobody else. This is the only type the browse path
//    queries, so a hike is discoverable exactly when a human has published one
//    of these for it, and no client can forge one.
//
//  Publishing is therefore creating a ``listingType`` record that points at a
//  submission. It is deliberately small enough to be done by hand in the
//  CloudKit Console, which is what lets review ship before any review tooling
//  does.
//
//  ## Why nobody may write a submission, including its author
//
//  Two things follow from ``CloudKitCommunityTransport/detail(for:)`` fetching
//  the submission a listing names, and both are why `_creator` has read and
//  not write.
//
//  **A submission is write-once.** If its author kept write access, approval
//  would mean nothing: a modified client could replace the route, the
//  description or the photo assets of an already-approved submission, and the
//  listing — which points at the record rather than at a copy of its contents
//  — would go on serving the replacement to everybody who opened it, without a
//  second review. Protecting the listing only protects what a hike is *called*
//  unless the thing it names can no longer change. So there is no write
//  permission on this type outside the admin role, which also means a hiker
//  cannot withdraw or edit a submission from the app; sharing an amended hike
//  makes a new submission, and taking one down is a reviewer's delete.
//
//  **`_world` reads it.** Browsing needs no account — public reads never do —
//  and a signed-out hiker who can find a listing has to be able to open it.
//  A reference being readable does not make its target readable, so without
//  this the preview would fail at the fetch for exactly the hikers the
//  account-free flow is for.
//
//  What that costs is worth stating plainly: a submission nobody has reviewed
//  is readable by anybody who has its record name. It is not *discoverable* —
//  see the indexes below, which is the part that matters — but the gate on a
//  pending upload is an unguessable name rather than a permission. The
//  alternative was copying every approved route and photograph into a record
//  only the admin role can create, which cannot be done by hand in the Console
//  for a dozen assets and so would make review wait on tooling this does not
//  have yet.
//
//  ## Indexes this schema needs
//
//  Record types are created automatically by the first save in the
//  development environment, but **indexes are not** — a query against an
//  unindexed field fails at runtime with `invalidArguments`, and the message
//  names the field. On ``listingType`` the Console needs:
//
//  - `location` — QUERYABLE and SORTABLE. Both: the predicate filters on it
//    and the results are sorted by distance from the same point.
//  - `title` — SEARCHABLE, for the token match the typed query uses.
//  - `publishedAt` — SORTABLE, the fallback order when there is no location.
//  - `___recordID` — QUERYABLE, which the Console adds by default.
//
//  `authorID` deliberately gets none. A block is applied on the device that
//  made it — see ``CommunityBlockList`` — so the field is read off rows that
//  have already arrived and is never a predicate. Indexing it would let
//  anybody enumerate one person's published hikes, which is a thing this
//  schema has no reason to offer.
//
//  On ``submissionType``, **no index at all**, and that absence is a security
//  control rather than an omission. A fetch by record ID is not a query and
//  needs no index, which is the only way this type is ever read; without a
//  queryable field nobody can enumerate submissions, so a pending one cannot
//  be listed, searched or walked through even though `_world` may read one it
//  can name. Adding an index here — `___recordID` QUERYABLE included, which
//  the Console offers by default — would publish every unreviewed upload.
//
//  Nothing here contacts CloudKit, and nothing here is verified against a
//  live container. See *Schema and migration policy* for the standing rule
//  that a deployment fact is recorded in the instructions file rather than in
//  runtime code.
//

import Foundation

/// Record type and field names for the two public-database types.
///
/// Spelled out as constants for the same reason
/// ``CloudSyncCoordinator/containerIdentifier`` is: these are a storage
/// contract shared with a schema that already exists in a container, so a
/// rename here is a migration rather than a refactor. A promoted production
/// field cannot be deleted, renamed or retyped at all.
nonisolated enum CommunitySchema {
    /// What a hiker uploads: written once, then read by record name only.
    ///
    /// Never *queried* — by this app or by anything else, because the type
    /// carries no queryable index. See this file's header.
    static let submissionType = "CommunityHikeSubmission"
    /// What a reviewer publishes. The only type the browse path reads.
    static let listingType = "CommunityHike"

    /// Fields on ``submissionType``.
    enum Submission {
        static let title = "title"
        static let authorName = "authorName"
        static let trackDescription = "trackDescription"
        static let hikeDate = "hikeDate"
        static let distanceMeters = "distanceMeters"
        /// The route, JSON-encoded and gzip-free, carried as an asset.
        ///
        /// An asset rather than a field because a `CKRecord`'s fields have to
        /// add up to under a megabyte and a day's recording is several — the
        /// same reason ``Hike/route`` is `@Attribute(.externalStorage)`.
        static let route = "route"
        /// The photographs, in the order ``photoPins`` describes them.
        static let photos = "photos"
        /// Per-photo capture time and trail coordinate, JSON-encoded, in the
        /// same order as ``photos``.
        ///
        /// Separate from the assets rather than encoded into their filenames
        /// because an asset is bytes and nothing else: CloudKit does not carry
        /// a name, a type or any metadata alongside one.
        static let photoPins = "photoPins"
        /// Where the route starts, copied onto the listing at publication so
        /// the reviewer does not have to work it out.
        static let startLocation = "startLocation"
    }

    /// Fields on ``listingType``.
    ///
    /// Denormalised from the submission rather than read through the
    /// reference, and that is what makes the browse query possible at all: a
    /// `CKQuery` filters and sorts on fields of the type being queried, so a
    /// location that lived only on the submission could not be used to find
    /// anything.
    enum Listing {
        static let submission = "submission"
        static let title = "title"
        static let authorName = "authorName"
        static let hikeDate = "hikeDate"
        static let distanceMeters = "distanceMeters"
        static let photoCount = "photoCount"
        /// QUERYABLE and SORTABLE — see this file's header.
        static let location = "location"
        static let publishedAt = "publishedAt"
        /// The submission's creator, copied across at publication: the record
        /// name of the `CKUserIdentity` CloudKit stamped the upload with.
        ///
        /// Here rather than read through ``submission`` for the reason every
        /// other field on this type is denormalised — the browse query returns
        /// listings and nothing else, so an author that lived only on the
        /// submission would cost a fetch per row to filter on. ``Listing``
        /// exists to avoid exactly that.
        ///
        /// It is what a block is keyed on, and the reason a block is keyed on
        /// something other than ``authorName``: that name is free text the
        /// hiker types, so two people may choose the same one and one person
        /// may choose a different one on every submission. A list keyed on it
        /// would block a string rather than a person, and would fail open for
        /// anybody deliberately evading it. This is the identity CloudKit
        /// assigns, which the hiker cannot choose and a takedown already
        /// relies on.
        ///
        /// A `String` rather than a reference, because the hiker's own
        /// blocked list is stored on the device and a `CKRecord.Reference`
        /// does not belong in `UserDefaults` — see ``CommunityBlockList``.
        ///
        /// **The reviewer copies this in the Console alongside everything
        /// else**, from the submission's *Created By* field. A listing without
        /// it is dropped rather than shown; see
        /// ``CommunityListing/init(record:)`` for why an unblockable listing
        /// is worse than a missing one.
        static let authorID = "authorID"
    }
}
