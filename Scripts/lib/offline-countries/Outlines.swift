//
//  Outlines.swift
//  offline-countries
//
//  Which tiles a country is: its Natural Earth outline (public domain, the
//  1:50m admin-0 shapes, keyed by `ISO_A2_EH`, which unlike `ISO_A2` names
//  France and Norway), the tiles whose middles fall inside it at the deepest
//  zoom, grown by a margin, and every tile above those.
//
//  The margin is there because a 1:50m border is a kilometre or two out in
//  the mountains, and a trail along a ridge is exactly where it runs: a
//  country is cut wider than its outline rather than ever narrower.
//

import Foundation

/// One country as `Scripts/lib/offline-countries.json` lists it.
struct CountryChoice: Decodable {
    let id: String
    /// West, south, east, north: only the polygons that reach into this box
    /// are kept, which is how France is mainland France and Corsica rather
    /// than French Guiana too.
    let clip: [Double]?
}

typealias Ring = [(lon: Double, lat: Double)]

enum Outlines {
    enum Failure: Error, CustomStringConvertible {
        case unreadable(String)
        case missing(String)

        var description: String {
            switch self {
            case let .unreadable(why): "the outlines are unreadable: \(why)"
            case let .missing(id): "the outlines have no country \(id)"
            }
        }
    }

    /// The outer ring of every polygon of `choice` in the GeoJSON.
    static func rings(of choice: CountryChoice, in features: [[String: Any]]) throws -> [Ring] {
        var rings: [Ring] = []
        for feature in features {
            guard let properties = feature["properties"] as? [String: Any],
                  properties["ISO_A2_EH"] as? String == choice.id,
                  let geometry = feature["geometry"] as? [String: Any],
                  let type = geometry["type"] as? String
            else { continue }
            let polygons: [Any]
            switch type {
            case "Polygon": polygons = [geometry["coordinates"] as Any]
            case "MultiPolygon": polygons = geometry["coordinates"] as? [Any] ?? []
            default: continue
            }
            for polygon in polygons {
                guard let outer = (polygon as? [Any])?.first as? [[Double]] else {
                    throw Failure.unreadable("a polygon of \(choice.id)")
                }
                let ring = outer.compactMap { $0.count >= 2 ? (lon: $0[0], lat: $0[1]) : nil }
                if let clip = choice.clip, clip.count == 4, !reaches(ring, into: clip) { continue }
                rings.append(ring)
            }
        }
        guard !rings.isEmpty else { throw Failure.missing(choice.id) }
        return rings
    }

    static func features(at url: URL) throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let features = (object as? [String: Any])?["features"] as? [[String: Any]] else {
            throw Failure.unreadable("no features")
        }
        return features
    }

    private static func reaches(_ ring: Ring, into box: [Double]) -> Bool {
        ring.contains { box[0]...box[2] ~= $0.lon && box[1]...box[3] ~= $0.lat }
    }

    /// `ring` with every vertex that moves it less than `tolerance` degrees
    /// dropped (Douglas–Peucker), rounded to four places, or `nil` when it
    /// shrinks to nothing: what the manifest carries for the map to draw.
    static func simplified(_ ring: Ring, tolerance: Double) -> [[Double]]? {
        guard ring.count > 3 else { return nil }
        var keep = [Bool](repeating: false, count: ring.count)
        keep[0] = true
        keep[ring.count - 1] = true
        var stack = [(0, ring.count - 1)]
        while let (first, last) = stack.popLast() {
            guard last > first + 1 else { continue }
            var farthest = first
            var distance = 0.0
            for index in first + 1..<last {
                let away = offset(of: ring[index], from: ring[first], to: ring[last])
                if away > distance {
                    distance = away
                    farthest = index
                }
            }
            if distance > tolerance {
                keep[farthest] = true
                stack.append((first, farthest))
                stack.append((farthest, last))
            }
        }
        let kept = ring.indices.filter { keep[$0] }.map { [rounded(ring[$0].lon), rounded(ring[$0].lat)] }
        return kept.count >= 4 ? kept : nil
    }

    private static func offset(
        of point: (lon: Double, lat: Double),
        from start: (lon: Double, lat: Double),
        to end: (lon: Double, lat: Double)
    ) -> Double {
        let (dx, dy) = (end.lon - start.lon, end.lat - start.lat)
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return hypot(point.lon - start.lon, point.lat - start.lat) }
        return abs(dy * point.lon - dx * point.lat + end.lon * start.lat - end.lat * start.lon) / length
    }

    private static func rounded(_ degrees: Double) -> Double {
        (degrees * 10_000).rounded() / 10_000
    }
}

/// The tiles of one country, as runs of columns along each row, for every
/// zoom down to the deepest.
struct TileCoverage {
    let maximumZoom: Int
    /// By zoom, then by row: the runs of columns, sorted and apart.
    private(set) var rows: [[Int: [ClosedRange<Int>]]]

    init(rings: [Ring], marginKilometers: Double, maximumZoom: Int) {
        self.maximumZoom = maximumZoom
        let size = 1 << maximumZoom
        var deepest: [Int: [ClosedRange<Int>]] = [:]
        let latitudes = rings.flatMap { $0.map(\.lat) }
        let (south, north) = (latitudes.min() ?? 0, latitudes.max() ?? 0)
        let (top, bottom) = (Self.row(of: north, size: size), Self.row(of: south, size: size))
        for row in top...bottom {
            let latitude = Self.latitude(ofRowMiddle: row, size: size)
            var crossings: [Double] = []
            for ring in rings {
                for (index, vertex) in ring.enumerated() {
                    let previous = ring[index == 0 ? ring.count - 1 : index - 1]
                    guard (previous.lat > latitude) != (vertex.lat > latitude) else { continue }
                    let along = (latitude - previous.lat) / (vertex.lat - previous.lat)
                    crossings.append(previous.lon + along * (vertex.lon - previous.lon))
                }
            }
            crossings.sort()
            for pair in stride(from: 0, to: crossings.count - 1, by: 2) {
                let first = Int((Self.column(of: crossings[pair], size: size) - 0.5).rounded(.up))
                let last = Int((Self.column(of: crossings[pair + 1], size: size) - 0.5).rounded(.down))
                if first <= last { deepest[row, default: []].append(first...last) }
            }
        }
        // Every vertex's own tile, so a sliver narrower than a tile, which no
        // tile's middle falls in, is still there.
        for vertex in rings.joined() {
            let column = Int(Self.column(of: vertex.lon, size: size).rounded(.down))
            deepest[Self.row(of: vertex.lat, size: size), default: []].append(column...column)
        }
        let middle = (south + north) / 2
        let tileKilometers = 40_075 * cos(middle * .pi / 180) / Double(size)
        let margin = Int((marginKilometers / tileKilometers).rounded(.up))
        deepest = Self.grown(deepest.mapValues(Self.merged), by: margin, size: size)
        var rows = [[Int: [ClosedRange<Int>]]](repeating: [:], count: maximumZoom + 1)
        rows[maximumZoom] = deepest
        for zoom in stride(from: maximumZoom - 1, through: 0, by: -1) {
            var above: [Int: [ClosedRange<Int>]] = [:]
            for (row, runs) in rows[zoom + 1] {
                above[row >> 1, default: []].append(contentsOf: runs.map { ($0.lowerBound >> 1)...($0.upperBound >> 1) })
            }
            rows[zoom] = above.mapValues(Self.merged)
        }
        self.rows = rows
    }

    func count(atZoom zoom: Int) -> Int {
        rows[zoom].values.joined().reduce(0) { $0 + $1.count }
    }

    /// Every tile from `minimumZoom` down, as `(z, x, y)`.
    func tiles(from minimumZoom: Int = 0) -> [(z: Int, x: Int, y: Int)] {
        var tiles: [(z: Int, x: Int, y: Int)] = []
        for zoom in minimumZoom...maximumZoom {
            for (row, runs) in rows[zoom] {
                for run in runs {
                    for column in run { tiles.append((zoom, column, row)) }
                }
            }
        }
        return tiles
    }

    /// West, south, east and north of the deepest tiles, in degrees.
    var bounds: (west: Double, south: Double, east: Double, north: Double) {
        let size = 1 << maximumZoom
        let deepest = rows[maximumZoom]
        let columns = deepest.values.joined()
        let west = columns.map(\.lowerBound).min() ?? 0
        let east = (columns.map(\.upperBound).max() ?? 0) + 1
        let top = deepest.keys.min() ?? 0
        let bottom = (deepest.keys.max() ?? 0) + 1
        return (
            Self.longitude(ofColumn: west, size: size),
            Self.latitude(ofRowEdge: bottom, size: size),
            Self.longitude(ofColumn: east, size: size),
            Self.latitude(ofRowEdge: top, size: size)
        )
    }

    private static func grown(
        _ rows: [Int: [ClosedRange<Int>]],
        by margin: Int,
        size: Int
    ) -> [Int: [ClosedRange<Int>]] {
        guard margin > 0 else { return rows }
        var grown: [Int: [ClosedRange<Int>]] = [:]
        for (row, runs) in rows {
            let wider = runs.map { max($0.lowerBound - margin, 0)...min($0.upperBound + margin, size - 1) }
            for target in max(row - margin, 0)...min(row + margin, size - 1) {
                grown[target, default: []].append(contentsOf: wider)
            }
        }
        return grown.mapValues(merged)
    }

    static func merged(_ runs: [ClosedRange<Int>]) -> [ClosedRange<Int>] {
        var merged: [ClosedRange<Int>] = []
        for run in runs.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, run.lowerBound <= last.upperBound + 1 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, run.upperBound)
            } else {
                merged.append(run)
            }
        }
        return merged
    }

    static func column(of longitude: Double, size: Int) -> Double {
        (longitude + 180) / 360 * Double(size)
    }

    static func row(of latitude: Double, size: Int) -> Int {
        let radians = latitude * .pi / 180
        let row = (1 - log(tan(radians) + 1 / cos(radians)) / .pi) / 2 * Double(size)
        return min(max(Int(row.rounded(.down)), 0), size - 1)
    }

    static func latitude(ofRowMiddle row: Int, size: Int) -> Double {
        latitude(ofRowEdge: row, size: size, plus: 0.5)
    }

    static func latitude(ofRowEdge row: Int, size: Int, plus fraction: Double = 0) -> Double {
        let y = (Double(row) + fraction) / Double(size)
        return atan(sinh(.pi * (1 - 2 * y))) * 180 / .pi
    }

    static func longitude(ofColumn column: Int, size: Int) -> Double {
        Double(column) / Double(size) * 360 - 180
    }
}
