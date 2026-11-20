//
//  VectorTileSeasonalStretches.swift
//  OpenHikes
//
//  Which stretches of the basemap's waterways the vector extras say are not
//  always there. The basemap joins a stream's pieces whether or not each runs
//  all year, and the extras' `intermittent` layer gives only the pieces that
//  do not, so a waterway is parted where it runs along one of those lines:
//  that stretch is drawn broken, and the rest whole. A river a seasonal stream
//  crosses lies across the band its gaps are rubbed out over, not along it,
//  and so stays whole.
//
//  A waterway is judged a short piece at a time, as long as one dash and one
//  gap, since the basemap may run one straight line through where a stream
//  stops running all year. A piece runs along a seasonal line where both its
//  ends lie within that band, and its middle too, beside a piece of the line
//  running the same way. The two archives simplify a line apart, so
//  neither's points are the other's, but each lies within the band of the
//  other's line.
//

import CoreGraphics

nonisolated struct VectorTileSeasonalStretches {
    /// One piece of a seasonal line, and half the band its gaps are rubbed
    /// out over.
    private struct Segment {
        let start: CGPoint
        let end: CGPoint
        let reach: CGFloat

        var run: CGVector { CGVector(dx: end.x - start.x, dy: end.y - start.y) }

        func distance(to point: CGPoint) -> CGFloat {
            let line = run
            let length = line.dx * line.dx + line.dy * line.dy
            let along = length > 0
                ? min(max(((point.x - start.x) * line.dx + (point.y - start.y) * line.dy) / length, 0), 1)
                : 0
            return hypot(point.x - (start.x + along * line.dx), point.y - (start.y + along * line.dy))
        }

        /// Whether `other` runs within ``VectorTileSeasonalStretches/turn``
        /// of this piece, either way along it.
        func runs(as other: CGVector) -> Bool {
            let lengths = hypot(run.dx, run.dy) * hypot(other.dx, other.dy)
            let sine = abs(run.dx * other.dy - run.dy * other.dx)
            return lengths > 0 && sine <= VectorTileSeasonalStretches.turn * lengths
        }
    }

    private struct Cell: Hashable {
        let x: Int
        let y: Int
    }

    /// The sine of the widest angle a stretch may make with the seasonal
    /// line and still run along it: 30°.
    private static let turn: CGFloat = 0.5
    /// How many squares the pieces are filed in along each side of the
    /// archive's tile.
    private static let cellsAcross: CGFloat = 16

    /// How many pieces one straight line of a waterway is judged in at
    /// most, however long a tile off the network makes it.
    private static let mostPieces = 1024

    private let cells: [Cell: [Segment]]
    private let side: CGFloat
    private let piece: CGFloat
    private let bounds: CGRect

    /// - Parameters:
    ///   - lines: each seasonal line's parts in the picture's pixels, with
    ///     half the band its gaps are rubbed out over.
    ///   - frame: the archive's tile on the picture. A piece is filed only
    ///     within it and a square's width around it, which holds the buffer
    ///     the archive draws past its edge, so a tile off the network that
    ///     says otherwise costs no more than one that does not.
    ///   - piece: the length a waterway is judged in pieces of.
    ///   - bounds: the picture. A stretch that is nowhere near it is drawn
    ///     nowhere, and is never asked about.
    init(_ lines: [(parts: [[CGPoint]], reach: CGFloat)], frame: CGRect, piece: CGFloat, bounds: CGRect) {
        let square = frame.width / Self.cellsAcross
        let filed = (
            x: Self.index(frame.minX, square) - 1...Self.index(frame.maxX, square) + 1,
            y: Self.index(frame.minY, square) - 1...Self.index(frame.maxY, square) + 1
        )
        var found: [Cell: [Segment]] = [:]
        for (parts, reach) in lines {
            for part in parts {
                for (start, end) in zip(part, part.dropFirst()) {
                    let box = CGRect(origin: start, size: CGSize(width: end.x - start.x, height: end.y - start.y))
                        .standardized
                        .insetBy(dx: -reach, dy: -reach)
                    let xs = Self.index(box.minX, square)...Self.index(box.maxX, square)
                    let ys = Self.index(box.minY, square)...Self.index(box.maxY, square)
                    guard xs.overlaps(filed.x), ys.overlaps(filed.y) else { continue }
                    let segment = Segment(start: start, end: end, reach: reach)
                    for x in xs.clamped(to: filed.x) {
                        for y in ys.clamped(to: filed.y) {
                            found[Cell(x: x, y: y), default: []].append(segment)
                        }
                    }
                }
            }
        }
        cells = found
        side = square
        self.piece = piece
        self.bounds = bounds
    }

    /// `parts` divided into the stretches along a seasonal line and the
    /// rest, or `nil` where no stretch runs along one.
    func split(_ parts: [[CGPoint]]) -> (seasonal: CGPath, perennial: CGPath?)? {
        guard !cells.isEmpty else { return nil }
        let seasonal = CGMutablePath()
        let perennial = CGMutablePath()
        for part in parts {
            var current: CGMutablePath?
            for (start, end) in zip(part, part.dropFirst()) {
                for (from, to) in pieces(from: start, to: end) {
                    let path = runsAlong(from: from, to: to) ? seasonal : perennial
                    guard path !== current else { continue }
                    current?.addLine(to: from)
                    path.move(to: from)
                    current = path
                }
                current?.addLine(to: end)
            }
        }
        guard !seasonal.isEmpty else { return nil }
        return (seasonal, perennial.isEmpty ? nil : perennial)
    }

    /// The line from `start` to `end` in pieces of about ``piece``, or
    /// whole where it is nowhere near the picture.
    private func pieces(from start: CGPoint, to end: CGPoint) -> [(CGPoint, CGPoint)] {
        let run = CGVector(dx: end.x - start.x, dy: end.y - start.y)
        guard isNearPicture(start, run) else { return [(start, end)] }
        let count = min(max(Int((hypot(run.dx, run.dy) / piece).rounded(.up)), 1), Self.mostPieces)
        let points = (0...count).map { step in
            let along = CGFloat(step) / CGFloat(count)
            return CGPoint(x: start.x + along * run.dx, y: start.y + along * run.dy)
        }
        return Array(zip(points, points.dropFirst()))
    }

    private func runsAlong(from start: CGPoint, to end: CGPoint) -> Bool {
        let run = CGVector(dx: end.x - start.x, dy: end.y - start.y)
        guard isNearPicture(start, run) else { return false }
        let middle = CGPoint(x: start.x + run.dx / 2, y: start.y + run.dy / 2)
        return lies(start) && lies(end) && lies(middle, running: run)
    }

    private func isNearPicture(_ start: CGPoint, _ run: CGVector) -> Bool {
        CGRect(origin: start, size: CGSize(width: run.dx, height: run.dy)).standardized
            .insetBy(dx: -side, dy: -side)
            .intersects(bounds)
    }

    /// Whether `point` lies within the band of a seasonal line, beside a
    /// piece of it running as `run` does where one is given.
    private func lies(_ point: CGPoint, running run: CGVector? = nil) -> Bool {
        let cell = Cell(x: Self.index(point.x, side), y: Self.index(point.y, side))
        return cells[cell]?.contains { segment in
            segment.distance(to: point) <= segment.reach && (run.map(segment.runs(as:)) ?? true)
        } ?? false
    }

    private static func index(_ coordinate: CGFloat, _ side: CGFloat) -> Int {
        Int((coordinate / side).rounded(.down))
    }
}
