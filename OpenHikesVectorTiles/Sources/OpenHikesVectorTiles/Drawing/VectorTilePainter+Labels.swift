//
//  VectorTilePainter+Labels.swift
//  OpenHikesVectorTiles
//
//  The names, icons, road numbers and one-way arrows of a drawn tile, over
//  everything they name, each claiming its room in the order OpenStreetMap
//  Carto's layers claim it.
//

import CoreGraphics

extension VectorTilePainter {
    /// Names, the points' icons, the roads' numbers and the one-way arrows
    /// last, over everything they name, each claiming room in the order
    /// OpenStreetMap Carto's layers claim it: places, the stations' icons and
    /// names, the points' icons, the roads' numbers, the names along streets
    /// and paths and then their arrows, the points' names with the lakes'
    /// and the localities' (``PointNames``), the buildings' names, the house
    /// numbers, the names along water and ridges, and last the low-priority
    /// icons and names — benches, bins, wayside crosses.
    func paintLabels() {
        let placeCandidates = VectorTileLabels.candidates(
            in: tile,
            source: source,
            target: target,
            bounds: bounds,
            language: language
        )
        let places = placeNames(placeCandidates.filter { $0.category.turn == .first }, clearOf: [])
        let candidates = pointCandidates()
        let main = candidates.filter { !$0.look.lowPriority && !$0.look.isStation }
        // Mapnik keeps no room between a point and a name; the names along
        // lines keep theirs from everything, `occupied` included.
        var room = VectorTilePoints.Room(bounds: bounds, taken: places.placements.map(\.frame))
        var fonts = LabelFonts(language: language)
        let stations = VectorTilePoints.Stations(
            candidates.filter(\.look.isStation),
            unit: unit,
            room: &room,
            fonts: &fonts
        )
        let icons = VectorTilePoints.Icons(main, unit: unit, room: &room)
        let shields = VectorTileShields.Layout(
            VectorTileShields.lines(in: tile, source: source, target: target),
            target: target,
            unit: unit,
            room: &room,
            fonts: &fonts
        )
        let named = VectorTileLineLabels.lines(in: tile, source: source, target: target, language: language)
        let streets = lineNames(named.filter { !$0.category.isPlacedAfterPoints }, clearOf: room.taken)
        room = VectorTilePoints.Room(bounds: bounds, taken: streets.taken)
        let oneWay = VectorTileArrows.lines(in: tile, source: source, target: target)
        let arrows = VectorTileArrows.Layout(oneWay, unit: unit, room: &room)
        let names = pointNames(main, among: placeCandidates, room: &room, fonts: &fonts)
        stations.icons.draw(into: context, icons: points.icons)
        icons.draw(into: context, icons: points.icons)
        arrows.draw(into: context, unit: unit)
        shields.draw(into: context, unit: unit)
        streets.draw(into: context)
        paintLateLabels(
            points: candidates,
            lines: named.filter(\.category.isPlacedAfterPoints),
            room: &room,
            fonts: &fonts
        )
        places.draw(into: context)
        names.waters.draw(into: context)
        names.localities.draw(into: context)
        stations.names.draw(into: context)
        names.points.draw(into: context)
    }

    /// The names Carto's layer of points writes, placed in its order: the
    /// summits and passes by their height, then the lakes, bays and
    /// glaciers, which it orders among the areas by their size, then every
    /// other point's, and last the localities'. So a summit keeps its name
    /// where a lake's would cover it, and a hut's where a gully's would.
    private func pointNames(
        _ main: [VectorTilePoints.Candidate],
        among places: [VectorTileLabels.Candidate],
        room: inout VectorTilePoints.Room,
        fonts: inout LabelFonts
    ) -> PointNames {
        var written = VectorTilePoints.Names(main.filter(\.rank.isByHeight), unit: unit, room: &room, fonts: &fonts)
        let waters = placeNames(places.filter { $0.category.turn == .afterSummits }, clearOf: room.taken)
        for placement in waters.placements { room.take(placement.frame) }
        for candidate in main where !candidate.rank.isByHeight {
            written.place(candidate, unit: unit, room: &room, fonts: &fonts)
        }
        let localities = placeNames(places.filter { $0.category.turn == .afterPoints }, clearOf: room.taken)
        for placement in localities.placements { room.take(placement.frame) }
        return PointNames(points: written, waters: waters, localities: localities)
    }

    /// What claims its room after the points' names, and is drawn under
    /// them: the buildings' names, the house numbers, the names along water
    /// and ridges, and the low-priority icons and names.
    /// - Parameter points: every point of the tile, which a building's name
    ///   is checked against, the low-priority ones among them.
    private func paintLateLabels(
        points candidates: [VectorTilePoints.Candidate],
        lines: [VectorTileLineLabels.NamedLine],
        room: inout VectorTilePoints.Room,
        fonts: inout LabelFonts
    ) {
        let buildings = VectorTilePoints.Names(
            VectorTileBuildingNames.candidates(
                in: tile,
                source: source,
                target: target,
                language: language,
                besides: candidates
            ),
            unit: unit,
            room: &room,
            fonts: &fonts
        )
        let numbers = VectorTilePoints.Names(
            VectorTileHouseNumbers.candidates(in: tile, source: source, target: target),
            unit: unit,
            room: &room,
            fonts: &fonts,
            margin: VectorTileHouseNumbers.margin * unit
        )
        let water = lineNames(lines, clearOf: room.taken)
        room = VectorTilePoints.Room(bounds: bounds, taken: water.taken)
        let low = candidates.filter(\.look.lowPriority)
        let lowIcons = VectorTilePoints.Icons(low, unit: unit, room: &room)
        let lowNames = VectorTilePoints.Names(low, unit: unit, room: &room, fonts: &fonts)
        lowIcons.draw(into: context, icons: points.icons)
        water.draw(into: context)
        numbers.draw(into: context)
        buildings.draw(into: context)
        lowNames.draw(into: context)
    }

    /// `candidates` set and placed clear of `occupied`: the names of places,
    /// which claim room first, and the lakes' and the localities', which
    /// wait their turn among the points.
    private func placeNames(
        _ candidates: [VectorTileLabels.Candidate],
        clearOf occupied: [CGRect]
    ) -> VectorTileLabels.Layout {
        VectorTileLabels.Layout(
            candidates,
            z: z,
            unit: unit,
            bounds: bounds,
            language: language,
            occupied: occupied
        )
    }

    private func lineNames(
        _ lines: [VectorTileLineLabels.NamedLine],
        clearOf occupied: [CGRect]
    ) -> VectorTileLineLabels.Layout {
        VectorTileLineLabels.Layout(lines, z: z, unit: unit, bounds: bounds, occupied: occupied, language: language)
    }

    private func pointCandidates() -> [VectorTilePoints.Candidate] {
        VectorTilePoints.candidates(
            in: tile,
            source: source,
            target: target,
            language: language,
            height: height,
            style: points.style
        )
    }
}

/// The names placed in the points' turn: the points' own, and the lakes'
/// and the localities' written among them.
private struct PointNames {
    let points: VectorTilePoints.Names
    let waters: VectorTileLabels.Layout
    let localities: VectorTileLabels.Layout
}
