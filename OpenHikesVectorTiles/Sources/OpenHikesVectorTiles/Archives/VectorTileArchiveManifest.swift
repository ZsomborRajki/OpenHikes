//
//  VectorTileArchiveManifest.swift
//  OpenHikesVectorTiles
//
//  Which archives on a tile server the map is drawn from: the basemaps the
//  server holds, each with the Protomaps schema of its layers, and the
//  extras, each with the generation of theirs. The server keeps one at its
//  root, `manifest.json`. A host bundles the one of its day, which is what it
//  draws from until it has read the server's. OpenHikes' is
//  `VectorTileArchiveManifest.json` in the app, which
//  `Scripts/vector-archives.sh publish` puts on the server.
//
//  An archive goes up under a new name and is never replaced in place: the
//  server's cache keeps a tile for a day, so an archive replaced in place
//  would be drawn from two builds at once. A new build is therefore a new
//  name at the head of its list, and every installed app that can draw it
//  moves to it (`VectorTileArchives`). One it cannot draw — a basemap of
//  another schema, extras of a later generation — it passes over for the
//  next one listed, which the server keeps for as long as builds that read
//  only that one are about.
//

import Foundation

public struct VectorTileArchiveManifest: Codable, Equatable, Sendable {
    /// The format this reader takes. A manifest of another is not read.
    public static let currentVersion = 1
    /// The newest layout of the extras this build draws
    /// (``VectorTileSchema/extrasGeneration``). It draws every earlier one
    /// too, which only lacks what later ones added. Extras an older build
    /// would draw wrong go up as the next generation.
    static let extrasGeneration = VectorTileSchema.extrasGeneration

    public var version: Int
    /// Raised by every publish, so that of two manifests the newer is known:
    /// the server's over the bundled one, unless a build bundles a newer one
    /// than the server has been given.
    public var revision: Int
    /// Newest first: the first this build can draw is the one it draws.
    public var basemaps: [Basemap]
    /// Newest first, as the basemaps are.
    public var extras: [Extras]

    public init(version: Int, revision: Int, basemaps: [Basemap], extras: [Extras]) {
        self.version = version
        self.revision = revision
        self.basemaps = basemaps
        self.extras = extras
    }

    public struct Basemap: Codable, Equatable, Sendable {
        /// The archive's name on the server: its object key, without
        /// `.pmtiles`.
        public var name: String
        /// The generation of the Protomaps basemap's layers it holds.
        public var schema: Int
        /// The deepest zoom it holds.
        public var maximumZoom: Int

        public init(name: String, schema: Int, maximumZoom: Int) {
            self.name = name
            self.schema = schema
            self.maximumZoom = maximumZoom
        }

        /// Whether this build draws it: of the schema ``VectorTileRasterizer``
        /// draws, under a name the server serves.
        var isDrawn: Bool {
            schema == VectorTileSchema.basemap
                && VectorTileArchiveManifest.isArchiveName(name)
                && VectorTileArchiveManifest.zooms.contains(maximumZoom)
        }
    }

    public struct Extras: Codable, Equatable, Sendable {
        public var name: String
        public var generation: Int
        /// The widest zoom the map asks it for.
        public var minimumZoom: Int

        public init(name: String, generation: Int, minimumZoom: Int) {
            self.name = name
            self.generation = generation
            self.minimumZoom = minimumZoom
        }

        /// Whether this build draws them: of a generation it knows, under a
        /// name the server serves.
        var isDrawn: Bool {
            (1...VectorTileArchiveManifest.extrasGeneration).contains(generation)
                && VectorTileArchiveManifest.isArchiveName(name)
                && VectorTileArchiveManifest.zooms.contains(minimumZoom)
        }
    }

    /// What this build draws from `server`: the first basemap it draws, with
    /// the first extras it draws, if any are listed. `nil` for a manifest of
    /// another version, or one with no such basemap.
    public func source(on server: URL) -> VectorTileSource? {
        guard version == Self.currentVersion, let basemap = basemaps.first(where: \.isDrawn) else { return nil }
        let drawnExtras = extras.first(where: \.isDrawn)
        return VectorTileSource(
            archiveURL: server.appending(path: basemap.name),
            maximumZ: basemap.maximumZoom,
            extras: drawnExtras.map { .init(archiveURL: server.appending(path: $0.name), minimumZ: $0.minimumZoom) }
        )
    }

    /// The zooms a slippy-map archive can hold.
    private static let zooms = 0...30

    /// Whether `name` is one the tile server's route serves an archive
    /// under, and no more: lower-case letters, digits and single hyphens, so
    /// that a name off the network names an archive on that server and
    /// nothing else.
    static func isArchiveName(_ name: String) -> Bool {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        return (1...64).contains(name.count)
            && parts.allSatisfy { part in
                !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber) }
            }
    }
}
