//
//  CommunityImport.swift
//  OpenHikes
//
//  Turning somebody else's published hike into one of this hiker's own.
//
//  Deliberately the same shape as ``HikeImport``, because it makes the same
//  promise: everything downstream of a successful import acts on the claim
//  that the hike is *kept*, so the commit happens here, before anything is
//  told there is a hike. A refused save comes back as a failure rather than
//  as a `Hike`.
//
//  What is different is that the photographs are somebody else's, and two
//  decisions follow from that and are not negotiable at the call site.
//
//  The imported copies never reach the hiker's photo library. The library
//  mirror is an opt-in for photographs the hiker *took*
//  (``SettingsKey/savePhotosToLibrary``), and honouring it here would quietly
//  file a stranger's pictures into a library somebody curates by hand — a
//  thing they did not ask for and would have to undo one at a time. So the
//  writer is passed `false` unconditionally rather than read from defaults.
//
//  The pictures other hikers contributed come too, and they are the reason the
//  paragraph above has to be said twice. A contribution is a *different
//  person's* photograph on the same trail — see ``CommunityPhotoContribution``
//  — so a copy of one is stamped with the listing like any other import, and
//  additionally with the name its contributor asked to be credited under. That
//  per-photograph credit is the whole of what this needed and did not have:
//  the hike's ``Hike/importedAuthorName`` names whoever published the walk,
//  which for a contributed picture is the wrong person.
//
//  This used to copy only the author's own submission, and that was wrong in
//  the one way a hiker could see. The trail's preview draws the two sets
//  merged, deliberately — a hiker looking at a trail is looking at pictures of
//  a place, whoever took them — so saving a hike from a preview showing eight
//  photographs produced a hike holding three, with no account of where the
//  other five went. It is also how a hiker lost *their own* contributed
//  photograph: the way to add a picture to a trail somebody else published is
//  to contribute it, and a hike deleted and saved again came back without it.
//
//  And the distance is recomputed from the route rather than copied from the
//  listing. The listing is a record a human creates by hand in the CloudKit
//  Console, so its numbers are typed; the route is what was actually uploaded.
//  Where the two disagree the route is the one that drew the line on the map,
//  and a hike whose stated length disagreed with its own polyline would be
//  wrong in the one place the hiker could see it.
//

import CoreLocation
import Foundation
import OpenHikesData
import os
import SwiftData

/// What one attempt to import a published hike did.
enum CommunityImportOutcome {
    /// Already in the library, from an earlier import. The existing hike is
    /// handed back so the caller can open it rather than reporting an error
    /// for something that is not one.
    case alreadyImported(Hike)
    case imported(Hike)
    case refused(CommunityFailure)

    var hike: Hike? {
        switch self {
        case .alreadyImported(let hike), .imported(let hike): hike
        case .refused: nil
        }
    }
}

nonisolated enum CommunityImport {
    private static let logger = Logger(subsystem: "OpenHikes", category: "Community")

    /// Adds `detail` to the library, committing before it reports success.
    ///
    /// - Parameter saveDate: The clock, handed in so the date a curated route
    ///   is filed under can be pinned by a test.
    /// - Parameter alreadyImported: The has-it-already read, handed in so the
    ///   branch below can be reached at all. Closure-driven for the reason
    ///   ``StoredTileDeletionPlan/init(doomedClaim:survivingClaims:)`` is:
    ///   nothing makes a `ModelContext` throw on demand — a fetch against a
    ///   schema it does not know comes back empty rather than failing — so
    ///   without the seam the refusal could be rewritten as `try?` and every
    ///   test in the bundle would still pass, while a store under stress grew
    ///   a second row for one listing.
    /// - Parameter save: The commit seam, the same shape ``HikeImport`` takes
    ///   its own in.
    @MainActor
    static func importHike(
        _ detail: CommunityHikeDetail,
        into context: ModelContext,
        store: HikePhotoStore = .shared,
        libraryWriter: any PhotoLibraryWriting = PhotoLibraryWriter(),
        saveDate: Date = .now,
        alreadyImported: (String, ModelContext) throws -> Hike? = { try existingImport(of: $0, in: $1) },
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) async -> CommunityImportOutcome {
        guard detail.route.count >= 2 else { return .refused(.nothingToShare) }
        do {
            if let existing = try alreadyImported(detail.listing.id, context) {
                return .alreadyImported(existing)
            }
        } catch {
            // A store that cannot answer *is this already here* is not a store
            // that says no. Reading the failure as "not imported" is how one
            // listing ends up with two rows claiming it — the invariant this
            // fetch exists to hold — and a store under stress is exactly when
            // that costs most: the Saved badge and the open-destination then
            // disagree with each other for good. ``HikeImport/imported(_:into:)``
            // refuses the same way for the same reason.
            logger.error(
                "A community hike was not imported: the library could not be asked whether it already has it."
            )
            return .refused(.unavailable(error.localizedDescription))
        }

        let listing = detail.listing
        let hike = Hike(
            title: listing.title,
            distanceMeters: routeLength(of: detail.route),
            // A curated route carries no date, because nobody walked it. The
            // day it was saved is the only honest value: ``Hike/date`` means
            // *when this walk happened*, and the hikes list is sorted by it, so
            // a distant-past sentinel would file a trail the hiker just added
            // at the bottom of everything they have ever done.
            date: listing.hikeDate ?? saveDate,
            route: detail.route,
            trackDescription: detail.trackDescription
        )
        hike.importedFromListingID = listing.id
        // The colour the hiker has been looking at, rather than the green
        // ``Hike`` defaults to.
        //
        // A file import picks at random for this reason — a library of
        // identical lines tells a hiker nothing — and a community import had
        // been landing every trail in the default green instead. It need not
        // pick at random, because this hike has been on screen for a while
        // already: it was a coloured row, a pin, a line on the map and the
        // graph on the screen the hiker pressed *Add to My Hikes* on. Keeping
        // that colour is what makes the hike that appears in the library the
        // one they were just deciding about. See ``CommunityListing/tint``,
        // which is derived from the same id ``importedFromListingID`` holds,
        // so the two agree by construction.
        //
        // Theirs to change from here, like any other hike's.
        hike.tintHex = listing.tintHex
        // Left `nil` for a curated route, which nobody shared. It is what
        // ``CommunityPublishingEligibility`` reads to tell a stranger's hike
        // from a trail OpenStreetMap already had — see
        // ``CommunityPublishingEligibility/Reason/savedFromOpenStreetMap``.
        hike.importedAuthorName = listing.authorName.isEmpty ? nil : listing.authorName
        context.insert(hike)
        // The places the author marked, each under a new id of this device's
        // own. The author's ids are theirs — the same trail saved twice, or
        // an author saving their own listing back, would otherwise put two
        // rows under one id — and they are remembered only long enough to
        // file the author's photographs under the right copies below.
        let placeIDs = Dictionary(detail.places.map { ($0.id, UUID()) }) { first, _ in first }
        hike.replacePlaces(
            with: detail.places.map { place in
                TrailPlace(
                    latitude: place.latitude,
                    longitude: place.longitude,
                    name: place.name,
                    symbol: place.symbol,
                    note: place.note,
                    osm: place.osm,
                    id: placeIDs[place.id] ?? UUID()
                )
            },
            in: context,
            now: saveDate
        )

        do {
            try save(context)
        } catch {
            // Nothing is left behind: the row never committed, and the
            // downloaded files belong to the caller's directory, which it
            // deletes either way.
            logger.error(
                "Could not keep an imported community hike: \(error.localizedDescription, privacy: .public)"
            )
            context.delete(hike)
            return .refused(.unavailable(error.localizedDescription))
        }

        await attachPhotos(
            of: detail,
            to: hike,
            places: placeIDs,
            store: store,
            libraryWriter: libraryWriter,
            save: save
        )
        return .imported(hike)
    }

    /// Whether this listing is already in the library.
    ///
    /// By listing rather than by title: two different hikers can publish the
    /// same ridge under the same name, and they are two hikes.
    ///
    /// Throws rather than answering `nil` when the fetch itself fails, because
    /// the two answers are not interchangeable for every caller: *no* means go
    /// ahead and insert one, and a migration, a corrupt store or a mirror
    /// conflict must not be read as that. A caller for which the distinction
    /// does not matter — a badge, a destination — writes `try?` and gets the
    /// old behaviour, visibly.
    @MainActor
    static func existingImport(of listingID: String, in context: ModelContext) throws -> Hike? {
        var descriptor = FetchDescriptor<Hike>(
            predicate: #Predicate { $0.importedFromListingID == listingID }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// The hiker's own copies of published hikes, keyed by the listing each
    /// one came from.
    ///
    /// For the sheet's lists, which hold every hike in a `@Query` already:
    /// asking ``existingImport(of:in:)`` per row would be a fetch per row
    /// against a store those rows are drawn from. One pass answers both
    /// questions a community row asks — whether it says *Saved*, and which
    /// screen tapping it opens — so the badge and the destination are the
    /// same fact rather than two readings of it.
    ///
    /// Two hikes carrying one listing id is a state the import refuses to
    /// create — see ``importHike(_:into:store:libraryWriter:saveDate:alreadyImported:save:)`` — but a
    /// mirrored store can deliver one from another device, so the first wins
    /// rather than the last. The lists are sorted newest first, which makes
    /// that the copy the hiker made most recently.
    @MainActor
    static func importedByListing(in hikes: [Hike]) -> [String: Hike] {
        Dictionary(
            hikes.compactMap { hike in hike.importedFromListingID.map { ($0, hike) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Copies the downloaded photographs into this hiker's own store: the
    /// hike author's, and then everybody else's.
    ///
    /// **What the saved hike holds is what the preview drew.** The strip on
    /// that screen merges the submission's photographs and the contributed
    /// ones deliberately — a hiker looking at a trail is looking at pictures
    /// of a place, whoever took them — and saving from it is the promise the
    /// button under that strip makes.
    ///
    /// Both halves are a snapshot: a contribution published tomorrow does not
    /// appear in a hike saved today, and one taken down tomorrow does not
    /// leave it. That is true of the author's own photographs already, and of
    /// the route and the title beside them — a saved hike is this hiker's own
    /// copy rather than a window onto a record somebody else can still edit,
    /// and the trail stays in the community list for anybody who wants the
    /// live one.
    ///
    /// Two calls rather than one loop over a merged array, and the separation
    /// is the point: the two sets are separate records with separate authors,
    /// so they are paired separately, credited separately, and fail
    /// separately.
    @MainActor
    private static func attachPhotos(
        of detail: CommunityHikeDetail,
        to hike: Hike,
        places: [UUID: UUID],
        store: HikePhotoStore,
        libraryWriter: any PhotoLibraryWriting,
        save: (ModelContext) throws -> Void
    ) async {
        await attachOwnPhotos(
            of: detail,
            to: hike,
            places: places,
            store: store,
            libraryWriter: libraryWriter,
            save: save
        )
        // Unconditionally, whatever the call above made of the submission. A
        // submission whose pins and files disagree is a fact about the
        // submission, and letting it cost the contributed sets too would hide
        // pictures that are perfectly well described because somebody else's
        // are not.
        await attachContributedPhotos(
            of: detail,
            to: hike,
            store: store,
            libraryWriter: libraryWriter,
            save: save
        )
    }

    /// The hike author's own photographs — the ones on the submission.
    ///
    /// One at a time, and a failure costs its own picture rather than the
    /// import: the hike is already committed and already useful, and a single
    /// photograph that would not decode is not a reason to refuse a walk.
    ///
    /// The pairing is checked first rather than trusted, which is what
    /// ``CommunityHikeDetail/isConsistent`` is for and the one place it can be
    /// asked to any purpose: the pins and the files describe each other *by
    /// index*, and `zip` truncates to the shorter of two arrays without
    /// saying so. Pairing a photograph with another photograph's coordinate is
    /// the one failure nothing downstream could notice — the hike is saved,
    /// the pin looks ordinary, and the picture is on the wrong part of the
    /// trail for good.
    ///
    /// Costs the photographs and not the walk, because that is the
    /// proportionate answer: the route committed before this ran and is the
    /// thing the hiker asked for. It is the same bargain the loop below makes
    /// for one unreadable file, one size larger.
    ///
    /// **Every copy is stamped with the listing it came from.** See
    /// ``HikePhoto/importedFromListingID``: these are the hike author's
    /// photographs sitting in this hiker's library, and the contribution flow
    /// offers to send this very hike's pictures back to this very trail. A
    /// copy that looked like the hiker's own would be one tap from
    /// republishing somebody else's work under the importer's credit.
    ///
    /// No per-photograph credit, and that is not an omission: these are the
    /// work of whoever published the walk, which the hike records once on
    /// ``Hike/importedAuthorName`` and its own screen draws as *Shared by*.
    /// ``attachContributedPhotos(of:to:store:libraryWriter:save:)`` is where a
    /// photograph needs a name of its own.
    @MainActor
    private static func attachOwnPhotos(
        of detail: CommunityHikeDetail,
        to hike: Hike,
        places: [UUID: UUID],
        store: HikePhotoStore,
        libraryWriter: any PhotoLibraryWriting,
        save: (ModelContext) throws -> Void
    ) async {
        guard detail.isConsistent else {
            logger.error(
                """
                Imported \(detail.listing.id, privacy: .public) without its photos: \
                \(detail.photoPins.count) pins for \(detail.photoFileURLs.count) files.
                """
            )
            return
        }
        await attachSet(
            zip(detail.photoPins, detail.photoFileURLs),
            // No per-photograph credit, for the reason above.
            stampedAs: Stamp(listingID: detail.listing.id, authorName: nil, places: places),
            to: hike,
            store: store,
            libraryWriter: libraryWriter,
            save: save
        )
    }

    /// The photographs other hikers published onto this trail.
    ///
    /// Copied for the reason the author's are: what the hiker pressed *Add to
    /// My Hikes* on was a strip showing both sets merged — see
    /// ``CommunityHikeDetail/galleryPhotos`` — and a saved hike holding fewer
    /// pictures than the screen it was saved from is a loss nothing on that
    /// screen accounts for. It is also the only way a hiker gets back a
    /// photograph **they contributed themselves**, which is what adding a
    /// picture to somebody else's trail means in this app.
    ///
    /// Two things are different from the author's half, and both follow from a
    /// contribution being a separate record with a separate author.
    ///
    /// **The pairing is checked per set rather than once.** Each contribution
    /// carries its own pins and its own files — see
    /// ``CommunityPhotoContribution/isConsistent`` — so one set whose two
    /// arrays disagree loses its own pictures and none of anybody else's. The
    /// reason for checking at all is the reason the author's half checks:
    /// `zip` truncates silently, and a photograph pinned to another
    /// photograph's coordinate is the one failure nothing downstream could
    /// ever notice.
    ///
    /// **Each copy carries its contributor's credit**, from
    /// ``CommunityPhotoContribution/credit``, because the hike's own
    /// ``Hike/importedAuthorName`` names the person who published the *walk*
    /// and that is not who took these. A contributor who asked for no credit
    /// leaves it `nil`, which is the honest answer rather than a lost one.
    ///
    /// Every copy is stamped with the listing just as the author's are, so
    /// ``HikePhoto/isOwn`` is false for all of them and
    /// ``CommunityPublisher/ownPhotos(of:)`` keeps the lot out of any
    /// contribution sent back to this same trail. That matters more here, not
    /// less: these pictures are already on the listing, so re-sending one
    /// would put a second copy of it in the gallery it came from — and under
    /// the wrong hiker's name.
    ///
    /// What arrives here has already been filtered for this hiker — see
    /// ``CommunityHikeView/visible(_:)`` — so a blocked contributor's
    /// photographs and a set a reviewer has taken down never reach it.
    @MainActor
    private static func attachContributedPhotos(
        of detail: CommunityHikeDetail,
        to hike: Hike,
        store: HikePhotoStore,
        libraryWriter: any PhotoLibraryWriting,
        save: (ModelContext) throws -> Void
    ) async {
        for contribution in detail.contributions {
            guard contribution.isConsistent else {
                logger.error(
                    """
                    Imported \(detail.listing.id, privacy: .public) without a \
                    contributed set: \(contribution.photoPins.count) pins for \
                    \(contribution.photoFileURLs.count) files.
                    """
                )
                continue
            }
            await attachSet(
                zip(contribution.photoPins, contribution.photoFileURLs),
                // No places: a contributor's pictures are not theirs to file
                // under the author's places, whatever their pins claim.
                stampedAs: Stamp(
                    listingID: detail.listing.id,
                    authorName: contribution.credit,
                    places: [:]
                ),
                to: hike,
                store: store,
                libraryWriter: libraryWriter,
                save: save
            )
        }
    }

    /// How a copied photograph is stamped: the listing it came from, and who
    /// took it where that is somebody other than the hike's own author.
    private struct Stamp {
        let listingID: String
        /// `nil` for the walk's own photographs, whose credit is the hike's
        /// ``Hike/importedAuthorName``, and for a contributor who asked for
        /// none — which is the honest answer rather than a lost one.
        let authorName: String?
        /// The author's place ids, to the ids this hike's copies were given.
        /// A photograph whose pin names a place not in here is filed under
        /// none.
        let places: [UUID: UUID]
    }

    /// Copies one paired set of pins and files onto the hike, whoever took
    /// them.
    ///
    /// The one loop both halves above run, because what differs between a
    /// submission's photographs and a contribution's is the stamp and nothing
    /// else — the reading, the abandonment check and every other argument are
    /// the same work on the same files, and the two spellings of it were one
    /// edit apart from disagreeing about which.
    ///
    /// **Paired by the caller**, which is also where the pairing is checked:
    /// `zip` truncates silently, and a photograph pinned to another
    /// photograph's coordinate is the one failure nothing downstream could
    /// notice, so both callers refuse a set whose two arrays disagree before
    /// reaching here.
    ///
    /// **The hike is re-checked every picture.** It can be swiped away while a
    /// dozen are being copied — the list is one tap behind this screen — and
    /// writing to a detached row persists nothing, leaving files nothing
    /// claims. That ends the import rather than skipping one photograph, which
    /// is why it returns.
    @MainActor
    private static func attachSet(
        _ photos: some Sequence<(CommunityPhotoPin, URL)>,
        stampedAs stamp: Stamp,
        to hike: Hike,
        store: HikePhotoStore,
        libraryWriter: any PhotoLibraryWriting,
        save: (ModelContext) throws -> Void
    ) async {
        for (pin, url) in photos {
            guard let data = await readFile(at: url) else { continue }
            guard hike.isAttached else { return }
            await HikePhotoImport.add(
                data,
                to: hike,
                coordinate: pin.coordinate,
                // Never the hiker's setting — see this file's header.
                savesToPhotoLibrary: false,
                capturedAt: pin.capturedAt,
                // Stamped as somebody else's, which is the one thing that
                // keeps it out of a contribution back to the same trail: the
                // saved hike is exactly the one the *Add Photos* form opens
                // on, and without this it opened pre-selected with the
                // author's own pictures. See ``HikePhoto/importedFromListingID``.
                importedFromListingID: stamp.listingID,
                importedAuthorName: stamp.authorName,
                placeID: pin.placeID.flatMap { stamp.places[$0] },
                store: store,
                libraryWriter: libraryWriter,
                save: save
            )
        }
    }

    /// Reads a downloaded file off the main actor.
    ///
    /// `@concurrent` rather than a bare `nonisolated async`, which under
    /// `SWIFT_APPROACHABLE_CONCURRENCY` would run on the main-actor caller's
    /// own executor and put a multi-megabyte read on the thread drawing the
    /// progress view.
    @concurrent
    private static func readFile(at url: URL) async -> Data? {
        try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// The route's own length, summed the way ``GPXImport`` sums an imported
    /// file's — see this file's header for why the listing's figure is not
    /// trusted.
    static func routeLength(of route: [RouteCoordinate]) -> Double {
        guard route.count >= 2 else { return 0 }
        var total = 0.0
        for index in 1..<route.count {
            total += RouteGeometry.distanceMeters(
                from: route[index - 1].clCoordinate,
                to: route[index].clCoordinate
            )
        }
        return total
    }
}
