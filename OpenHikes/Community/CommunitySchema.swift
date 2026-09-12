//
//  CommunitySchema.swift
//  OpenHikes
//
//  The public-database record types, written down once.
//
//  This is a hand-written CloudKit schema and has nothing to do with the
//  mirrored one. `Hike` and `HikeWalk` reach CloudKit because SwiftData
//  mirrors them into the *private* database, where the storage is the
//  walker's own iCloud quota; these two types live in the **public** database
//  of the same container, where the storage is the developer's. That
//  distinction is the whole reason this feature can carry photographs at all
//  — see *Settled decisions* in the repository instructions for why the
//  private database deliberately does not.
//
//  ## Why two record types rather than one with a status field
//
//  Every submission is reviewed by hand before anybody else can see it, and
//  the gate has to survive a modified client. CloudKit's permissions are
//  granted per *record type*, never per field or per record, and `create`
//  implies `read` — so a single type with a `moderationState` field could not
//  express this: whoever may create a submission may also read every other
//  pending one, and may write whatever they like into their own state field.
//
//  So the submission and the publication are different types with different
//  permissions:
//
//  - ``submissionType`` — `_world` nothing, `_icloud` create, `_creator`
//    read/write. A walker can submit, and can read back and withdraw their
//    own submission. Nobody browses these, including the app.
//  - ``listingType`` — `_world` read, and create granted to a custom admin
//    role and to nobody else. This is the only type the browse path queries,
//    so a hike is visible exactly when a human has published one of these for
//    it, and no client can forge one.
//
//  Publishing is therefore creating a ``listingType`` record that points at a
//  submission. It is deliberately small enough to be done by hand in the
//  CloudKit Console, which is what lets review ship before any review tooling
//  does.
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
//  - `___recordID` — QUERYABLE, which the Console adds by default and which a
//    reference lookup needs.
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
    /// What a walker uploads. Never queried by the app.
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
    }
}
