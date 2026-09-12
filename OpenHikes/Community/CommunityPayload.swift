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

/// The decoded contents of the two asset fields on a submission.
///
/// A struct rather than two loose arrays so the one invariant that matters —
/// a pin per photo, in order — has somewhere to be enforced. See
/// ``isConsistent(withPhotoCount:)``.
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
    /// Re-encoded copies, in ``photoPins`` order. Owned by the caller, which
    /// deletes the directory holding them once the upload has finished or
    /// failed — see ``CommunityPublisher``.
    var photoFileURLs: [URL]

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
    /// The listing record's own name, which is also its identity here.
    var id: String
    /// The submission record this was published from, fetched on open.
    var submissionID: String
    var title: String
    /// What the hiker typed when they shared it, which is a credit and not
    /// an identity. See ``authorID`` for the difference and why both are here.
    var authorName: String
    /// Who published it, as CloudKit knows them.
    ///
    /// Carried on every listing so a hiker can block the person rather than
    /// the name they happened to type — see ``CommunitySchema/Listing/authorID``
    /// and ``CommunityBlockList``. Never shown: it is an opaque record name,
    /// and the screen credits ``authorName``.
    var authorID: String
    var hikeDate: Date
    var distanceMeters: Double
    var photoCount: Int
    var latitude: Double
    var longitude: Double
    var publishedAt: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
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

    /// Whether the pins and the assets still describe each other.
    ///
    /// Asked before anything is imported rather than trusted. The two fields
    /// are written together by this app and read back from a database a
    /// reviewer edits by hand, so they can disagree — and the failure mode of
    /// not checking is a photograph silently pinned to a different
    /// photograph's coordinate, which nothing downstream could ever detect.
    var isConsistent: Bool {
        photoPins.count == photoFileURLs.count
    }
}
