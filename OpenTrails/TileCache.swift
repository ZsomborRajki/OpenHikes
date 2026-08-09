//
//  TileCache.swift
//  OpenTrails
//
//  Two-tier (memory + disk) tile cache with async network loading.
//

import Foundation
import MapKit
import Network
import os

#if canImport(UIKit)
import UIKit
typealias TileImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias TileImage = NSImage
#endif

/// Receives connectivity callbacks from ``TileCache``, always on the main queue.
/// Renderers adopt this to retry tiles once the network is back.
protocol TileCacheObserver: AnyObject {
    func tileCacheDidReconnect()
}

/// Caches map tiles in memory (`NSCache`) and on disk, fetching missing tiles
/// over the network. Safe to call from any thread/task.
nonisolated final class TileCache: @unchecked Sendable {
    static let shared = TileCache()

    private static let logger = Logger(subsystem: "OpenTrails", category: "TileRequests")

    private let memory = NSCache<NSString, TileImage>()
    private let directory: URL
    /// Durable (non-purgeable) store for tiles the user has explicitly chosen to
    /// keep, e.g. via ``AutoSaveTileStore``. Unlike `directory`, this lives under
    /// Application Support, so it survives OS storage-pressure cache eviction.
    private let durableDirectory: URL
    private let session: URLSession

    /// Live network reachability, updated by `NWPathMonitor`. Tile loads short-
    /// circuit when this is `false`, so an offline app doesn't fire (and log) a
    /// doomed request for every visible tile.
    private let online = OSAllocatedUnfairLock(initialState: true)
    var isOnline: Bool { online.withLock { $0 } }

    /// Weakly-held reconnect listeners. A boxed array keeps the reference weak so
    /// a deallocated renderer drops out without needing to unregister.
    private struct WeakObserver { weak var value: TileCacheObserver? }
    private let observers = OSAllocatedUnfairLock(initialState: [WeakObserver]())

    private let monitor = NWPathMonitor()

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("OSMTiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        durableDirectory = support.appendingPathComponent("OSMTilesSaved", isDirectory: true)
        try? FileManager.default.createDirectory(at: durableDirectory, withIntermediateDirectories: true)

        let config = URLSessionConfiguration.default
        // OSM's tile usage policy requires an identifying User-Agent.
        config.httpAdditionalHeaders = ["User-Agent": "OpenTrails/1.0 (iOS; hiking app)"]
        // Don't sit in a retry queue when offline — fail fast so the caller can
        // record the miss and stop asking until we're back online.
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)

        memory.countLimit = 1_024

        startMonitoringNetwork()
    }

    /// Tracks reachability and, on each offline→online transition, notifies
    /// renderers so they clear failed tiles and try again.
    private func startMonitoringNetwork() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            let wasOnline = self.online.withLock { previous in
                let old = previous
                previous = satisfied
                return old
            }
            if satisfied && !wasOnline { self.notifyReconnect() }
        }
        monitor.start(queue: DispatchQueue(label: "TileCache.network"))
    }

    /// Registers a reconnect listener; held weakly, so no explicit removal is
    /// required (though ``removeObserver(_:)`` is available).
    func addObserver(_ observer: TileCacheObserver) {
        observers.withLock { boxes in
            boxes.removeAll { $0.value == nil }
            boxes.append(WeakObserver(value: observer))
        }
    }

    func removeObserver(_ observer: TileCacheObserver) {
        observers.withLock { boxes in
            boxes.removeAll { $0.value == nil || $0.value === observer }
        }
    }

    private func notifyReconnect() {
        // MKOverlayRenderer.setNeedsDisplay must run on the main thread; the path
        // handler fires on a background queue, so hop first, then read observers
        // there (keeps the non-Sendable listeners off the queue boundary).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let live = self.observers.withLock { boxes -> [TileCacheObserver] in
                boxes.removeAll { $0.value == nil }
                return boxes.compactMap(\.value)
            }
            live.forEach { $0.tileCacheDidReconnect() }
        }
    }

    /// Fast, synchronous memory-only lookup — safe to call from the render loop.
    func memoryImage(forKey key: String) -> TileImage? {
        memory.object(forKey: key as NSString)
    }

    /// Loads a tile, checking memory, then disk (ephemeral, then durable), then
    /// the network, and populating the faster tiers as it goes.
    @discardableResult
    func loadTile(forKey key: String, url: URL) async -> TileImage? {
        if let cached = memory.object(forKey: key as NSString) { return cached }

        let name = diskName(for: key)

        if let data = try? Data(contentsOf: directory.appendingPathComponent(name)), let image = TileImage(data: data) {
            memory.setObject(image, forKey: key as NSString)
            return image
        }

        if let data = try? Data(contentsOf: durableDirectory.appendingPathComponent(name)), let image = TileImage(data: data) {
            memory.setObject(image, forKey: key as NSString)
            return image
        }

        // Offline: the tile isn't cached and the network is gone. Return without
        // requesting so we don't spam failing loads for every visible tile.
        guard isOnline else {
            #if DEBUG
            Self.logger.debug("Skipped tile \(key, privacy: .public): offline")
            #endif
            return nil
        }

        #if DEBUG
        Self.logger.debug("Requesting tile \(key, privacy: .public) from \(url.absoluteString, privacy: .public)")
        #endif

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                #if DEBUG
                Self.logger.error("Tile \(key, privacy: .public): response was not HTTP")
                #endif
                return nil
            }
            guard (200..<300).contains(http.statusCode) else {
                #if DEBUG
                Self.logger.error("Tile \(key, privacy: .public) failed: HTTP \(http.statusCode, privacy: .public) (\(data.count, privacy: .public) bytes) from \(url.absoluteString, privacy: .public)")
                #endif
                return nil
            }
            guard let image = TileImage(data: data) else {
                #if DEBUG
                Self.logger.error("Tile \(key, privacy: .public) failed: undecodable response (\(data.count, privacy: .public) bytes, HTTP \(http.statusCode, privacy: .public), content-type \(http.value(forHTTPHeaderField: "Content-Type") ?? "unknown", privacy: .public))")
                #endif
                return nil
            }

            try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
            memory.setObject(image, forKey: key as NSString)
            #if DEBUG
            Self.logger.debug("Fetched tile \(key, privacy: .public) (\(data.count, privacy: .public) bytes)")
            #endif
            return image
        } catch {
            #if DEBUG
            Self.logger.error("Tile \(key, privacy: .public) request failed: \(error.localizedDescription, privacy: .public)")
            #endif
            return nil
        }
    }

    /// Writes pre-encoded tile bytes to the durable store, bypassing the network
    /// path entirely. Used by ``AutoSaveTileStore`` to persist tiles the user has
    /// already viewed (and so already fetched through ``loadTile(forKey:url:)``).
    func writeDurable(_ data: Data, forKey key: String) {
        try? data.write(to: durableDirectory.appendingPathComponent(diskName(for: key)), options: .atomic)
    }

    private func diskName(for key: String) -> String {
        key.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "@", with: "_")
    }

    // MARK: - Storage management

    /// Total bytes used by all cached tiles on disk (ephemeral + durable). Does
    /// file I/O — call off the main thread.
    func totalDiskBytes() -> Int64 {
        assertOffMainThread("totalDiskBytes() enumerates and stats every cached tile file — call it off the main thread")
        return (allTileFiles(in: directory) + allTileFiles(in: durableDirectory)).reduce(0) { $0 + fileSize($1) }
    }

    /// Bytes used by the tiles for `keys` that are actually present on disk
    /// (ephemeral or durable).
    func bytes(forKeys keys: [String]) -> Int64 {
        assertOffMainThread("bytes(forKeys:) stats two files per key — call it off the main thread")
        return keys.reduce(0) { total, key in
            let name = diskName(for: key)
            return total
                + fileSize(directory.appendingPathComponent(name))
                + fileSize(durableDirectory.appendingPathComponent(name))
        }
    }

    /// Removes every cached tile (memory + ephemeral disk + durable disk).
    func removeAllTiles() {
        assertOffMainThread("removeAllTiles() deletes every cached tile file synchronously — call it off the main thread")
        memory.removeAllObjects()
        for file in allTileFiles(in: directory) + allTileFiles(in: durableDirectory) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Removes the tiles for `keys` (memory + ephemeral disk + durable disk).
    /// Missing files are ignored.
    func removeTiles(forKeys keys: [String]) {
        assertOffMainThread("removeTiles(forKeys:) deletes two files per key synchronously — call it off the main thread")
        for key in keys {
            memory.removeObject(forKey: key as NSString)
            let name = diskName(for: key)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            try? FileManager.default.removeItem(at: durableDirectory.appendingPathComponent(name))
        }
    }

    private func allTileFiles(in directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
    }

    private func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
}
