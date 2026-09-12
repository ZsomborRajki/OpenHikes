//
//  CommunityImport.swift
//  OpenHikes
//
//  Turning somebody else's published hike into one of this walker's own.
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
//  The imported copies never reach the walker's photo library. The library
//  mirror is an opt-in for photographs the walker *took*
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
//  wrong in the one place the walker could see it.
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
    /// - Parameter save: The commit seam, the same shape ``HikeImport`` takes
    ///   its own in.
    @MainActor
    static func importHike(
        _ detail: CommunityHikeDetail,
        into context: ModelContext,
        store: HikePhotoStore = .shared,
        libraryWriter: any PhotoLibraryWriting = PhotoLibraryWriter(),
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) async -> CommunityImportOutcome {
        guard detail.route.count >= 2 else { return .refused(.nothingToShare) }
        if let existing = existingImport(of: detail.listing.id, in: context) {
            return .alreadyImported(existing)
        }

        let listing = detail.listing
        let hike = Hike(
            title: listing.title,
            distanceMeters: routeLength(of: detail.route),
            date: listing.hikeDate,
            route: detail.route,
            trackDescription: detail.trackDescription
        )
        hike.importedFromListingID = listing.id
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
    /// By listing rather than by title: two different walkers can publish the
    /// same ridge under the same name, and they are two hikes.
    @MainActor
    static func existingImport(of listingID: String, in context: ModelContext) -> Hike? {
        var descriptor = FetchDescriptor<Hike>(
            predicate: #Predicate { $0.importedFromListingID == listingID }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Copies the downloaded photographs into this walker's own store.
    ///
    /// One at a time, and a failure costs its own picture rather than the
    /// import: the hike is already committed and already useful, and a single
    /// photograph that would not decode is not a reason to refuse a walk.
    @MainActor
    private static func attachPhotos(
        of detail: CommunityHikeDetail,
        to hike: Hike,
        store: HikePhotoStore,
        libraryWriter: any PhotoLibraryWriting,
        save: (ModelContext) throws -> Void
    ) async {
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
                // Never the walker's setting — see this file's header.
                savesToPhotoLibrary: false,
                capturedAt: pin.capturedAt,
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
