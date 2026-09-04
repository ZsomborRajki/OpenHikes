//
//  TileOwnership.swift
//  OpenHikes
//
//  Which cached tiles a hike lays claim to.
//
//  Tile cache keys are purely geographic — `providerID/z/x/y`, with no
//  hike identity in them — so two hikes in the same area claim literally the
//  same keys, and at low zoom (where one tile spans a region) *every* hike in
//  the same country claims the same handful. That makes "delete this hike's
//  tiles" the wrong question: the right one is which of its tiles nothing
//  else still needs, which is what this type exists to answer.
//
//  A plain value snapshot of a `Hike`, taken on the main actor, precisely so
//  the expensive part can run off it: `tileKeys()` does O(tile budget) trig
//  per download record, and SwiftData models can't leave the main actor
//  anyway.
//

import CoreLocation
import Foundation

nonisolated struct TileOwnership: Sendable {
    private let route: [RouteCoordinate]
    private let offlineDownloads: [OfflineDownloadRecord]
    private let autoSavedTileKeys: [String]

    /// Snapshots `hike`'s claims. Call `AutoSaveController.flushPendingKeys()`
    /// first if tiles may have been auto-saved since the last drain — this
    /// reads the manifest, and anything not yet folded into it is invisible
    /// here.
    init(_ hike: Hike) {
        route = hike.route
        offlineDownloads = hike.offlineDownloads
        autoSavedTileKeys = hike.autoSavedTileKeys
    }

    /// Whether this hike has any stored tiles at all — the cheap check that
    /// keeps `tileKeys()`'s real work off hikes that were never saved offline.
    var hasStoredTiles: Bool { !offlineDownloads.isEmpty || !autoSavedTileKeys.isEmpty }

    /// Every cache key this hike claims: the tiles each bulk download would
    /// have covered, plus the ones auto-saved while it was browsed.
    ///
    /// Recomputed from the route rather than stored, matching how the
    /// downloader enumerates them in the first place.
    func tileKeys() throws(CancellationError) -> Set<String> {
        guard hasStoredTiles else { return [] }
        let coordinates = route.map(\.clCoordinate)
        return try Set(
            OfflineTileDownloader.storedTileKeys(
                route: coordinates,
                offlineDownloads: offlineDownloads
            )
        ).union(autoSavedTileKeys)
    }

    /// The keys `self` claims that none of `others` do — i.e. exactly what can
    /// be deleted along with this hike without quietly stripping offline
    /// coverage from a hike that's still around and still lists it.
    ///
    /// Cancellation propagates rather than degrading: a half-enumerated
    /// survivor would under-report its claims, and the caller would delete
    /// tiles that hike still needs. Throwing means nothing is deleted instead.
    func exclusiveTileKeys(
        against others: [Self]
    ) throws(CancellationError) -> Set<String> {
        var keys = try tileKeys()
        for other in others where other.hasStoredTiles {
            keys.subtract(try other.tileKeys())
            // Overlapping trails can account for everything; stop paying for
            // the remaining route enumerations once nothing is left to delete.
            if keys.isEmpty { break }
        }
        return keys
    }
}

/// Snapshots one hike's tile claims and every surviving claim in one
/// main-actor pass, then answers the expensive deletion question off-main.
///
/// The third site that spends a tile claim set, beside
/// ``OpenHikesModel/trimTileCache(_:limit:fetchingHikes:)`` and
/// ``OfflineStorageActions``, and it follows their rule: a claim that could
/// not be read refuses the plan rather than shortening it. A survivor missing
/// from `survivors` is not a hike that claims nothing — it is a hike whose
/// downloaded map is about to be deleted while its manifest goes on listing
/// it, with nothing left to re-download it and nothing able to see the hole.
nonisolated struct StoredTileDeletionPlan: Sendable {
    private let doomed: TileOwnership
    private let survivors: [TileOwnership]

    /// Snapshots `hike`'s claim and every surviving claim, or `nil` if either
    /// read failed.
    ///
    /// Built through ``Hike/tileClaim()`` rather than the ``Hike/hasStoredTiles``
    /// pre-filter, which reads through ``Hike/localState`` and so answers
    /// `false` for a hike whose sidecar fetch *threw* — indistinguishable,
    /// once it is absent from `survivors`, from one that genuinely holds no
    /// tiles.
    ///
    /// `@MainActor` where the rest of this type is `nonisolated`: reading a
    /// claim is reading SwiftData, which is what the snapshot exists to get
    /// out of the way before the expensive part runs off-main.
    @MainActor
    init?(removing hike: Hike, among hikes: [Hike]) {
        self.init(
            // A doomed hike with no sidecar row claims nothing, which is a
            // plan that deletes nothing rather than a refusal; the throwing
            // read above it is what tells that apart from a failure.
            doomedClaim: { try hike.tileClaim() ?? TileOwnership(hike) },
            survivingClaims: { try TileOwnership.claims(of: hikes.filter { $0.id != hike.id }) }
        )
    }

    /// The rule itself, with both claim reads handed in.
    ///
    /// Closure-driven for the reason ``OpenHikesModel/trimTileCache(_:limit:fetchingHikes:)``
    /// is: the branch that matters is the failing one, and nothing makes a
    /// `ModelContext` throw on demand — a fetch against a schema it does not
    /// know returns an empty result rather than an error. Without this seam
    /// the refusal below could be rewritten as `try?` with a fallback and
    /// every test in the bundle would still pass, while a delete stripped a
    /// neighbouring hike's offline map.
    init?(
        doomedClaim: () throws -> TileOwnership,
        survivingClaims: () throws -> [TileOwnership]
    ) {
        guard let claim = try? doomedClaim(),
              let claims = try? survivingClaims() else { return nil }
        doomed = claim
        survivors = claims
    }

    /// The plan a caller has already read both claims for.
    ///
    /// The failable initialisers above exist to *refuse* a plan whose claim
    /// set could not be established. A caller that established it itself
    /// before writing anything — which is the order ``StoredTileDeletion``
    /// works in, so that a refusal costs the walker nothing — has nothing
    /// left to refuse, and a second optional there would be a `nil` branch no
    /// test could reach.
    init(doomed: TileOwnership, survivors: [TileOwnership]) {
        self.doomed = doomed
        self.survivors = survivors
    }

    func exclusiveTileKeys() throws(CancellationError) -> Set<String> {
        try doomed.exclusiveTileKeys(against: survivors)
    }

    /// Enumerates and frees this plan's exclusive tiles on the concurrent
    /// executor. `@concurrent` rather than a detached task: a `Task` started
    /// from the main actor inherits its isolation, and both the enumeration
    /// and the file removal assert they are off the main thread.
    @concurrent
    func removeExclusiveTiles(from cache: TileCache) async {
        let keys: Set<String>
        do throws(CancellationError) {
            keys = try exclusiveTileKeys()
        } catch {
            // Cancelled mid-enumeration: a partial survivor set under-reports
            // what is still claimed, so delete nothing rather than strip a
            // surviving hike's offline coverage.
            return
        }
        guard !keys.isEmpty else { return }
        cache.removeTiles(forKeys: Array(keys))
    }
}

extension TileOwnership {
    /// The claims of every hike in `hikes` that is holding tiles on this
    /// device — refusing rather than under-reporting when one of them cannot
    /// be read.
    ///
    /// A claim set is only ever spent whole, by something whose job is
    /// removing what is not in it, so the difference between a short set and a
    /// complete one is the difference between freeing browsing residue and
    /// deleting the map a walker downloaded for a valley with no signal. Both
    /// ways a hike can go missing therefore arrive here as an error instead of
    /// as a shorter array: the fetch that produced `hikes`, and the sidecar
    /// read behind ``Hike/tileClaim()``.
    static func claims(of hikes: [Hike]) throws -> [Self] {
        try hikes.compactMap { try $0.tileClaim() }
    }
}

extension Hike {
    /// This hike's tile claim, or `nil` if it holds no tiles on this device.
    ///
    /// Throws where ``hasStoredTiles`` would merely answer `false`. That
    /// property reads through ``localState``, which swallows a failed sidecar
    /// fetch, and a hike answering "no tiles" because its record could not be
    /// read is — to a claim set — indistinguishable from one that genuinely
    /// holds none. Resolving the record here is what tells the two apart.
    func tileClaim() throws -> TileOwnership? {
        guard try resolveLocalState() != nil, hasStoredTiles else { return nil }
        return TileOwnership(self)
    }

    /// Whether this hike has any stored tiles — answered from two small
    /// arrays, without touching `route`.
    ///
    /// The cheap half of ``tileClaim()``, and the short-circuit a delete opens
    /// with: it has to consider every *other* hike, and faulting in a few
    /// hundred full routes to discover that none of them ever saved a tile is
    /// work worth not doing on the main actor. Not a filter anything builds a
    /// claim set with — see ``tileClaim()`` for why the difference matters.
    var hasStoredTiles: Bool { !offlineDownloads.isEmpty || !autoSavedTileKeys.isEmpty }
}
