//
//  CommunityPayload.swift
//  OpenHikes
//
//  The `Sendable` values that cross between the store, the transport and the
//  screens — and the JSON the two asset fields actually contain.
//
//  Nothing here knows about CloudKit and nothing here knows about SwiftData.
//  That is the point: a `Hike` is a `@Model` and cannot leave the main actor,
//  a `CKRecord` is a non-`Sendable` reference type that must not reach a
//  SwiftUI body, and the upload is a long piece of off-main work in between.
//  These are what travels.
//

import CoreLocation
import Foundation
import OpenHikesData

/// One photograph's place in a shared hike.
///
/// Kept apart from the image bytes because CloudKit assets carry nothing but
/// bytes — no name, no type, no metadata — so the ordering and the pins have
/// to be stated somewhere the assets can be matched against by index.
nonisolated struct CommunityPhotoPin: Codable, Hashable, Sendable {
    var capturedAt: Date
    var latitude: Double?
    var longitude: Double?
    /// The shared hike's place this is a photograph of — a
    /// ``CommunityPlace/id`` — or `nil`. Always `nil` on a contribution to
    /// somebody else's trail, whose places are not the contributor's to name.
    var placeID: UUID?

    init(capturedAt: Date, coordinate: CLLocationCoordinate2D?, placeID: UUID? = nil) {
        self.capturedAt = capturedAt
        latitude = coordinate?.latitude
        longitude = coordinate?.longitude
        self.placeID = placeID
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// One photograph a reviewer kept, on its way back onto the submission.
///
/// The pin and the file together, because the two are only meaningful as a
/// pair: ``CommunitySchema/Submission/photos`` and
/// ``CommunitySchema/Submission/photoPins`` describe each other by index, so
/// rewriting one of them without the other is how a photograph ends up
/// carrying another photograph's coordinate. Removing a picture renumbers
/// every picture after it, which is exactly when that matters most — so the
/// two fields are rebuilt from one array rather than filtered separately.
///
/// The file is a *downloaded* one, in the directory the review screen owns.
/// See ``CommunityTransporting/keepOnlyPhotos(_:of:staging:)`` for why the
/// bytes have to make the trip back up.
nonisolated struct CommunityKeptPhoto: Hashable, Sendable {
    var pin: CommunityPhotoPin
    var fileURL: URL
}

/// One photograph of the hike whose preview is open, and where on the trail it
/// was taken.
///
/// What the map draws a pin from. A ``CommunityHikeDetail`` carries the same
/// facts in two arrays paired by index; this is that pairing made into one
/// value, for the photographs that have somewhere to stand.
nonisolated struct CommunityPreviewPhoto: Identifiable, Hashable, Sendable {
    /// Which photograph of the hike this is, counting the unanchored ones.
    ///
    /// Also its identity, and that is the reason it is carried rather than
    /// derived: a hiker photographs the same summit twice, and a coordinate
    /// cannot tell those two pictures apart. Under a reviewer removing one it
    /// is also the only thing that stays still — see ``CommunityKeptPhoto``.
    var index: Int
    var latitude: Double
    var longitude: Double
    var capturedAt: Date
    /// The downloaded file the callout decodes its thumbnail from.
    ///
    /// Owned by the screen that downloaded it and deleted with that screen, so
    /// a pin outliving its preview is a pin pointing at a file that has gone.
    /// Nothing here has to defend against that — the pins are retired by the
    /// same two calls that retire the line; see
    /// ``CommunityBrowser/previewClosed(_:)``.
    var fileURL: URL

    var id: Int { index }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// A request that the map open one community photo pin's callout.
///
/// The ``CommunityPreviewPhoto/index`` counterpart of ``PinSelection``, and
/// tokened for the same reason: asking twice for the same photograph is two
/// requests, and the second must not look like one already answered.
nonisolated struct CommunityPhotoPinSelection: Equatable, Sendable {
    let index: Int
    let token: Int
}

/// One photograph of a shared hike, as its gallery pages through them.
///
/// The difference from ``CommunityPreviewPhoto`` is which photographs are in
/// it, and it follows from what each of the two is for. That one is what the
/// *map* draws, so a picture with nowhere to stand is left out of it; this one
/// is what the *gallery* pages through, where a picture with no coordinate is
/// still a picture. So the pin is optional here and the array is never short —
/// the strip and the viewer show the same photographs in the same order, which
/// is the whole of what makes tapping the third tile land on the third page.
nonisolated struct CommunityGalleryPhoto: Identifiable, Hashable, Sendable {
    /// Which photograph of the hike this is, and its identity — the same index
    /// ``CommunityPreviewPhoto`` carries, so a map pin and a page agree about
    /// which picture they are both about.
    ///
    /// Counted across the **whole** gallery rather than within one source: the
    /// hike's own photographs first and then each published contribution, so
    /// the viewer can go on using it as a position in one array. See
    /// ``CommunityHikeDetail/galleryPhotos``, which is the only thing that
    /// assigns it.
    var index: Int
    /// Where and when it was taken, or `nil` when nothing may claim to know.
    var pin: CommunityPhotoPin?
    var fileURL: URL
    /// Who contributed this picture, or `nil` when it came from the hike's own
    /// author.
    ///
    /// The `nil` is the ordinary case and carries the meaning: a photograph
    /// with no attribution is the hike's, credited by the listing's own author
    /// name, reported by reporting the hike and taken down by taking the hike
    /// down. One with an attribution is a second person's, and every one of
    /// those four is a different record — see ``CommunityPhotoAttribution``.
    var contribution: CommunityPhotoAttribution?

    var id: Int { index }

    var coordinate: CLLocationCoordinate2D? { pin?.coordinate }

    /// What to put beside the picture, or `nil` when it is the hike's own and
    /// the screen has already credited its author.
    var credit: String? { contribution?.credit }
}

/// The decoded contents of the two asset fields on a submission.
///
/// A struct rather than two loose arrays so the one invariant that matters —
/// a pin per photo, in order — has somewhere to be enforced. See
/// ``CommunityHikeDetail/isConsistent``.
nonisolated struct CommunityRouteDocument: Codable, Hashable, Sendable {
    var route: [RouteCoordinate]
    /// The places marked along the route — none, in a document written
    /// before places were published.
    ///
    /// In the route's own asset rather than a field of the record, which is
    /// what lets them ship with **no CloudKit schema change**: the asset is a
    /// file, a file can carry a new key, and a version that does not know the
    /// key decodes the route and ignores it. Decoded apart from the route —
    /// see ``init(from:)`` — so a malformed list costs the places and never
    /// the walk.
    var places: [CommunityPlace]

    init(route: [RouteCoordinate], places: [CommunityPlace] = []) {
        self.route = route
        self.places = places
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        route = try container.decode([RouteCoordinate].self, forKey: .route)
        places = (try? container.decodeIfPresent([CommunityPlace].self, forKey: .places)) ?? []
    }
}

/// One place along a shared hike, as it is written into the route's asset.
///
/// Its own shape rather than ``TrailPlace`` itself, and every field that names
/// something is a string: this is read on devices running other versions, and
/// a ``TrailPlaceSymbol`` or ``TrailPlaceFact/Kind`` a reader does not know
/// would fail the whole decode if it were an enumeration here. A string it
/// does not know is answered as *no symbol*, or as a fact it does not show —
/// see ``CommunityRoutePayload/places(_:)``, which is also where everything
/// here is bounded, because a stranger wrote it.
nonisolated struct CommunityPlace: Codable, Hashable, Sendable {
    /// The author's own id for the place, which is what a photograph's
    /// ``CommunityPhotoPin/placeID`` names. Never kept on import — see
    /// ``CommunityImport``.
    var id: UUID
    var latitude: Double
    var longitude: Double
    var name: String
    var symbol: String?
    var note: String
    var osmElementType: String?
    var osmElementID: Int64?
    /// OpenStreetMap's tags as they were read, by tag — the shape
    /// ``TrailPlaceFact/facts(in:)`` reads them back out of.
    ///
    /// Optional because it is a wire field: a place the hiker made has no
    /// tags, and the key is then absent rather than an empty object, which a
    /// synthesized decode of a non-optional would refuse — losing every place
    /// in the file over one.
    var osmTags: [String: String]? // swiftlint:disable:this discouraged_optional_collection

    init(_ place: TrailPlace) {
        id = place.id
        latitude = place.latitude
        longitude = place.longitude
        name = place.name
        symbol = place.symbol?.rawValue
        note = place.note
        osmElementType = place.osm?.elementType
        osmElementID = place.osm?.elementID
        osmTags = place.osm.map { osm in
            Dictionary(osm.facts.map { ($0.kind.rawValue, $0.value) }) { first, _ in first }
        }
    }
}

/// Everything about a hike that is offered for publication, ready to upload.
///
/// The photographs are file URLs rather than `Data` deliberately. CloudKit
/// takes an asset as a file and streams it from there, so holding a dozen
/// re-encoded images in memory to hand them over would be paying twice for
/// something the framework wants on disk anyway — and the re-encoded copies
/// have to be written somewhere regardless, because the originals are the
/// wrong size to publish.
nonisolated struct CommunitySubmissionDraft: Sendable {
    var hikeID: UUID
    var title: String
    var authorName: String
    var trackDescription: String?
    var hikeDate: Date
    var distanceMeters: Double
    var route: [RouteCoordinate]
    /// The places marked along the route. Every one of them goes: a place is
    /// part of the trail being shared, as its name is.
    var places: [CommunityPlace] = []
    var photoPins: [CommunityPhotoPin]
    /// Re-encoded copies, in ``photoPins`` order, inside ``stagingDirectory``.
    var photoFileURLs: [URL]
    /// Where this attempt's asset files go: the re-encoded photographs above,
    /// and whatever else the transport has to put on disk to hand over.
    ///
    /// Named on the draft rather than inferred from ``photoFileURLs``, which
    /// is what it used to be. A hike with no photographs — or one whose
    /// pictures all failed to encode — left nothing to infer from, so the
    /// route JSON was written to the process-wide temporary directory
    /// instead: a full copy of the walk outside the directory its owner
    /// deletes, kept on the device after every success and every failure, and
    /// written to one fixed path that two submissions in flight at once both
    /// pointed at. An atomic write makes each of those two files whole; it
    /// does not make them different files.
    ///
    /// Owned by the caller, which creates it, gives every attempt its own,
    /// and deletes it on every exit — see ``CommunityPublisher``.
    var stagingDirectory: URL

    /// Where the route begins, which is what the listing is found by.
    ///
    /// The first point rather than a centroid: a hiker searching near a place
    /// is looking for something to set off on from there, and the trailhead is
    /// the part of a route that answers that. A centroid would put a long
    /// linear route's match ten kilometres from either end of it.
    var startCoordinate: CLLocationCoordinate2D? {
        route.first?.clCoordinate
    }
}

/// A published hike as the browse list knows it: enough to draw a row and
/// decide whether to open it, and nothing more.
///
/// Deliberately carries neither the route nor any image. A location query can
/// come back with fifty of these, and fifty routes is tens of megabytes of
/// transfer for a list the hiker will scroll past — so the route and the
/// photographs are fetched from the submission only once a hike is opened.
///
/// No thumbnail either, which is a lifetime decision rather than a visual
/// one: a `CKAsset` handed back by a query points into CloudKit's own cache,
/// and the framework may delete the file behind it whenever it likes. A row
/// in a list the hiker scrolls a minute later would be reading a path that
/// has gone. Copying each one to keep it would mean a file write per row of a
/// list nobody asked to keep, so the row draws a symbol and a photo count and
/// the pictures arrive with the hike itself.
nonisolated struct CommunityListing: CommunityBlockableRow, Identifiable, Hashable, Sendable {
    /// This hike's identity across the whole app, including
    /// ``Hike/importedFromListingID``.
    ///
    /// A CloudKit listing's record name, or — for a curated route — the
    /// namespaced form ``CommunityIdentity/curated(relationID:)`` builds. One
    /// column holds both, so they cannot be allowed to look alike.
    var id: String
    /// Where this came from, and the facts that exist only for that source.
    ///
    /// See ``CommunityOrigin``: the author and the submission live in here
    /// rather than beside the fields below, because a curated route has
    /// neither and the empty strings that used to stand in for them were
    /// values the app treated as meaningful.
    var origin: CommunityOrigin
    var title: String
    /// What the hiker typed when they shared it, which is a credit and not an
    /// identity — see ``CommunityOrigin/published(submissionID:authorID:)``
    /// for the identity and why the two are apart.
    ///
    /// Empty for a curated route, which nobody shared. The screen credits
    /// OpenStreetMap's contributors instead, and the emptiness is what every
    /// existing consumer already branches on.
    var authorName: String
    /// The day this was walked, or `nil` when nobody walked it.
    ///
    /// Optional rather than a `.distantPast` sentinel, because the sentinel is
    /// a date and every consumer formatted it as one: a curated route carrying
    /// it would head its screen with *1 January 1*.
    var hikeDate: Date?
    var distanceMeters: Double
    var photoCount: Int
    var latitude: Double
    var longitude: Double
    var publishedAt: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// The submission behind this hike, or `nil` for a curated route.
    var submissionID: String? { origin.submissionID }

    /// Who may be blocked over this hike, or `nil` when there is nobody.
    ///
    /// ``CommunityBlockableRow``'s one requirement, which is how a page of
    /// these is filtered before the budget counts it — see
    /// ``CommunityPageBudget``.
    var blockableAuthorID: String? { origin.blockableAuthorID }

    /// Whether this came from OpenStreetMap rather than from a hiker.
    var isCurated: Bool { origin.isCurated }

    /// The OSM relation behind this hike, or `nil` when a person published it.
    ///
    /// The fourth of these and the one that was missing, which left its two
    /// callers reading through ``origin`` while everything beside them had a
    /// spelling here. It is also the *total* answer to the question
    /// ``CommunityIdentity/relationID(of:)`` answers about a bare string:
    /// routing a per-listing request on this is a fact about where the listing
    /// came from, where routing on the id is a fact about how the id is
    /// spelled, and only one of those is what the caller means.
    var relationID: Int64? { origin.relationID }

    /// What OpenStreetMap says about this route, or `nil` for a published
    /// hike. See ``CuratedTrailFacts``.
    var curatedFacts: CuratedTrailFacts? { origin.curatedFacts }

    /// How long this hike is, or `nil` when there is no line to measure yet.
    ///
    /// Only a curated row is ever in that second state, and only between the
    /// search that listed it and its line arriving. A geometry pass Overpass
    /// refused now leaves the row standing without one rather than taking it
    /// off the list — see ``CuratedTrailSourcing/completed(_:)`` — because the
    /// listing pass had already paid for it and the trail is really there.
    /// Opening the row fetches the line, so the state is as short as the
    /// hiker's next tap. A published hike always has a length of its own,
    /// measured from the track somebody uploaded.
    ///
    /// Zero is how that is spelled, because a route's length *is* its line's
    /// length and an empty line is zero metres long. What this exists for is
    /// to keep every reader from formatting that as *0 m*, which is a claim
    /// about a trail rather than the absence of one — and which is what a row
    /// and a map callout each did with it once.
    var drawnDistanceMeters: Double? { distanceMeters > 0 ? distanceMeters : nil }
}

nonisolated extension CommunityListing {
    /// A published listing, spelled the way every caller already spells one.
    ///
    /// Kept when ``origin`` replaced the two loose fields, rather than
    /// rewriting forty-odd construction sites across the app and the test
    /// bundles to say `.published(submissionID:authorID:)` in longhand. It is
    /// not a convenience so much as the *only* way to build this case — which
    /// is the point: there is no initialiser here that can make a listing with
    /// an author it cannot name.
    init(
        id: String,
        submissionID: String,
        title: String,
        authorName: String,
        authorID: String,
        hikeDate: Date?,
        distanceMeters: Double,
        photoCount: Int,
        latitude: Double,
        longitude: Double,
        publishedAt: Date
    ) {
        self.init(
            id: id,
            origin: .published(submissionID: submissionID, authorID: authorID),
            title: title,
            authorName: authorName,
            hikeDate: hikeDate,
            distanceMeters: distanceMeters,
            photoCount: photoCount,
            latitude: latitude,
            longitude: longitude,
            publishedAt: publishedAt
        )
    }

    /// The listing a curated route is drawn as.
    ///
    /// Everything a published hike gets from a person is absent by
    /// construction: no author to credit, no date anybody walked it, and no
    /// photographs.
    ///
    /// `editedAt` is **not** OSM's last-edit time, and nothing here can make
    /// it one: the listing pass asks `out tags bb` rather than `out meta`,
    /// because a timestamp nothing draws is not worth doubling the size of
    /// every search for. It is the moment the row was fetched — see
    /// ``MergedCommunityTransport``, which passes `.now`. That gives a merged
    /// list something defensible to order by when there is no distance to use,
    /// and it is never shown.
    init(curated trail: CuratedTrail, editedAt: Date) {
        self.init(
            id: CommunityIdentity.curated(relationID: trail.relationID),
            origin: .openStreetMap(relationID: trail.relationID, facts: trail.facts),
            title: trail.name,
            authorName: "",
            hikeDate: nil,
            distanceMeters: trail.distanceMeters,
            photoCount: 0,
            latitude: trail.coordinate.latitude,
            longitude: trail.coordinate.longitude,
            publishedAt: editedAt
        )
    }
}

/// A published hike's line on the map, and which of the two kinds of line it
/// is.
///
/// The map draws shared hikes at two fidelities and they are deliberately one
/// type rather than two. Every hike in the nearby answer is drawn from its
/// ``CommunityRouteOutline`` — a kilobyte, faded, there to be seen and tapped.
/// The one whose preview is open is drawn from the route the preview itself
/// downloaded: every point of it, at full strength, because that screen no
/// longer draws the route anywhere else and this *is* where the hiker sees
/// what they are deciding about.
///
/// One type because the map's job is identical either way — build a polyline,
/// style it, let a tap find it — and the only thing that differs is two
/// numbers in a renderer. Two types would mean two overlay arrays, two
/// rebuild guards and two hit-tests, so that a tap on the emphasised line
/// could open the screen it is already showing.
nonisolated struct CommunityRouteLine: Identifiable, Hashable, Sendable {
    /// The hike this line is, so a tap has somewhere to go.
    var listing: CommunityListing
    var coordinates: [RouteCoordinate]
    /// Whether this is the hike whose preview is open.
    var isPreviewed: Bool

    var id: String { listing.id }
}

/// A published hike's full contents, fetched when one is opened.
nonisolated struct CommunityHikeDetail: Sendable, CommunityReviewSubject {
    var listing: CommunityListing
    var route: [RouteCoordinate]
    /// The places the author marked along the route, checked and bounded —
    /// see ``CommunityRoutePayload/places(_:)``. Their ids are the author's,
    /// which is what the photographs' ``CommunityPhotoPin/placeID``s name.
    var places: [TrailPlace] = []
    var trackDescription: String?
    var photoPins: [CommunityPhotoPin]
    /// Downloaded photographs, in ``photoPins`` order.
    var photoFileURLs: [URL]
    /// How many photographs the submission actually carries.
    ///
    /// Not the same number as ``photoFileURLs``'s count, and the difference is
    /// the whole reason this is here: a download can lose one, and the
    /// surviving pictures go on describing themselves correctly because the
    /// pins pair by index — see ``CloudKitCommunityTransport/pins(_:for:of:takenOn:)``.
    ///
    /// A screen *showing* a hike has no use for this; one photograph fewer is
    /// one tile fewer and nothing else. A screen that **rewrites** the record's
    /// photographs has every use for it, because the rewrite is built out of
    /// the copies on this device: doing it while one is missing would delete
    /// that one too, permanently, without the reviewer having decided anything
    /// about it. See ``hasEveryPhoto``, which is the question this exists to
    /// answer.
    var photosOnRecord: Int
    /// Photographs other hikers have published onto this trail, oldest set
    /// first.
    ///
    /// Beside the four fields above rather than merged into them, and that
    /// separation is load-bearing rather than tidy. Those four describe **the
    /// submission**: they are what ``hasEveryPhoto`` is asked about and what
    /// ``keptPhotos(at:)`` rewrites, and a reviewer taking a photograph off a
    /// hike must never be able to reach a picture somebody else owns. These
    /// are separate records with separate authors, taken down separately and
    /// blocked separately — see ``CommunityPhotoContribution``.
    ///
    /// Where the two *do* come together is on screen, in
    /// ``galleryPhotos`` and ``previewPhotos``, because a hiker looking at a
    /// trail is looking at pictures of a place rather than at a filing system.
    ///
    /// Empty is the ordinary case: every hike had none until this existed, a
    /// download that failed leaves none, and nothing about the screen changes
    /// when there are none.
    var contributions: [CommunityPhotoContribution] = []

    /// This detail with the contributed sets a hiker may no longer see taken
    /// out.
    ///
    /// Two things can hide a set after it has been downloaded, and neither can
    /// reach the request that fetched it: blocking its contributor, and — for
    /// a reviewer — taking it down. Both are decided in the gallery pushed
    /// over the trail, and coming back from that gallery is a pop rather than
    /// a fetch, so the filter has to be on the draw. See
    /// ``CommunityHikeView/visible(_:)``, which is the only caller and the
    /// place the two sets come from.
    ///
    /// A whole detail rather than a filtered array, because the offsets are
    /// shared: ``galleryPhotos`` and ``previewPhotos`` number the same
    /// pictures the same way, and a map pin that opened the page beside the
    /// one it was about would be the bug that arithmetic exists to prevent.
    /// The submission's own four fields are untouched — a block is about a
    /// contributor and a takedown is about a contribution, and neither has
    /// anything to say about the hike's author.
    ///
    /// - Parameters:
    ///   - authors: Blocked contributors, by
    ///     ``CommunityPhotoContribution/authorID``.
    ///   - removed: Contributions taken down this launch, by record name.
    func excluding(
        authors: Set<String>,
        contributions removed: Set<String>
    ) -> Self {
        // The ordinary path, and worth the check: most hikers have blocked
        // nobody and almost nobody is a reviewer, so this is a pass over a
        // handful of sets that could only ever keep all of them.
        guard !authors.isEmpty || !removed.isEmpty else { return self }
        var visible = self
        visible.contributions = contributions.filter { contribution in
            !authors.contains(contribution.authorID) && !removed.contains(contribution.id)
        }
        return visible
    }

    /// Whether the pins and the assets still describe each other.
    ///
    /// Asked before a photograph is attached rather than trusted — by
    /// ``CommunityImport``, which is the only thing that reads the two arrays
    /// against each other. The two fields are written together by this app and
    /// read back from a database a reviewer edits by hand, so they can
    /// disagree, and the failure mode of not checking is a photograph silently
    /// pinned to a different photograph's coordinate — which nothing
    /// downstream could ever detect, and which a saved hike keeps for good.
    ///
    /// The check itself, and the rest of the pairing, is
    /// ``CommunityReviewSubject``'s.
    /// ``CloudKitCommunityTransport/detail(for:downloadingInto:)`` builds both
    /// arrays from the same downloaded files, so nothing it hands back can
    /// fail it.
    ///
    /// The hike's own photographs are credited by the listing's author name,
    /// and reported, blocked and taken down as the hike — so there is no
    /// per-photograph attribution to carry. A contributed set is the case that
    /// has one.
    var galleryAttribution: CommunityPhotoAttribution? { nil }

    /// The photographs that know where they were taken, ready for the map.
    ///
    /// Unanchored ones are left out rather than pinned somewhere plausible,
    /// which is the rule ``PhotoMapPin`` already follows for the hiker's own
    /// pictures: a photograph with no coordinate is still part of the hike and
    /// still in the strip, it just has nowhere to stand.
    ///
    /// Empty when the two arrays disagree, for the reason ``isConsistent``
    /// gives. A pin is a claim about *which* photograph was taken *where*, and
    /// pairing by index is the entirety of what backs that claim — so a
    /// detail that cannot support it draws no pins at all rather than pins
    /// that might each be about the picture next door.
    var previewPhotos: [CommunityPreviewPhoto] {
        ownPreviewPhotos + contributedPreviewPhotos
    }

    /// ``CommunityReviewSubject``'s spelling.
    ///
    /// ``previewPhotos`` rather than ``ownPreviewPhotos``, which is what the
    /// review screen has always passed and so is what this keeps. Worth a
    /// second look: `ownPreviewPhotos` documents itself as the one the review
    /// screen wants, and the two differ only for a detail carrying
    /// contributed photographs — which a submission under review cannot have,
    /// because nothing can contribute to a listing that does not exist yet.
    var reviewPreviewPhotos: [CommunityPreviewPhoto] { previewPhotos }

    /// The hike author's own anchored photographs.
    ///
    /// Separate from ``previewPhotos`` because the review screen wants exactly
    /// these: a reviewer striking a photograph off a submission is deciding
    /// about that submission's pictures, and a contributed pin under their
    /// thumb would be a picture they cannot remove from a record they are not
    /// editing.
    var ownPreviewPhotos: [CommunityPreviewPhoto] { previewPhotos(startingAt: 0) }

    /// Everybody else's anchored photographs, numbered on from the author's.
    ///
    /// The offsets are the whole of what this does, and they have to be the
    /// gallery's: a map pin and a gallery page identify the same picture by
    /// the same number, so a pin tapped on the map has to open the page the
    /// strip would. ``contributedOffsets`` is the one place that arithmetic
    /// is done.
    var contributedPreviewPhotos: [CommunityPreviewPhoto] {
        zip(contributions, contributedOffsets).flatMap { contribution, offset in
            contribution.previewPhotos(startingAt: offset)
        }
    }

    /// Where each contribution starts in the merged gallery.
    ///
    /// The author's photographs come first and every contribution follows in
    /// publication order, so one set gaining or losing a picture between two
    /// opens moves the ones after it — which is why nothing stores these
    /// numbers and everything derives them from the same walk.
    ///
    /// Counted over the **downloaded** files rather than over each set's
    /// ``CommunityPhotoContribution/photosOnRecord``, because the gallery can
    /// only show what arrived and the index is a position in it.
    private var contributedOffsets: [Int] {
        var offset = photoFileURLs.count
        return contributions.map { contribution in
            defer { offset += contribution.photoFileURLs.count }
            return offset
        }
    }

    /// Every downloaded photograph, in the order the strip draws them.
    ///
    /// Unlike ``previewPhotos`` this drops nothing, because the gallery is the
    /// strip made large: a picture missing from here would make the fourth
    /// tile open the fifth photograph. What an inconsistent detail loses is
    /// the *places* rather than the pictures — a pin is a claim about which
    /// photograph was taken where, pairing by index is the entirety of what
    /// backs that claim, and a detail that cannot support it makes none.
    var galleryPhotos: [CommunityGalleryPhoto] {
        ownGalleryPhotos + zip(contributions, contributedOffsets).flatMap { contribution, offset in
            contribution.galleryPhotos(startingAt: offset)
        }
    }

    /// The hike author's own photographs, which is what the review screen
    /// draws.
    ///
    /// The distinction the strip on the *public* screen deliberately does not
    /// make — a hiker deciding on a trail is looking at pictures of a place,
    /// whoever took them — and the one the reviewer's screen has to, for the
    /// reason ``ownPreviewPhotos`` gives.
    var ownGalleryPhotos: [CommunityGalleryPhoto] { galleryPhotos(startingAt: 0) }

}
