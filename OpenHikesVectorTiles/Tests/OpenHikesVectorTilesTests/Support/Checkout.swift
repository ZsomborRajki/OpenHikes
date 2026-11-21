//
//  Checkout.swift
//  OpenHikesVectorTilesTests
//
//  The checkout these suites were compiled from, for the suites that hold
//  the renderer to a file beside it: the extras' schema the tile server's
//  archive is built by, and the icon catalog as it lies on disk.
//

import Foundation

enum Checkout {
    /// The repository's root: this file is four folders inside it.
    static var root: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<foldersToRoot { url.deleteLastPathComponent() }
        return url
    }

    /// The schema `Scripts/vector-extras.sh` builds the extras by.
    static var extrasSchema: URL { root.appending(path: "Scripts/lib/vector-extras.yml") }

    /// The package's resources, as sources.
    static var resources: URL {
        root.appending(path: "OpenHikesVectorTiles/Sources/OpenHikesVectorTiles/Resources")
    }

    /// `Support`, `OpenHikesVectorTilesTests`, `Tests`, `OpenHikesVectorTiles`,
    /// and the file itself.
    private static let foldersToRoot = 5
}
