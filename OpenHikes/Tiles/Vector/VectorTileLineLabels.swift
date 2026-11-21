//
//  VectorTileLineLabels.swift
//  OpenHikes
//
//  Names along lines: streets, paths, tracks, lifts, rivers, ridges and
//  cliffs, set letter by letter along the line they name, or beside it where
//  the name would hide the line: a stream's, a ridge's. A protected area's
//  name goes along the inside of its edge (`VectorTileLineLabels+Areas.swift`).
//
//  The archive splits a street wherever its tags change, so a street arrives
//  as many short ways. Pieces with the same name that meet end to end are
//  joined first, which is what leaves room for the name. A name reads left to
//  right whichever way the line was drawn, follows bends up to its look's
//  ``VectorTileLabelStyle/LineLook/bend`` from one letter to the next, and is
//  moved along the line, or left out, where it would bend more, cross the
//  tile's edge or touch another name. A long line repeats its name, never
//  nearer itself than its look's repeat distance, at marks
//  measured from the line's middle, and a tile names only the marks inside
//  it, so the tiles cut from one archive tile agree on where the repeats go.
//  Point names claim their room first, so a street name never covers a
//  district's or a summit's.
//
//  A right-to-left name, Hebrew or Arabic, is laid out letter by letter in
//  the order its letters stand on the page. Each letter is still set on its
//  own, so Arabic's letters stand in their separate forms rather than
//  joined.
//

import Algorithms
import CoreGraphics
import CoreText
import Foundation

nonisolated enum VectorTileLineLabels {
    /// One or more of the archive's ways, joined end to end, in the picture's
    /// pixels.
    struct NamedLine: Equatable {
        let category: VectorTileLabelStyle.LineCategory
        let name: String
        let points: [CGPoint]
        /// Measured once, because placing and ordering both read it.
        let length: CGFloat
        /// The box around the line: a line whose box misses a tile cannot
        /// carry a name on it.
        let box: CGRect

        init(category: VectorTileLabelStyle.LineCategory, name: String, points: [CGPoint]) {
            self.category = category
            self.name = name
            self.points = points
            length = VectorTileLineLabels.length(of: points)
            let across = points.lazy.map(\.x).minAndMax() ?? (0, 0)
            let down = points.lazy.map(\.y).minAndMax() ?? (0, 0)
            box = CGRect(x: across.min, y: down.min, width: across.max - across.min, height: down.max - down.min)
        }
    }

    /// Where one letter goes: its centre, and the line's direction there.
    struct Letter: Equatable {
        let center: CGPoint
        let angle: CGFloat
    }

    // MARK: Choosing

    /// The named lines `tile` offers at `target`'s zoom, joined, most
    /// important first and the longer first within a category.
    static func lines(
        in tile: MapboxVectorTile,
        source: VectorTileAddress,
        target: VectorTileAddress,
        language: String
    ) -> [NamedLine] {
        var pieces: [NamedLineKey: [[CGPoint]]] = [:]
        for layerName in ["roads", "water", VectorTileRasterizer.ridgesLayer, "earth"] {
            guard let layer = tile.layers[layerName] else { continue }
            let geometry = VectorTileGeometry(extent: layer.extent, source: source, target: target)
            for feature in layer.features where feature.type == .line {
                let kind = feature.string("kind")
                let detail = feature.string("kind_detail")
                // A minor road's or a track's number, which Carto writes
                // along it as it writes a name.
                if layerName == "roads",
                   let numbered = VectorTileLabelStyle.LineCategory.number(kind: kind, detail: detail),
                   target.z >= VectorTileLabelStyle.look(of: numbered).minimumZ,
                   let number = roadNumber(of: feature) {
                    pieces[NamedLineKey(category: numbered, name: number), default: []] += geometry.lines(of: feature)
                }
                guard let category = VectorTileLabelStyle.LineCategory.line(in: layerName, kind: kind, detail: detail),
                      target.z >= VectorTileLabelStyle.look(of: category).minimumZ,
                      let name = VectorTileLabels.name(of: feature, language: language)
                else { continue }
                pieces[NamedLineKey(category: category, name: name), default: []] += geometry.lines(of: feature)
            }
        }
        let lines = pieces.flatMap { key, parts in
            joined(parts).map { NamedLine(category: key.category, name: key.name, points: $0) }
        }
        return (lines + areaEdges(in: tile, source: source, target: target, language: language)).sorted(by: precedes)
    }

    /// The first of a road's numbers, where it has several.
    static func roadNumber(of feature: MapboxVectorTile.Feature) -> String? {
        let first = feature.string(VectorTileShields.refKey)?
            .split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces)
        return first?.isEmpty == false ? first : nil
    }

    /// `parts` joined wherever one ends where another begins or ends, which
    /// is how a street the archive split comes back whole.
    static func joined(_ parts: [[CGPoint]]) -> [[CGPoint]] {
        var remaining = parts.filter { $0.count > 1 }
        var lines: [[CGPoint]] = []
        while var line = remaining.popLast() {
            while let index = remaining.firstIndex(where: { touches($0, line) }) {
                line = attach(remaining.remove(at: index), to: line)
            }
            lines.append(line)
        }
        return lines
    }

    // MARK: Setting letters

    /// The letters of a name `advances` wide, centred at `middle` along
    /// `points`, reading left to right: along the line, or along it reversed
    /// where it was drawn leftward. Empty where the name runs off the line or
    /// turns more than `maximumBend` from one letter to the next.
    static func letters(
        along points: [CGPoint],
        advances: [CGFloat],
        centeredAt middle: CGFloat,
        maximumBend: CGFloat
    ) -> [Letter] {
        letters(
            along: MeasuredPath(points),
            reversed: MeasuredPath(points.reversed()),
            advances: advances,
            centeredAt: middle,
            maximumBend: maximumBend
        )
    }

    /// ``letters(along:advances:centeredAt:maximumBend:)`` on a line measured
    /// once, both ways, for the many spots tried along it.
    private static func letters(
        along path: MeasuredPath,
        reversed: MeasuredPath,
        advances: [CGFloat],
        centeredAt middle: CGFloat,
        maximumBend: CGFloat
    ) -> [Letter] {
        let total = advances.reduce(0, +)
        let start = middle - total / 2
        guard start >= 0, middle + total / 2 <= path.length else { return [] }
        guard path.point(at: start + total).x < path.point(at: start).x else {
            return letters(on: path, advances: advances, from: start, maximumBend: maximumBend)
        }
        // The same share of the way along the line read the other way, which
        // is as long unless the two run beside the line, one on each side.
        let turned = reversed.length * (1 - middle / path.length) - total / 2
        guard turned >= 0, turned + total <= reversed.length else { return [] }
        return letters(on: reversed, advances: advances, from: turned, maximumBend: maximumBend)
    }

    private static func letters(
        on path: MeasuredPath,
        advances: [CGFloat],
        from start: CGFloat,
        maximumBend: CGFloat
    ) -> [Letter] {
        var letters: [Letter] = []
        var distance = start
        for advance in advances {
            let before = path.point(at: distance)
            let after = path.point(at: distance + advance)
            let angle = advance > 0 ? atan2(after.y - before.y, after.x - before.x) : letters.last?.angle ?? 0
            if let previous = letters.last, abs(turn(from: previous.angle, to: angle)) > maximumBend { return [] }
            letters.append(Letter(center: path.point(at: distance + advance / 2), angle: angle))
            distance += advance
        }
        return letters
    }

    /// A place along a line a name may stand: the mark itself, then the
    /// spots it may slide to, nearest first.
    struct Mark: Equatable {
        let distance: CGFloat
        let spots: [CGFloat]
    }

    /// Where along a line `length` long a name `width` wide is tried: at its
    /// middle and every one and a half `spacing` either side, the middle
    /// first. Each mark may slide by `step` either way, no further than a
    /// quarter of `spacing`, so two names at neighbouring marks stand at
    /// least `spacing` apart however each slid. Measured from the whole
    /// line's middle, the marks fall in the same places on every tile cut
    /// from one archive tile, so that holds across the edge between two.
    static func marks(length: CGFloat, width: CGFloat, spacing: CGFloat, step: CGFloat) -> [Mark] {
        guard width <= length, spacing > 0, step > 0 else { return [] }
        let middle = length / 2
        let reach = spacing / 4
        let slides = slides(by: step, upTo: reach)
        let interval = spacing + 2 * reach
        let count = Int((middle / interval).rounded(.down))
        let distances = (-count...count).map { middle + CGFloat($0) * interval }
        let nearestFirst = distances.sorted { lhs, rhs in
            let (lhsOff, rhsOff) = (abs(lhs - middle), abs(rhs - middle))
            return lhsOff == rhsOff ? lhs < rhs : lhsOff < rhsOff
        }
        let fits = (width / 2)...(length - width / 2)
        return nearestFirst.compactMap { distance in
            let spots = slides.map { distance + $0 }.filter(fits.contains)
            return spots.isEmpty ? nil : Mark(distance: distance, spots: spots)
        }
    }

    /// The characters of `text` in the order they stand on the page, left to
    /// right: Core Text's bidirectional layout of the whole name, with each
    /// right-to-left run's characters reversed.
    static func visualOrder(of text: String) -> [String] {
        let logical = text.map(String.init)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text))
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return logical }
        var visual: [String] = []
        for run in runs.sorted(by: { origin(of: $0) < origin(of: $1) }) {
            let range = CTRunGetStringRange(run)
            guard let span = Range(NSRange(location: range.location, length: range.length), in: text) else {
                return logical
            }
            let characters = text[span].map(String.init)
            visual += CTRunGetStatus(run).contains(.rightToLeft) ? characters.reversed() : characters
        }
        // A run that split a character would lose or repeat it.
        return visual.count == logical.count ? visual : logical
    }

    static func length(of points: [CGPoint]) -> CGFloat {
        MeasuredPath(points).length
    }

    // MARK: Helpers

    private struct NamedLineKey: Hashable {
        let category: VectorTileLabelStyle.LineCategory
        let name: String
    }

    /// Ends closer than this are one point: the archive gives both ways the
    /// node they share, and only rounding parts them.
    private static let joinTolerance: CGFloat = 0.5

    /// More important first, then longer, then by name and place, so every
    /// tile settles a tie the same way.
    private static func precedes(_ lhs: NamedLine, _ rhs: NamedLine) -> Bool {
        if lhs.category != rhs.category { return lhs.category < rhs.category }
        if lhs.length != rhs.length { return lhs.length > rhs.length }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        let lhsStart = lhs.points.first ?? .zero
        let rhsStart = rhs.points.first ?? .zero
        return (lhsStart.x, lhsStart.y) < (rhsStart.x, rhsStart.y)
    }

    /// Where a run's first glyph stands along the line.
    private static func origin(of run: CTRun) -> CGFloat {
        var position = CGPoint.zero
        CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
        return position.x
    }

    private static func close(_ lhs: CGPoint?, _ rhs: CGPoint?) -> Bool {
        guard let lhs, let rhs else { return false }
        return abs(lhs.x - rhs.x) <= joinTolerance && abs(lhs.y - rhs.y) <= joinTolerance
    }

    private static func touches(_ part: [CGPoint], _ line: [CGPoint]) -> Bool {
        close(part.first, line.last) || close(part.last, line.last) || close(part.last, line.first)
            || close(part.first, line.first)
    }

    private static func attach(_ part: [CGPoint], to line: [CGPoint]) -> [CGPoint] {
        if close(part.first, line.last) { return line + part.dropFirst() }
        if close(part.last, line.last) { return line + part.reversed().dropFirst() }
        if close(part.last, line.first) { return part + line.dropFirst() }
        return part.reversed() + line.dropFirst()
    }

    /// The signed turn from one direction to another, between -π and π.
    private static func turn(from: CGFloat, to: CGFloat) -> CGFloat {
        var difference = to - from
        while difference > .pi { difference -= 2 * .pi }
        while difference < -.pi { difference += 2 * .pi }
        return difference
    }
}

// MARK: - Drawing

nonisolated extension VectorTileLineLabels {
    /// The line names placed on one tile, set and ready to draw.
    struct Layout {
        private let names: [SetName]
        /// The room taken once these names are placed: what was taken before
        /// them, and their letters'.
        let taken: [CGRect]

        /// How many names were placed, repeats included.
        var count: Int { names.count }

        /// A letter's width as a share of its size, at its narrowest: no name
        /// is narrower than this many sizes per character.
        private static let narrowestLetter: CGFloat = 0.25

        /// `lines`, in order, each at as many of its marks inside `bounds` as
        /// fit: inside `bounds`, clear of `occupied` and of each other, and no
        /// nearer the same name than its look's
        /// ``VectorTileLabelStyle/LineLook/repeatDistance``.
        init(
            _ lines: [NamedLine],
            target: VectorTileAddress,
            unit: CGFloat,
            bounds: CGRect,
            occupied: [CGRect],
            language: String
        ) {
            let z = target.z
            let spacing = VectorTileLabelStyle.spacing * unit
            // The picture's corner on the world's grid at its zoom.
            let side = CGFloat(VectorTileRasterizer.pixelSize)
            let origin = CGPoint(x: CGFloat(target.x) * side, y: CGFloat(target.y) * side)
            var room = Room(inner: bounds.insetBy(dx: spacing, dy: spacing), spacing: spacing, taken: occupied)
            var placed: [SetName] = []
            var texts: [String: SetText] = [:]
            var fonts = LabelFonts(language: language)
            for line in lines {
                let look = VectorTileLabelStyle.look(of: line.category)
                let offset = look.offset(at: z) * unit
                // A tile deeper than the archive holds the whole archive
                // tile's lines, most of them nowhere near it. A name set
                // beside its line can stand inside the tile when the line
                // runs just outside it.
                guard line.box.insetBy(dx: -abs(offset), dy: -abs(offset)).intersects(bounds) else { continue }
                let size = look.size.value(at: z) * unit
                // A name about as long as its line will not fit it, so it is
                // never set letter by letter: most of a city's ways are that.
                guard line.length > CGFloat(line.name.count) * size * Self.narrowestLetter else { continue }
                let key = "\(line.category)/\(line.name)"
                let text = texts[key]
                    ?? SetText(line.name, font: fonts.font(size: size, face: look.face), look: look, unit: unit)
                texts[key] = text
                let repeatDistance = look.repeatDistance * unit
                // A name written beside its line is set along the line that
                // runs beside it, on the side below the name whichever way it
                // reads, or an area's on the area's side however it reads.
                let beside = MeasuredPath.offset(line.points, by: offset)
                let forward = MeasuredPath(beside)
                let backward = MeasuredPath(
                    look.isInsideArea ? beside.reversed() : MeasuredPath.offset(line.points.reversed(), by: offset)
                )
                let marks = Self.marks(
                    of: look,
                    along: forward,
                    origin: origin,
                    unit: unit,
                    width: text.width,
                    step: max(text.width / 4, spacing)
                )
                guard !marks.isEmpty else { continue }
                // A mark outside the tile is the neighbouring tile's to name.
                for mark in marks where bounds.contains(forward.point(at: mark.distance)) {
                    for spot in mark.spots {
                        let letters = VectorTileLineLabels.letters(
                            along: forward,
                            reversed: backward,
                            advances: text.advances,
                            centeredAt: spot,
                            maximumBend: look.bend
                        )
                        let boxes = text.boxes(for: letters)
                        if room.claim(name: line.name, letters: letters, boxes: boxes, apart: repeatDistance) {
                            placed.append(SetName(text: text, letters: letters))
                            break
                        }
                    }
                }
            }
            names = placed
            taken = room.taken
        }

        /// Where along `path` a name `width` wide in `look` is tried: where
        /// the path crosses the world's grid, for a look that has one, and
        /// otherwise from the path's middle.
        private static func marks(
            of look: VectorTileLabelStyle.LineLook,
            along path: MeasuredPath,
            origin: CGPoint,
            unit: CGFloat,
            width: CGFloat,
            step: CGFloat
        ) -> [Mark] {
            let repeatDistance = look.repeatDistance * unit
            guard let grid = look.gridSpacing else {
                return VectorTileLineLabels.marks(
                    length: path.length,
                    width: width,
                    spacing: repeatDistance,
                    step: step
                )
            }
            return VectorTileLineLabels.marks(
                along: path,
                origin: origin,
                every: grid * unit,
                apart: repeatDistance,
                width: width,
                step: step
            )
        }

        /// Draws every name's halo, then every name's letters, so no halo
        /// covers a letter drawn before it.
        func draw(into context: CGContext) {
            context.saveGState()
            context.setLineJoin(.round)
            for name in names { name.draw(into: context, halo: true) }
            for name in names { name.draw(into: context, halo: false) }
            context.restoreGState()
        }
    }
}

/// The room left on a tile for names along lines.
nonisolated private struct Room {
    let inner: CGRect
    let spacing: CGFloat
    var taken: [CGRect]
    var placedAt: [String: [CGPoint]] = [:]

    /// Takes the room `boxes` need for `name`, if they fit inside the tile,
    /// touch nothing placed, and stand at least `apart` from the same name.
    mutating func claim(
        name: String,
        letters: [VectorTileLineLabels.Letter],
        boxes: [CGRect],
        apart repeatDistance: CGFloat
    ) -> Bool {
        guard let middle = letters.dropFirst(letters.count / 2).first?.center else { return false }
        let nearSame = placedAt[name, default: []].contains { spot in
            hypot(spot.x - middle.x, spot.y - middle.y) < repeatDistance
        }
        let fits = boxes.allSatisfy { inner.contains($0) }
        let clear = !boxes.contains { box in
            taken.contains { $0.insetBy(dx: -spacing, dy: -spacing).intersects(box) }
        }
        guard !nearSame, fits, clear else { return false }
        taken += boxes
        placedAt[name, default: []].append(middle)
        return true
    }
}

/// A name broken into its characters, in the order they stand on the page,
/// each set on its own so it can be turned to the line under it. Kerning is
/// given up for that; at a map's sizes it does not show.
nonisolated private struct SetText {
    let characters: [InkedText]
    let height: CGFloat
    /// From a letter's centre down to its baseline, so the letters sit
    /// centred on the line.
    let baselineDrop: CGFloat

    var advances: [CGFloat] { characters.map(\.width) }
    var width: CGFloat { advances.reduce(0, +) }

    init(_ text: String, font: CTFont, look: VectorTileLabelStyle.LineLook, unit: CGFloat) {
        characters = VectorTileLineLabels.visualOrder(of: text).map { character in
            InkedText(character, font: font, color: look.color, unit: unit)
        }
        let rise = characters.map(\.ascent).max() ?? 0
        let fall = characters.map(\.descent).max() ?? 0
        height = rise + fall
        baselineDrop = (rise - fall) / 2
    }

    /// Each letter's box on the picture, as wide as its advance and as tall
    /// as the line of text, turned with the line and boxed again.
    func boxes(for letters: [VectorTileLineLabels.Letter]) -> [CGRect] {
        zip(characters, letters).map { character, letter in
            CGRect(x: -character.width / 2, y: -height / 2, width: character.width, height: height)
                .applying(
                    CGAffineTransform(translationX: letter.center.x, y: letter.center.y).rotated(by: letter.angle)
                )
        }
    }
}

/// A name set along a line.
nonisolated private struct SetName {
    let text: SetText
    let letters: [VectorTileLineLabels.Letter]

    func draw(into context: CGContext, halo: Bool) {
        for (character, letter) in zip(text.characters, letters) {
            context.saveGState()
            context.translateBy(x: letter.center.x, y: letter.center.y)
            context.rotate(by: letter.angle)
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            let baseline = CGPoint(x: -character.width / 2, y: text.baselineDrop)
            if halo {
                character.drawHalo(at: baseline, context: context)
            } else {
                character.drawInk(at: baseline, context: context)
            }
            context.restoreGState()
        }
    }
}
