//
//  CommunityOriginTests.swift
//  OpenHikesTests
//
//  What keeps two sources' hikes apart while one column holds both of them.
//
//  ``Hike/importedFromListingID`` is a single string, and the *Saved* badge,
//  the import's duplicate check and the block list are all keyed on it. So a
//  curated route and a published listing have to be told apart by their
//  identity alone — there is nowhere else to look — which is the whole of what
//  ``CommunityIdentity`` is for, and why the shape it uses is one CloudKit
//  cannot mint.
//
//  The other half is ``CommunityOrigin``, and what is asserted about it here
//  is mostly the **absences**. A curated route has no author to block and no
//  record to report, and the argument for a sum type over two loose fields is
//  precisely that those affordances come out *absent* rather than inert: an
//  inert *Block This Hiker* naming a hiker who does not exist is a lie inside
//  a Guideline 1.2 affordance, which is worse than a missing menu item and far
//  harder to notice — nothing is drawn wrong, nothing throws, and the hiker
//  who tapped it believes they are no longer being shown that person's hikes.
//  A `nil` asserted here is what stands between the two.
//
//  The other thing these answers decide is *which service a request reaches*.
//  ``MergedCommunityTransport`` routes a per-listing call by asking
//  ``CommunityIdentity/relationID(of:)`` what the id names, so an id read one
//  way round sends a relation to CloudKit as a record name, and read the other
//  way sends a record name to Overpass as a number. Neither can be seen from
//  the outside except as a hike that will not open.
//
//  A `CKRecord` built here reaches nothing: it is an in-memory object until
//  something saves it, and nothing here does — the same line
//  `CommunityListingTextTests` draws, for the same reason.
//

import CloudKit
import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Community origin and identity")
struct CommunityOriginTests {
    /// One curated route and the pieces a published one is spelled from.
    ///
    /// Named `Sample` rather than `Fixture`, which this bundle already uses
    /// for the shared route and container fixtures. The literals live in here
    /// rather than at their call sites for the reason
    /// ``CommunityListing/stub(id:submissionID:title:authorName:authorID:distanceMeters:photoCount:latitude:longitude:)``
    /// keeps its dates in one: the linter reads a literal inside a call as a
    /// magic number and a named constant as a constant.
    private enum Sample {
        /// A relation id of the size OSM actually issues — seven digits — so
        /// the round trip below is exercised on a number that would not
        /// survive being squeezed into anything narrower than `Int64`.
        static let relationID: Int64 = 1_671_346
        static let submissionID = "submission-42"
        static let authorID = "_abc123"
        static let latitude = 47.63
        static let longitude = 12.86
        static let distanceMeters: Double = 8000
        /// Fixed moments, so two listings built in two tests compare equal.
        static let walkedInterval: TimeInterval = 1_750_000_000
        static let editedInterval: TimeInterval = 1_750_100_000
        static let walked = Date(timeIntervalSince1970: walkedInterval)
        static let editedAt = Date(timeIntervalSince1970: editedInterval)

        /// The tags of a waymarked route as they really arrive.
        ///
        /// `osmc:symbol` in its full five-component form — the first component
        /// is the route colour and the rest describes a painted shape — so the
        /// facts carried through the origin below are ones that went through
        /// the real parser rather than a hand-built value.
        static let tags = [
            "name": "Soleleitungsweg",
            "route": "hiking",
            "ref": "411",
            "osmc:symbol": "red:red:white_bar:411:black",
            "roundtrip": "no",
            "from": "Ramsau",
            "to": "Bad Reichenhall",
            "operator": "Alpenverein Berchtesgaden",
        ]

        /// A short line, because the listing pass carries none and the point
        /// here is only that whatever a trail has reaches its listing.
        static let route = [
            RouteCoordinate(latitude: latitude, longitude: longitude),
            RouteCoordinate(latitude: latitude + 0.01, longitude: longitude + 0.01),
            RouteCoordinate(latitude: latitude + 0.02, longitude: longitude + 0.015),
        ]

        static let trail = CuratedTrail(
            relationID: relationID,
            name: "Soleleitungsweg",
            tags: tags,
            box: CuratedTrailQuery.BoundingBox(
                south: latitude,
                west: longitude,
                north: latitude + 0.02,
                east: longitude + 0.015
            ),
            route: route
        )

        static var facts: CuratedTrailFacts { trail.facts }
    }

    /// A published listing's record, built the way `CommunityListingTextTests`
    /// builds one — with the record name spelled out, which is the field this
    /// suite is about.
    private static func record(recordName: String) -> CKRecord {
        let record = CKRecord(
            recordType: CommunitySchema.listingType,
            recordID: CKRecord.ID(recordName: recordName)
        )
        record[CommunitySchema.Listing.submission] = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: Sample.submissionID),
            action: .none
        )
        record[CommunitySchema.Listing.title] = "Thumsee Loop"
        record[CommunitySchema.Listing.authorName] = "Anna Kovacs"
        record[CommunitySchema.Listing.authorID] = Sample.authorID
        record[CommunitySchema.Listing.location] = CLLocation(
            latitude: Sample.latitude,
            longitude: Sample.longitude
        )
        return record
    }

    // MARK: - What each source can and cannot answer

    /// The two things a published hike has, and the two it does not, asserted
    /// together because the pair is the invariant rather than either half.
    /// *Block* and *Report* are drawn off the first two and the *On the Trail*
    /// section off the second two, so an origin that answered both sets would
    /// put a waymark and a signposted destination under a hiker's photographs.
    @Test("a published hike carries an author and a submission, and no relation")
    func publishedOriginCarriesWhatAHikerGave() {
        let origin = CommunityOrigin.published(
            submissionID: Sample.submissionID,
            authorID: Sample.authorID
        )

        #expect(origin.blockableAuthorID == Sample.authorID)
        #expect(origin.submissionID == Sample.submissionID)
        #expect(origin.relationID == nil)
        #expect(origin.curatedFacts == nil)
        #expect(!origin.isCurated)
    }

    /// The mirror image, and the one that earns the type. Both `nil`s are the
    /// answer rather than a missing answer: there is nobody to block over a
    /// route nobody published, and no record name to put in a takedown mail, so
    /// the screen draws neither affordance instead of drawing two that cannot
    /// do anything. A curated route that answered an author id — an empty
    /// string, say — would hand ``CommunityBlockList`` a key that matches every
    /// *other* listing whose author was also missing.
    @Test("a curated route carries a relation and its facts, and nobody to block")
    func curatedOriginCarriesNoAuthor() {
        let origin = CommunityOrigin.openStreetMap(
            relationID: Sample.relationID,
            facts: Sample.facts
        )

        #expect(origin.blockableAuthorID == nil)
        #expect(origin.submissionID == nil)
        #expect(origin.relationID == Sample.relationID)
        #expect(origin.curatedFacts == Sample.facts)
        #expect(origin.isCurated)
    }

    // MARK: - The one column that holds both

    /// The round trip is what routing depends on: a curated id that came back
    /// as some *other* number would fetch a different trail under this one's
    /// name, which is a failure nothing downstream can see — the row opens, the
    /// line draws, and it is the wrong walk.
    @Test("a curated identity round-trips through the relation it names")
    func curatedIdentityRoundTrips() {
        let id = CommunityIdentity.curated(relationID: Sample.relationID)

        #expect(id.hasPrefix(CommunityIdentity.curatedPrefix))
        #expect(CommunityIdentity.relationID(of: id) == Sample.relationID)
        #expect(CommunityIdentity.isCurated(id))
    }

    /// The other direction, which every published listing also goes through.
    /// A record name that answered `true` would send an ordinary hike's detail
    /// fetch to Overpass, where it is a relation id that does not parse.
    ///
    /// Asserted against a name CloudKit actually minted rather than a
    /// hand-typed one, because that is the claim being relied on: a minted
    /// record name is a UUID string, and a UUID has neither a colon nor a
    /// slash anywhere in it.
    @Test("a CloudKit record name names no relation")
    func recordNamesAreNotCurated() {
        let minted = CKRecord(recordType: CommunitySchema.listingType).recordID.recordName

        #expect(!CommunityIdentity.isCurated(minted))
        #expect(CommunityIdentity.relationID(of: minted) == nil)
        #expect(!CommunityIdentity.isCurated(UUID().uuidString))
        #expect(!CommunityIdentity.isCurated("listing-42"))
    }

    /// The prefix alone is not an identity, and neither is the prefix with
    /// something that is not a number after it. What is being read can be an id
    /// saved into ``Hike/importedFromListingID`` long before curated routes
    /// existed, or one a reviewer typed into the Console by hand — so the
    /// answer has to be "this names nothing" rather than a relation `0`, which
    /// is a real Overpass query for a relation nobody has.
    @Test("a prefixed id whose tail is not a number names nothing")
    func prefixedNonNumericTailIsRefused() {
        let prefix = CommunityIdentity.curatedPrefix

        #expect(CommunityIdentity.relationID(of: prefix) == nil)
        #expect(CommunityIdentity.relationID(of: "\(prefix)Soleleitungsweg") == nil)
        #expect(CommunityIdentity.relationID(of: "\(prefix)1671346x") == nil)
        #expect(!CommunityIdentity.isCurated(prefix))
    }

    // MARK: - The listing a curated route is drawn as

    /// The three things a curated route cannot have, asserted as the three
    /// values that say so rather than as placeholders that would read as
    /// content. An empty `authorName` is the one every existing consumer
    /// already branches on — ``CommunityHikeRow`` drops its "by …" clause on
    /// `isEmpty` — a `nil` `hikeDate` is why the screen does not head itself
    /// with *1 January 1*, and a zero `photoCount` is why the row draws no
    /// camera.
    @Test("a curated listing has no author, no date and no photographs")
    func curatedListingHasNothingAHikerWouldHaveGivenIt() {
        let listing = CommunityListing(curated: Sample.trail, editedAt: Sample.editedAt)

        #expect(listing.authorName.isEmpty)
        #expect(listing.hikeDate == nil)
        #expect(listing.photoCount == 0)
        #expect(listing.blockableAuthorID == nil)
        #expect(listing.submissionID == nil)
    }

    /// What it has instead. The id is the interesting one: it is what lands in
    /// ``Hike/importedFromListingID`` when this route is saved, so a listing
    /// built without the prefix would be a curated route the app afterwards
    /// believes is a CloudKit listing.
    ///
    /// `publishedAt` carries the relation's last-edit time because the merged
    /// list is ordered by it — without one, every curated row sinks below every
    /// published row and the feature is invisible on a busy area.
    @Test("a curated listing is identified by its relation and dated by its edit")
    func curatedListingCarriesItsIdentityAndFacts() {
        let listing = CommunityListing(curated: Sample.trail, editedAt: Sample.editedAt)

        #expect(listing.id == CommunityIdentity.curated(relationID: Sample.relationID))
        #expect(listing.id.hasPrefix(CommunityIdentity.curatedPrefix))
        #expect(listing.isCurated)
        #expect(listing.publishedAt == Sample.editedAt)
        #expect(listing.title == Sample.trail.name)
        #expect(listing.distanceMeters == Sample.trail.distanceMeters)
        // The facts ride inside the origin rather than beside it, so this is
        // also the assertion that a route cannot arrive on the list having lost
        // its waymark on the way.
        #expect(listing.curatedFacts?.waymark?.reference == "411")
        #expect(listing.curatedFacts?.waymark?.colour == WaymarkColour.red)
        #expect(listing.curatedFacts?.maintainer == "Alpenverein Berchtesgaden")
    }

    /// The compatibility initialiser is how the forty-odd existing call sites
    /// still spell a published listing, and the risk in keeping it is that it
    /// quietly builds something *other* than a published origin — at which
    /// point every one of those sites loses its author without a single one of
    /// them changing. So the two fields are read back through the origin they
    /// were folded into.
    @Test("the longhand initialiser still produces a published origin")
    func compatibilityInitialiserStaysPublished() {
        let listing = CommunityListing(
            id: "listing-42",
            submissionID: Sample.submissionID,
            title: "Thumsee Loop",
            authorName: "Anna Kovacs",
            authorID: Sample.authorID,
            hikeDate: Sample.walked,
            distanceMeters: Sample.distanceMeters,
            photoCount: 2,
            latitude: Sample.latitude,
            longitude: Sample.longitude,
            publishedAt: Sample.editedAt
        )

        #expect(listing.submissionID == Sample.submissionID)
        #expect(listing.blockableAuthorID == Sample.authorID)
        #expect(listing.hikeDate == Sample.walked)
        #expect(!listing.isCurated)
        #expect(listing.curatedFacts == nil)
    }

    // MARK: - The separation where listings enter the app

    /// "CloudKit cannot mint this shape" is not "this shape cannot exist". A
    /// record name can be typed by hand in the Console, which is how the first
    /// listings were made before there was a review screen — so the separation
    /// is enforced at the door rather than assumed. A record that got through
    /// would be a published listing wearing a curated id: the block list would
    /// key on it, ``MergedCommunityTransport`` would send its detail fetch to
    /// Overpass, and the *Saved* badge would light up on somebody else's hike.
    @Test("a record named like a curated route is refused")
    func recordImpersonatingACuratedRouteIsRefused() throws {
        let impersonating = Self.record(
            recordName: CommunityIdentity.curated(relationID: Sample.relationID)
        )

        #expect(CommunityListing(record: impersonating) == nil)

        // The control, because a refusal proves nothing on its own: the same
        // record under a name CloudKit could have minted is an ordinary
        // listing, so what was refused above is the name rather than something
        // this fixture forgot to fill in.
        let ordinary = try #require(CommunityListing(record: Self.record(recordName: "listing-42")))
        #expect(!ordinary.isCurated)
        #expect(ordinary.blockableAuthorID == Sample.authorID)
    }
}
