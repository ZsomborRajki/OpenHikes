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

    private let memory = NSCache<NSString, TileImage>()
    private let directory: URL
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

    /// Loads a tile, checking memory, then disk, then the network, and
    /// populating the faster tiers as it goes.
    @discardableResult
    func loadTile(forKey key: String, url: URL) async -> TileImage? {
        if let cached = memory.object(forKey: key as NSString) { return cached }

        let file = directory.appendingPathComponent(diskName(for: key))
        if let data = try? Data(contentsOf: file), let image = TileImage(data: data) {
            memory.setObject(image, forKey: key as NSString)
            return image
        }

        // Offline: the tile isn't cached and the network is gone. Return without
        // requesting so we don't spam failing loads for every visible tile.
        guard isOnline else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard
                let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                let image = TileImage(data: data)
            else { return nil }

            try? data.write(to: file, options: .atomic)
            memory.setObject(image, forKey: key as NSString)
            return image
        } catch {
            return nil
        }
    }

    private func diskName(for key: String) -> String {
        key.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "@", with: "_")
    }

    // MARK: - Storage management

    /// Total bytes used by all cached tiles on disk. Does file I/O — call off the
    /// main thread.
    func totalDiskBytes() -> Int64 {
        allTileFiles().reduce(0) { $0 + fileSize($1) }
    }

    /// Bytes used by the tiles for `keys` that are actually present on disk.
    func bytes(forKeys keys: [String]) -> Int64 {
        keys.reduce(0) { $0 + fileSize(directory.appendingPathComponent(diskName(for: $1))) }
    }

    /// Removes every cached tile (memory + disk).
    func removeAllTiles() {
        memory.removeAllObjects()
        for file in allTileFiles() { try? FileManager.default.removeItem(at: file) }
    }

    /// Removes the tiles for `keys` (memory + disk). Missing files are ignored.
    func removeTiles(forKeys keys: [String]) {
        for key in keys {
            memory.removeObject(forKey: key as NSString)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(diskName(for: key)))
        }
    }

    private func allTileFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
    }

    private func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
}
