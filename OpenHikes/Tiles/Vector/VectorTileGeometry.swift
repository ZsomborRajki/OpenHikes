//
//  VectorTileGeometry.swift
//  OpenHikes
//
//  A vector tile layer's grid placed on the picture drawn of it, and a
//  feature's commands read into the paths, lines, points and areas the
//  rasterizer and the names ask for.
//

import CoreGraphics

/// A layer's grid placed on the picture: pixel = grid × scale − offset.
nonisolated struct VectorTileGeometry {
    let scale: CGFloat
    let offset: CGPoint

    /// The grid of `source`, whose side is `extent`, placed so that the part
    /// of it `target` covers fills a ``VectorTileRasterizer/pixelSize`` picture.
    init(extent: Int, source: VectorTileAddress, target: VectorTileAddress) {
        let factor = CGFloat(1 << max(target.z - source.z, 0))
        let size = CGFloat(VectorTileRasterizer.pixelSize)
        scale = size * factor / CGFloat(extent)
        offset = CGPoint(
            x: (CGFloat(target.x) - CGFloat(source.x) * factor) * size,
            y: (CGFloat(target.y) - CGFloat(source.y) * factor) * size
        )
    }

    /// A line or polygon feature's path. Each ring of a polygon is its own
    /// subpath, so an even-odd fill leaves its holes empty.
    func path(of feature: MapboxVectorTile.Feature) -> CGPath {
        let path = CGMutablePath()
        walk(feature.geometry) { command, point in
            switch command {
            case .moveTo: path.move(to: point)
            case .lineTo: path.addLine(to: point)
            case .closePath: path.closeSubpath()
            }
        }
        return path
    }

    /// A line feature's parts, each the points of one run between moves. A
    /// line drawn before any move, which the spec forbids and a tile off the
    /// network may still hold, belongs to no part and is left out.
    func lines(of feature: MapboxVectorTile.Feature) -> [[CGPoint]] {
        var lines: [[CGPoint]] = []
        walk(feature.geometry) { command, point in
            switch command {
            case .moveTo: lines.append([point])
            case .lineTo: if !lines.isEmpty { lines[lines.count - 1].append(point) }
            case .closePath: break
            }
        }
        return lines
    }

    /// A polygon feature's area in the picture's square pixels: its outer
    /// rings' less its holes', which the spec winds the other way round.
    func area(of feature: MapboxVectorTile.Feature) -> CGFloat {
        var twice: CGFloat = 0
        var ringStart: CGPoint?
        var previous: CGPoint?
        walk(feature.geometry) { command, point in
            switch command {
            case .moveTo:
                ringStart = point
                previous = point
            case .lineTo:
                if let last = previous { twice += last.x * point.y - point.x * last.y }
                previous = point
            case .closePath:
                if let last = previous, let start = ringStart { twice += last.x * start.y - start.x * last.y }
                ringStart = nil
                previous = nil
            }
        }
        return abs(twice) / 2
    }

    /// A point feature's points.
    func points(of feature: MapboxVectorTile.Feature) -> [CGPoint] {
        var points: [CGPoint] = []
        walk(feature.geometry) { command, point in
            if command == .moveTo { points.append(point) }
        }
        return points
    }

    private enum Command: UInt32 {
        case moveTo = 1
        case lineTo = 2
        case closePath = 7
    }

    /// Commands as the spec encodes them: an id and a count in one integer,
    /// then for a move or a line that many zigzag-encoded steps from the
    /// cursor, which carries on across a feature's parts. Stops at the first
    /// command it cannot read, keeping what came before.
    private func walk(_ geometry: [UInt32], _ visit: (Command, CGPoint) -> Void) {
        var index = 0
        var cursorX = 0
        var cursorY = 0
        while index < geometry.count {
            guard let command = Command(rawValue: geometry[index] & 0x7) else { return }
            let count = Int(geometry[index] >> 3)
            index += 1
            if command == .closePath {
                visit(.closePath, .zero)
                continue
            }
            guard geometry.count - index >= count * 2 else { return }
            for _ in 0..<count {
                cursorX += Self.zigZag(geometry[index])
                cursorY += Self.zigZag(geometry[index + 1])
                index += 2
                visit(command, CGPoint(
                    x: CGFloat(cursorX) * scale - offset.x,
                    y: CGFloat(cursorY) * scale - offset.y
                ))
            }
        }
    }

    private static func zigZag(_ value: UInt32) -> Int {
        Int(value >> 1) ^ -Int(value & 1)
    }
}
