//
//  SquareCover.swift
//  offline-countries
//
//  Which squares of a grid of latitude and longitude an area's outline and a
//  margin round it reach: the geometry the day hikes (Trails.swift) and the
//  heights (Elevation.swift) are cut along, each on its own grid.
//
//  A grid here is `perDegree` squares to a degree each way, rows counted
//  north from the South Pole and columns east from the antimeridian, which
//  is how `TrailCellGrid` counts. `ElevationSquareGrid` counts its rows from
//  the North Pole, and turns them over itself (`ElevationSquares`).
//

import Foundation

struct SquareCover {
    /// Squares to a degree, each way.
    let perDegree: Int

    var rowCount: Int { 180 * perDegree }
    var columnCount: Int { 360 * perDegree }

    /// A square of the grid, rows from the South Pole.
    struct Square: Hashable, Comparable {
        var row: Int
        var column: Int

        static func < (lhs: Self, rhs: Self) -> Bool { (lhs.row, lhs.column) < (rhs.row, rhs.column) }
    }

    /// Kilometres in a degree, rounded down from the least a degree is, so a
    /// margin counted in squares is never short of the one asked for.
    private static let kilometersPerDegree = 110.0
    /// The smallest cosine a margin across longitudes is divided by, which
    /// only keeps the arithmetic finite: at a pole the margin takes in
    /// every column.
    private static let minimumCosine = 1e-9

    private var squareKilometers: Double { Self.kilometersPerDegree / Double(perDegree) }

    /// The square that holds a point.
    func square(containingLatitude latitude: Double, longitude: Double) -> Square {
        let row = Int(((latitude + 90) * Double(perDegree)).rounded(.down))
        let column = Int(((longitude + 180) * Double(perDegree)).rounded(.down))
        return Square(
            row: min(rowCount - 1, max(0, row)),
            column: (column % columnCount + columnCount) % columnCount
        )
    }

    /// Every square with its middle inside `rings`, every square an edge of
    /// them passes through, and every square within `marginKilometers` of
    /// those, row by row from the south.
    func squares(rings: [Ring], marginKilometers: Double) -> [Square] {
        let rows = grown(inside(rings), by: marginKilometers)
        return rows.keys.sorted().flatMap { row in
            (rows[row] ?? []).flatMap { run in run.map { Square(row: row, column: $0) } }
        }
    }

    /// The squares `rings` cover, as runs of columns along each row: those
    /// whose middles they hold, and those their edges pass through.
    func inside(_ rings: [Ring]) -> [Int: [ClosedRange<Int>]] {
        let perDegree = Double(self.perDegree)
        var runs: [Int: [ClosedRange<Int>]] = [:]
        let latitudes = rings.flatMap { $0.map(\.lat) }
        guard let south = latitudes.min(), let north = latitudes.max() else { return [:] }
        let first = square(containingLatitude: south, longitude: 0).row
        let last = square(containingLatitude: north, longitude: 0).row
        for row in first...last {
            let latitude = (Double(row) + 0.5) / perDegree - 90
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
                // The columns whose middles fall between the two crossings.
                let west = Int(((crossings[pair] + 180) * perDegree - 0.5).rounded(.up))
                let east = Int(((crossings[pair + 1] + 180) * perDegree - 0.5).rounded(.down))
                if west <= east { runs[row, default: []].append(west...east) }
            }
        }
        // Every square an edge passes through, its ends' included, so a
        // sliver no square's middle falls in is still there: a long edge
        // across a square whose middle lies outside, with neither end in it,
        // took in no square between its ends, and a margin grown from those
        // ends did not reach the middle of it (Svalbard's east coast in
        // Norway's heights, at 80.1° N, 32.1° E).
        for ring in rings where !ring.isEmpty {
            for (index, end) in ring.enumerated() {
                let start = ring[index == 0 ? ring.count - 1 : index - 1]
                for square in squares(from: start, to: end) {
                    runs[square.row, default: []].append(square.column...square.column)
                }
            }
        }
        return runs.mapValues(TileCoverage.merged)
    }

    /// The squares the straight edge from `start` to `end` passes through,
    /// in degrees as the grid is laid out, from the square of one end to the
    /// square of the other: a step across a square's side at a time, to
    /// whichever side the edge reaches first.
    func squares(from start: (lon: Double, lat: Double), to end: (lon: Double, lat: Double)) -> [Square] {
        let perDegree = Double(self.perDegree)
        let (x0, y0) = ((start.lon + 180) * perDegree, (start.lat + 90) * perDegree)
        let (x1, y1) = ((end.lon + 180) * perDegree, (end.lat + 90) * perDegree)
        guard x0.isFinite, y0.isFinite, x1.isFinite, y1.isFinite else { return [] }
        var x = Int(x0.rounded(.down))
        var y = Int(y0.rounded(.down))
        let (lastX, lastY) = (Int(x1.rounded(.down)), Int(y1.rounded(.down)))
        let (dx, dy) = (x1 - x0, y1 - y0)
        let (stepX, stepY) = (dx > 0 ? 1 : -1, dy > 0 ? 1 : -1)
        // How far along the edge, from 0 to 1, it next crosses a column's
        // side and a row's, and how far it goes between two of each.
        var nextX = dx == 0 ? Double.infinity : (Double(dx > 0 ? x + 1 : x) - x0) / dx
        var nextY = dy == 0 ? Double.infinity : (Double(dy > 0 ? y + 1 : y) - y0) / dy
        let (acrossX, acrossY) = (dx == 0 ? Double.infinity : 1 / abs(dx), dy == 0 ? Double.infinity : 1 / abs(dy))
        var crossed = [square(atColumn: x, row: y)]
        // One step a side crossed: as many as there are between the ends'
        // squares, so the walk ends even where rounding puts it a side off.
        for _ in 0..<(abs(lastX - x) + abs(lastY - y)) {
            if nextX < nextY {
                x += stepX
                nextX += acrossX
            } else {
                y += stepY
                nextY += acrossY
            }
            crossed.append(square(atColumn: x, row: y))
        }
        return crossed
    }

    /// The square at a column and row of the grid as the walk counts them,
    /// on from either end of the columns round the antimeridian.
    private func square(atColumn column: Int, row: Int) -> Square {
        Square(row: min(rowCount - 1, max(0, row)), column: (column % columnCount + columnCount) % columnCount)
    }

    /// `rows` grown by `marginKilometers` each way: rows by the square's
    /// height, columns by its width at the poleward edge of either row, the
    /// narrowest it is there, and round the antimeridian.
    func grown(_ rows: [Int: [ClosedRange<Int>]], by marginKilometers: Double) -> [Int: [ClosedRange<Int>]] {
        let columns = columnCount
        let rowReach = Int((marginKilometers / squareKilometers).rounded(.up))
        var grown: [Int: [ClosedRange<Int>]] = [:]
        for (row, runs) in rows {
            let targets = max(row - rowReach, 0)...min(row + rowReach, rowCount - 1)
            for target in targets {
                let poleward = max(abs(edgeLatitude(of: min(row, target))), abs(edgeLatitude(of: max(row, target) + 1)))
                let cosine = max(cos(poleward * .pi / 180), Self.minimumCosine)
                let reach = Int(min((marginKilometers / (squareKilometers * cosine)).rounded(.up), Double(columns)))
                for run in runs {
                    let west = run.lowerBound - reach
                    let east = run.upperBound + reach
                    guard east - west + 1 < columns else {
                        grown[target, default: []].append(0...(columns - 1))
                        continue
                    }
                    // Round the antimeridian: a run past either end of the
                    // grid goes on from the other.
                    let wrappedWest = (west % columns + columns) % columns
                    let wrappedEast = wrappedWest + (east - west)
                    if wrappedEast < columns {
                        grown[target, default: []].append(wrappedWest...wrappedEast)
                    } else {
                        grown[target, default: []].append(wrappedWest...(columns - 1))
                        grown[target, default: []].append(0...(wrappedEast - columns))
                    }
                }
            }
        }
        return grown.mapValues(TileCoverage.merged)
    }

    /// The latitude of a row's southern edge.
    private func edgeLatitude(of row: Int) -> Double {
        Double(row) / Double(perDegree) - 90
    }

    /// West, south, east and north of `squares`, in degrees: the whole width
    /// of the world where they wrap round the antimeridian.
    func bounds(of squares: [Square]) -> (west: Double, south: Double, east: Double, north: Double) {
        let perDegree = Double(self.perDegree)
        let rows = squares.map(\.row)
        let columns = squares.map(\.column)
        let south = Double(rows.min() ?? 0) / perDegree - 90
        let north = Double((rows.max() ?? 0) + 1) / perDegree - 90
        let wraps = columns.contains(0) && columns.contains(columnCount - 1)
        let west = wraps ? -180 : Double(columns.min() ?? 0) / perDegree - 180
        let east = wraps ? 180 : Double((columns.max() ?? 0) + 1) / perDegree - 180
        return (west, south, east, north)
    }
}
