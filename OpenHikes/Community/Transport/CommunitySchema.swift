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
//  submission. It was small enough to be done by hand in the CloudKit Console,
//  which is what let review ship before any review tooling did; the app now
//  does it instead, from ``CommunityReviewView``, and the grant above is what
//  makes that safe rather than the absence of a method. See
//  ``CommunityTransporting`` for why leaving the method out never protected
//  anything.
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
//  The `reviewer` role does hold `WRITE` here, and that is what a delete
//  needs — see ``CommunityTransporting/decline(_:)`` and
//  ``CommunityTransporting/takeDown(_:)``. It is the narrowest grant that
//  makes declining possible at all, and declining has to be possible: nothing
//  enumerates this type, so a submission a reviewer turns down and leaves
//  behind can never be found by anybody again, and would be a stranger's
//  photographs and GPS trace held in a public database for good.
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
//  for a dozen assets. That argument was written when review was Console work
//  and it survives the app learning to publish: the copy would still have to
//  happen somewhere, and a reviewer's phone re-uploading a stranger's
//  photographs in order to approve them is worse than the record name being
//  the gate.
//
//  ## How a reviewer finds a submission, and why that needs a third type
//
//  The rule below — that ``submissionType`` carries no index at all — is what
//  keeps a world-readable pending upload from being enumerable. It binds
//  everybody. A CloudKit index belongs to a record *type*, not to a role, so
//  there is no such thing as an index only the reviewer can query: making the
//  queue visible to a reviewer that way would publish every unreviewed upload
//  to everybody. That is not a trade worth making, so the queue is somewhere
//  else.
//
//  ``noticeType`` is that somewhere else. One record per submission, carrying
//  a reference to it and nothing else, created by the app the moment an upload
//  succeeds. `_icloud` may create one; **only the `reviewer` role may read
//  one**, which is what lets this type be indexed without leaking anything: a
//  query returns the rows the caller may read, and for everybody but the
//  reviewer that is none of them.
//
//  Two things about its shape are deliberate:
//
//  - **It carries a reference and no copied fields.** A title or a distance
//    denormalised onto it would be text a client wrote, shown to a reviewer as
//    though it described the record they were about to approve — so the queue
//    reads the real values off each submission instead, with `desiredKeys`, the
//    way ``CommunityTransporting/outlines(for:)`` already reads a page of
//    outlines. Nothing on a notice can lie about what it points at.
//  - **The order is `___createTime`, not a field.** A client-supplied date
//    could be set to last year to jump the queue. The server stamps this one.
//
//  What a notice cannot do is make a submission *trustworthy*: anybody with an
//  Apple Account can create one pointing anywhere, so the queue is a list of
//  things to look at rather than a list of things that are real. The reviewer
//  fetches each submission before deciding, and a notice whose submission is
//  gone is dropped.
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
//  - `submission` — QUERYABLE, so an author can ask whether their own
//    submission has been published yet. See
//    ``CommunityTransporting/publication(of:)``.
//  - `___recordID` — QUERYABLE, which the Console adds by default.
//
//  `submission` is the one index here that is not needed for browsing, and is
//  worth a sentence on why it is safe. Querying it requires already knowing a
//  submission's record name, which only its author has — nothing enumerates
//  submissions, by the rule below — and what it returns is a listing, which is
//  `_world` read and already discoverable by location and by title. So it lets
//  an author find their own hike by a name they stored locally, and lets
//  nobody find anything they could not have found by searching for it. The
//  alternative, a status field on the submission for a reviewer to set, would
//  put a writable field on the record type whose unwritability is the whole
//  point of this schema.
//
//  `authorID` deliberately gets none. A block is applied on the device that
//  made it — see ``CommunityBlockList`` — so the field is read off rows that
//  have already arrived and is never a predicate. Indexing it would let
//  anybody enumerate one person's published hikes, which is a thing this
//  schema has no reason to offer.
//
//  ``noticeType`` needs `___recordID` QUERYABLE — without it the queue cannot
//  be listed at all — and `___createTime` SORTABLE, so the oldest submission
//  is reviewed first. Both are safe *here* and would not be safe one type
//  over, and the difference is the read grant rather than the index: this type
//  is readable only by the `reviewer` role, so a query run by anybody else
//  matches nothing. It is the one place in this schema where an index is
//  added rather than argued away, and the reason is that permission is doing
//  the work an absent index does elsewhere.
//
//  On ``submissionType``, **no index at all**, and that absence is a security
//  control rather than an omission. A fetch by record ID is not a query and
//  needs no index, which is the only way this type is ever read; without a
//  queryable field nobody can enumerate submissions, so a pending one cannot
//  be listed, searched or walked through even though `_world` may read one it
//  can name. Adding an index here — `___recordID` QUERYABLE included, which
//  the Console offers by default — would publish every unreviewed upload.
//
//  ``Submission/routeOutline`` does not change that. It is read the same way
//  everything on this type is read, by a fetch of record IDs taken off
//  published listings — the batch in
//  ``CommunityTransporting/outlines(for:)`` is one such fetch with several
//  IDs rather than a different kind of read — so it needs no index and must
//  not be given one.
//
//  ## The other pair: photographs offered to a hike that already exists
//
//  ``photoSubmissionType`` and ``contributionType`` are the same two-type
//  shape again, for the same reason, and everything argued above holds of them
//  word for word: a hiker may create a photo submission and never change one,
//  only the `reviewer` role may create the published record, and the queue is
//  the notice rather than an index on either.
//
//  Three things about them are genuinely different, and each one follows from
//  the trail already being public.
//
//  **The target is a string, not a reference.** ``PhotoSubmission/listing``
//  and ``Contribution/listing`` both hold a ``CommunityIdentity`` — a
//  ``listingType`` record name, or the `osm:r/<relation>` form a curated route
//  gets. A `CKRecord.Reference` could only ever express the first, and the
//  OpenStreetMap half is precisely the half with nothing in this database to
//  point at. It also means a contribution outlives its target being taken
//  down, which is a set of photographs nobody can reach rather than a dangling
//  reference — the same end state declining already produces.
//
//  **``contributionType`` needs two queryable fields, and both are
//  targets.** `listing` QUERYABLE, because opening a hike asks *which
//  contributions are about this one*. `photoSubmission` QUERYABLE, because a
//  contributor's own device asks *has mine been published yet* — the same
//  question ``Listing/submission``'s index answers about a hike, asked of the
//  other pair of types, and without it every contributed set reads as
//  *waiting for review* forever however many are live. See
//  ``CommunityTransporting/contribution(of:)``. Both are safe for the reason
//  ``Listing/submission``'s index is: running either needs a name that is
//  already public or that only its author holds, and what comes back is a
//  record that is `_world` read and reachable by anybody who opened the same
//  hike. `publishedAt` is SORTABLE so a hike's contributed photographs keep
//  their order between two people's screens. ``PhotoSubmission`` gets
//  **none**, like its sibling and for the identical reason: it is only ever
//  fetched by a record name that came off a published contribution.
//
//  **There is no count anywhere else.** A contribution does not touch the
//  listing it is about — the reviewer's role could write that record, and
//  deliberately does not. ``Listing/photoCount`` goes on meaning *the
//  photographs the hike's own author published*, so it cannot go stale behind
//  a contribution that was later taken down, and a curated route — which has
//  no record at all and never could have one — is not the odd one out. The
//  consequence is stated plainly because it is the cost of that choice:
//  contributed photographs are found by opening the hike and not by reading
//  its row.
//
//  ``noticeType`` carries both kinds, through a second reference field rather
//  than a second type. One query a launch is what the queue costs *everybody*
//  — almost none of whom is a reviewer — and a second type would have doubled
//  that to list a second kind of row in the same place. Exactly one of
//  ``Notice/submission`` and ``Notice/photoSubmission`` is set; a notice with
//  neither is a record nothing wrote and is dropped.
//
//  Nothing here contacts CloudKit, and nothing here is verified against a
//  live container. See *Schema and migration policy* for the standing rule
//  that a deployment fact is recorded in the instructions file rather than in
//  runtime code.
//

import Foundation
import OpenHikesData

/// Record type and field names for the public-database types: the two pairs
/// — a hike and its submission, a contributed photo set and its submission —
/// and the reviewer's notice that names whichever is waiting.
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
    /// One per submission, readable only by the `reviewer` role: the queue.
    ///
    /// See *How a reviewer finds a submission* in this file's header for why
    /// the queue cannot live on ``submissionType`` itself.
    static let noticeType = "CommunitySubmissionNotice"
    /// What a hiker uploads when the trail is already here and the
    /// photographs are not: written once, then read by record name only.
    ///
    /// Never *queried*, like ``submissionType`` and for the same reason — it
    /// carries no index at all. See *The other pair* in this file's header.
    static let photoSubmissionType = "CommunityPhotoSubmission"
    /// What a reviewer publishes from one of those. The only type a hike's
    /// contributed photographs are ever found through.
    static let contributionType = "CommunityPhotoContribution"

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
        /// The same line thinned to about a kilobyte of text, so the map can
        /// draw it before anybody opens the hike. See
        /// ``CommunityRouteOutline``.
        ///
        /// A *field* where ``route`` is an asset, and that is the whole reason
        /// it earns its place: a field can be asked for on its own.
        /// ``CommunityTransporting/outlines(for:)`` fetches this and nothing
        /// else for a whole page of listings in one request, which the asset
        /// cannot do — an asset is fetched as a file, and a page of them is
        /// the tens of megabytes ``CommunityListing`` exists to avoid.
        ///
        /// It needs **no index**, like everything else on this type and for
        /// the same reason: it is read by a fetch of record IDs that came off
        /// listings a reviewer published, never by a query. Nothing about it
        /// makes a submission enumerable.
        ///
        /// Absent on every hike shared before it existed, and on any whose
        /// route was too short to draw. A listing whose submission has no
        /// outline keeps its pin and draws no line; see
        /// ``CommunityBrowser/routeLines``.
        static let routeOutline = "routeOutline"
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

    /// Fields on ``noticeType``.
    ///
    /// Exactly one of the two is set. A notice with neither points at nothing
    /// and is dropped by ``CommunityTransporting/reviewQueue()``; a notice
    /// with both would be a record this app never writes, and the queue reads
    /// the hike first.
    enum Notice {
        /// The hike submission this notice is about.
        static let submission = "submission"
        /// The photo submission this notice is about, when it is a
        /// contribution rather than a hike.
        ///
        /// A second field rather than a second record type, so the queue stays
        /// one query — see *The other pair* in this file's header. It needs no
        /// index: the queue is listed by `___recordID` and sorted by
        /// `___createTime`, and this field is only ever read off a row that
        /// query already returned.
        static let photoSubmission = "photoSubmission"
    }

    /// Fields on ``photoSubmissionType``.
    ///
    /// No title, no description, no route and no distance. The trail already
    /// has all four, from whoever published it or from OpenStreetMap, and none
    /// of them is a contributor's to send — which is also why nothing here is
    /// editable by a reviewer except the photographs themselves.
    enum PhotoSubmission {
        /// The hike these belong to, as a ``CommunityIdentity``: a
        /// ``listingType`` record name, or `osm:r/<relation>`.
        ///
        /// A `String` rather than a reference, because half the trails a
        /// contribution can be aimed at have no record in this database. See
        /// *The other pair* in this file's header.
        static let listing = "listing"
        static let authorName = "authorName"
        /// The day the photographs were taken.
        static let takenOn = "takenOn"
        /// The photographs, in the order ``photoPins`` describes them.
        static let photos = "photos"
        /// Per-photo capture time and coordinate, JSON-encoded, in the same
        /// order as ``photos``. The same payload
        /// ``Submission/photoPins`` carries, decoded by the same code.
        static let photoPins = "photoPins"
        /// Where the photographs were taken, for the reviewer's map.
        static let location = "location"
    }

    /// Fields on ``contributionType``.
    ///
    /// Denormalised from the photo submission for the reason ``Listing``'s
    /// fields are: this is the type that gets queried, and a `CKQuery` filters
    /// on fields of the type being queried.
    enum Contribution {
        /// The hike these were published onto — QUERYABLE, and the only
        /// predicate this type ever serves. See this file's header.
        static let listing = "listing"
        /// The submission holding the assets — QUERYABLE, so a contributor
        /// can ask whether their own upload has been published yet. See this
        /// file's header, and ``Listing/submission``, which carries the
        /// identical index for the identical reason.
        static let photoSubmission = "photoSubmission"
        static let authorName = "authorName"
        /// The contributor, as CloudKit stamped them on the submission.
        ///
        /// Here for the reason ``Listing/authorID`` is there, and it is a
        /// sharper one: a contributed photograph is somebody *other* than the
        /// hike's author posting into the hike, so blocking the author cannot
        /// reach it and nothing else could. A contribution without one is
        /// dropped, exactly as a listing without one is.
        static let authorID = "authorID"
        static let photoCount = "photoCount"
        /// When the reviewer published it — SORTABLE, so a hike's contributed
        /// photographs are in the same order on everybody's screen.
        static let publishedAt = "publishedAt"
    }

    /// Fields on ``listingType``.
    ///
    /// Denormalised from the submission rather than read through the
    /// reference, and that is what makes the browse query possible at all: a
    /// `CKQuery` filters and sorts on fields of the type being queried, so a
    /// location that lived only on the submission could not be used to find
    /// anything.
    enum Listing {
        /// The submission this was published from.
        ///
        /// QUERYABLE — see this file's header. It is what makes publication
        /// observable to the author without making a reviewer's decision
        /// writable by anybody.
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
