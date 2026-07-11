//
//  TileCache.swift
//  OpenTrails
//
//  Two-tier (memory + disk) tile cache with async network loading.
//

import Foundation
import MapKit

#if canImport(UIKit)
import UIKit
typealias TileImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias TileImage = NSImage
#endif

/// Caches map tiles in memory (`NSCache`) and on disk, fetching missing tiles
/// over the network. Safe to call from any thread/task.
nonisolated final class TileCache: @unchecked Sendable {
    static let shared = TileCache()

    private let memory = NSCache<NSString, TileImage>()
    private let directory: URL
    private let session: URLSession

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("OSMTiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let config = URLSessionConfiguration.default
        // OSM's tile usage policy requires an identifying User-Agent.
        config.httpAdditionalHeaders = ["User-Agent": "OpenTrails/1.0 (iOS; hiking app)"]
        session = URLSession(configuration: config)

        memory.countLimit = 1_024
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
}
