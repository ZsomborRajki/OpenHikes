//
//  AutoSaveTileStore.swift
//  OpenTrails
//
//  Passively persists tiles for the one hike currently being auto-saved, as a
//  side effect of tiles MapKit already fetched to draw on screen — no bulk
//  enumeration, no extra network requests. This is how providers like OSM
//  (which disallow automated bulk downloading) save anything at all, and it
//  doubles as a gap-filler for bulk-download-capable providers: any tile the
//  bulk pass missed still gets saved the moment it's actually browsed.
//

import Foundation
import CoreLocation
import ImageIO
import UniformTypeIdentifiers
import os

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Thread-safe singleton bridging the (background) tile-load path to the one
/// hike the user currently has auto-save turned on for. Safe to call from any
/// thread/task, mirroring ``TileCache``.
nonisolated final class AutoSaveTileStore: @unchecked Sendable {
    static let shared = AutoSaveTileStore()

    private static let logger = Logger(subsystem: "OpenTrails", category: "AutoSaveTiles")

    /// Soft per-hike cap. Smaller than the bulk downloader's budget (4,000)
    /// since this accrues silently across many casual sessions rather than one
    /// deliberate action.
    static let tileCap = 3_000
    /// How far past the route's bounding box a tile is still fair game to save.
    static let corridorBufferMeters: CLLocationDistance = 1_500
    static let heicQuality: CGFloat = 0.8

    private struct ActiveHike {
        let id: UUID
        let corridor: TileCorridor
        /// Every key already known to belong to this hike (loaded from its saved
        /// manifest, plus anything persisted so far this session) — the dedupe +
        /// cap-counting set.
        var knownKeys: Set<String>
        /// Subset of `knownKeys` persisted this session but not yet drained back
        /// into the `Hike`'s SwiftData manifest.
        var pendingKeys: Set<String>
    }

    private let state = OSAllocatedUnfairLock<ActiveHike?>(initialState: nil)

    /// Makes `hikeID` the active auto-save target. Replaces any previously
    /// active hike.
    func setActiveHike(id: UUID, route: [CLLocationCoordinate2D], knownKeys: Set<String>) {
        let corridor = TileCorridor(route: route, bufferMeters: Self.corridorBufferMeters)
        state.withLock { $0 = ActiveHike(id: id, corridor: corridor, knownKeys: knownKeys, pendingKeys: []) }
    }

    /// Stops auto-saving — no active hike means `considerPersisting` is a no-op.
    func clearActiveHike() {
        state.withLock { $0 = nil }
    }

    func isCapReached(for hikeID: UUID) -> Bool {
        state.withLock { state in
            guard let state, state.id == hikeID else { return false }
            return state.knownKeys.count >= Self.tileCap
        }
    }

    /// Called after a tile has already been resolved for on-screen display
    /// (memory/disk/network hit alike). No-ops unless a hike is active, the
    /// tile falls in its corridor, it's under the cap, and it isn't already
    /// saved — otherwise HEIC-encodes and durably writes it.
    func considerPersisting(key: String, z: Int, x: Int, y: Int, image: TileImage) {
        assertOffMainThread("considerPersisting does HEIC encoding and a durable disk write — call it off the main thread")
        let shouldPersist = state.withLock { state -> Bool in
            guard var hike = state else { return false }
            defer { state = hike }
            guard
                hike.knownKeys.count < Self.tileCap,
                !hike.knownKeys.contains(key),
                hike.corridor.overlaps(z: z, x: x, y: y)    
            else { return false }
            hike.knownKeys.insert(key)
            hike.pendingKeys.insert(key)
            return true
        }
        guard shouldPersist else { return }
        guard let data = image.encodedForDurableStorage(quality: Self.heicQuality) else { return }
        TileCache.shared.writeDurable(data, forKey: key)
        #if DEBUG
        Self.logger.debug("Auto-saved tile \(key, privacy: .public) (\(data.count, privacy: .public) bytes)")
        #endif
    }

    /// Main-actor bookkeeping hook: returns and clears the keys persisted for
    /// `hikeID` since the last drain, so the caller can merge them into the
    /// hike's SwiftData manifest.
    func drainPendingKeys(for hikeID: UUID) -> Set<String> {
        state.withLock { state -> Set<String> in
            guard var hike = state, hike.id == hikeID else { return [] }
            let drained = hike.pendingKeys
            hike.pendingKeys.removeAll()
            state = hike
            return drained
        }
    }
}

/// `nonisolated`: called from ``AutoSaveTileStore``, which runs off the main actor.
private nonisolated extension TileImage {
    /// HEIC-encodes the tile for durable storage; falls back to PNG if HEIC
    /// encoding is unavailable (seen intermittently in the Simulator), so a
    /// tile is never silently dropped.
    func encodedForDurableStorage(quality: CGFloat) -> Data? {
        guard let cgImage = cgImageForEncoding else { return nil }
        if let heic = Self.encode(cgImage, type: .heic, quality: quality) { return heic }
        return Self.encode(cgImage, type: .png, quality: 1)
    }

    private static func encode(_ cgImage: CGImage, type: UTType, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            return nil
        }
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, cgImage, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private var cgImageForEncoding: CGImage? {
        #if canImport(UIKit)
        return cgImage
        #elseif canImport(AppKit)
        return cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }
}
