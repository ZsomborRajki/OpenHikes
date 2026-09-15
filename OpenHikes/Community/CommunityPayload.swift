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

/// One photograph's place in a shared hike.
///
/// Kept apart from the image bytes because CloudKit assets carry nothing but
/// bytes — no name, no type, no metadata — so the ordering and the pins have
/// to be stated somewhere the assets can be matched against by index.
nonisolated struct CommunityPhotoPin: Codable, Hashable, Sendable {
    var capturedAt: Date
    var latitude: Double?
    var longitude: Double?

    init(capturedAt: Date, coordinate: CLLocationCoordinate2D?) {
        self.capturedAt = capturedAt
        latitude = coordinate?.latitude
        longitude = coordinate?.longitude
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
    var index: Int
    /// Where and when it was taken, or `nil` when nothing may claim to know.
    var pin: CommunityPhotoPin?
    var fileURL: URL

    var id: Int { index }

    var coordinate: CLLocationCoordinate2D? { pin?.coordinate }
}

/// The decoded contents of the two asset fields on a submission.
///
/// A struct rather than two loose arrays so the one invariant that matters —
/// a pin per photo, in order — has somewhere to be enforced. See
/// ``CommunityHikeDetail/isConsistent``.
nonisolated struct CommunityRouteDocument: Codable, Hashable, Sendable {
    var route: [RouteCoordinate]
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
nonisolated struct CommunityListing: Identifiable, Hashable, Sendable {
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
    var blockableAuthorID: String? { origin.blockableAuthorID }

    /// Whether this came from OpenStreetMap rather than from a hiker.
    var isCurated: Bool { origin.isCurated }

    /// What OpenStreetMap says about this route, or `nil` for a published
    /// hike. See ``CuratedTrailFacts``.
    var curatedFacts: CuratedTrailFacts? { origin.curatedFacts }
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
    /// photographs. `publishedAt` carries the relation's own last-edit time
    /// where OSM reports one, so a merged list has a defensible order rather
    /// than sinking every curated row beneath every published one.
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
nonisolated struct CommunityHikeDetail: Sendable {
    var listing: CommunityListing
    var route: [RouteCoordinate]
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
    /// ``CloudKitCommunityTransport/detail(for:downloadingInto:)`` builds both
    /// arrays from the same downloaded files, so nothing it hands back can
    /// fail this. That is a reason to keep the check rather than to drop it:
    /// the guarantee lives in one conformance, the consequence of losing it is
    /// undetectable and permanent, and the check costs a comparison on a path
    /// that already walks every photograph.
    var isConsistent: Bool {
        photoPins.count == photoFileURLs.count
    }

    /// Whether every photograph on the record reached this device.
    ///
    /// What ``CommunityTransporting/keepOnlyPhotos(_:of:staging:)`` may only
    /// be called behind — see ``photosOnRecord``.
    var hasEveryPhoto: Bool {
        isConsistent && photoFileURLs.count == photosOnRecord
    }

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
        guard isConsistent else { return [] }
        return zip(photoPins, photoFileURLs).enumerated().compactMap { index, pair in
            guard let coordinate = pair.0.coordinate else { return nil }
            return CommunityPreviewPhoto(
                index: index,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                capturedAt: pair.0.capturedAt,
                fileURL: pair.1
            )
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
        let pinned = isConsistent
        return photoFileURLs.enumerated().map { index, url in
            CommunityGalleryPhoto(
                index: index,
                pin: pinned ? photoPins[index] : nil,
                fileURL: url
            )
        }
    }

    /// The photographs at `indexes`, each with the pin that describes it, in
    /// the order they arrived in.
    ///
    /// The order is load-bearing rather than tidy: what comes back is written
    /// straight onto the submission as its two photo fields, and those pair by
    /// position. Sorting by index is what keeps the first picture first after
    /// the third has been taken out.
    ///
    /// Empty when the two arrays disagree — the same refusal ``previewPhotos``
    /// makes, and a sharper one here, since this answer is uploaded.
    func keptPhotos(at indexes: Set<Int>) -> [CommunityKeptPhoto] {
        guard isConsistent else { return [] }
        return indexes.sorted().compactMap { index in
            guard photoFileURLs.indices.contains(index) else { return nil }
            return CommunityKeptPhoto(pin: photoPins[index], fileURL: photoFileURLs[index])
        }
    }
}
