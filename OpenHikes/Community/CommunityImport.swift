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
//  And the distance is recomputed from the route rather than copied from the
//  listing. The listing is a record a human creates by hand in the CloudKit
//  Console, so its numbers are typed; the route is what was actually uploaded.
//  Where the two disagree the route is the one that drew the line on the map,
//  and a hike whose stated length disagreed with its own polyline would be
//  wrong in the one place the hiker could see it.
//

import CoreLocation
import Foundation
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

        await attachPhotos(of: detail, to: hike, store: store, libraryWriter: libraryWriter, save: save)
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

    /// Copies the downloaded photographs into this hiker's own store.
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
    /// **Photographs other hikers contributed are deliberately not copied.**
    /// This reads ``CommunityHikeDetail/photoPins`` and
    /// ``CommunityHikeDetail/photoFileURLs``, which are the submission's own
    /// — ``CommunityHikeDetail/contributions`` sits beside them and is not
    /// read here. Saving a stranger's trail saves the walk its author
    /// published; what other people added to it is a thing that goes on
    /// happening on the shared listing, and a copy taken on the day of the
    /// import would be a snapshot that never grows, never shrinks when one is
    /// taken down, and carries no credit into a library that has nowhere to
    /// show one.
    @MainActor
    private static func attachPhotos(
        of detail: CommunityHikeDetail,
        to hike: Hike,
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
        for (pin, url) in zip(detail.photoPins, detail.photoFileURLs) {
            guard let data = await readFile(at: url) else { continue }
            // The hike can be swiped away while a dozen photographs are being
            // copied — the list is one tap behind this screen — and writing to
            // a detached row persists nothing, leaving files nothing claims.
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
                importedFromListingID: detail.listing.id,
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
