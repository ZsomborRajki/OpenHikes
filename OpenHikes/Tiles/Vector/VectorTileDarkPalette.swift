//
//  VectorTileDarkPalette.swift
//  OpenHikes
//
//  OpenHikes Dark's colors: for each color OpenStreetMap Carto draws the
//  light map in, the color the dark map draws the same thing in
//  (``VectorTilePalette``). The left of each pair is Carto's, as the style
//  and `VectorTilePoints.json` spell it, and is only ever a name here; the
//  right is this map's own.
//
//  What the colors are chosen by:
//  - The ground is dark and nearly without color, and what grows on it
//    keeps Carto's order: a wood is darker than a meadow, and both are
//    greener than a field. Carto's lightest ground, the land itself, is the
//    darkest here, so the pairs are no inversion.
//  - Water is the one large thing lighter than the land, so a stream a
//    pixel wide is still found in a wood.
//  - A street is lighter than the ground it crosses and cased darker than
//    it, where Carto's is white cased gray. The classed roads keep Carto's
//    hues, a motorway's red through a secondary's yellow, dimmed.
//  - Whatever is read rather than seen, a name, a path, an icon, a
//    border, is light: Carto's black is nearly white, and its pale grays,
//    which mark what is closed or matters least, are dim.
//  - A halo is the color of the dark ground, so a name is cut out of
//    whatever it crosses as Carto's white halo cuts one out.
//
//  A color Carto adds, or one of the few not listed, is drawn by rule
//  (``VectorTileDarkening``), so nothing here has to be complete for the
//  map to be readable. `VectorTileDarkPaletteTests` holds the table to the
//  colors the map is mostly made of.
//

nonisolated extension VectorTilePalette {
    /// OpenHikes Dark's.
    static let dark = Self(
        name: "dark",
        isDark: true,
        shared: VectorTileDarkPalette.ground + VectorTileDarkPalette.lines + VectorTileDarkPalette.points,
        roles: [
            .casing: VectorTileDarkPalette.casings,
            .fill: VectorTileDarkPalette.fills,
            .halo: VectorTileDarkPalette.halos,
            .pattern: VectorTileDarkPalette.patterns,
            .surface: VectorTileDarkPalette.surfaces,
            .text: VectorTileDarkPalette.text,
        ],
        otherwise: VectorTileDarkening.darkened
    )
}

nonisolated enum VectorTileDarkPalette {
    typealias Pair = (carto: String, own: String)

    // MARK: Whatever it is put down as

    /// The ground, the water and what stands on them.
    static let ground: [Pair] = [
        ("#F2EFE9", "#1C1E20"), // land
        ("#AAD3DF", "#1E4866"), // water, the sea, a salt pond
        ("#D9D0C9", "#383532"), // a building
        ("#C4B6AB", "#4E4A45"), // its outline
        ("#C8FACC", "#1F3B2C"), // a park
        ("#ADADAD", "#5A5D60"), // a dam
        ("#ADD19E", "#1B3423"), // forest, wood
        ("#CDEBB0", "#283F24"), // grass, meadow, and a line cut through a forest
        ("#EEF0D5", "#24261D"), // farmland
        ("#C8D7AB", "#2A3823"), // scrub
        ("#DDECEC", "#3E5057"), // a glacier
        ("#EEE5DC", "#2C2927"), // bare rock, scree
        ("#E0DFDF", "#27282A"), // residential, built-up land
        ("#D6D99F", "#353720"), // heath
        ("#F5DCBA", "#3A3024"), // a farmyard
        ("#AEDFA3", "#233D22"), // an orchard, a vineyard
        ("#C9E1BF", "#28392B"), // allotments
        ("#F2DAD9", "#33292A"), // commercial
        ("#FFD6D1", "#3B2A28"), // retail
        ("#EBDBE8", "#2E2A31"), // industrial, railway land
        ("#E3CBDF", "#32293A"), // a power station
        ("#AACBAF", "#22362B"), // a cemetery
        ("#FFFFE5", "#2D2D23"), // a hospital, a school
        ("#88E0BE", "#1D4638"), // a pitch
        ("#DFFCE2", "#233C2F"), // a playground, a recreation ground
        ("#DEF6C0", "#2B3E23"), // a golf course, a camp site
        ("#DDDDE8", "#35363E"), // a pedestrian square
        ("#EEEEEE", "#2E2F31"), // parking
        ("#DFDDCE", "#302F29"), // garages
        ("#E9E7E2", "#2B2B29"), // an aerodrome
        ("#DADAE0", "#35353B"), // its apron
        ("#EFC8C8", "#3A2B2B"), // a rest area
        ("#D0D0D0", "#313234"), // religious land
        ("#FFF1BA", "#4B4327"), // a beach
        ("#F5E9C6", "#403B2B"), // sand
        ("#C5C3C3", "#39383B"), // a quarry
        ("#B6B592", "#3A3A2B"), // a landfill
        ("#C7C7B4", "#37372F"), // a building site
        ("#CBB19A", "#7A6654"), // mud, laid thin
        ("#B8B8B8", "#55585C"), // a bridge mapped as an area
        ("#F3F7F7", "#14181B"), // the pale line of a waterway's tunnel
        ("#FF5555", "#FF5C5C"), // military land's tint, line and hatch
    ]

    /// Lines, and the grays most things are drawn in.
    static let lines: [Pair] = [
        ("#FFFFFF", "#111315"), // what Carto leaves white: a railway's dashes, a tower's eye
        ("#000000", "#E6E8EB"), // what it draws black: a lift's cabins, a path's bridge
        ("#444444", "#8C8F93"), // a fence, a wall, a dam's line
        ("#666666", "#989BA0"), // a light railway
        ("#6E6E6E", "#8D9095"), // a tram
        ("#707070", "#8F9297"), // a railway
        ("#7B7B7B", "#8A8D91"), // an embankment
        ("#808080", "#888B8F"), // a lift's cable, a path's tunnel
        ("#868686", "#808387"), // a power line's tower
        ("#888888", "#6D7074"), // a power line
        ("#919191", "#73767A"), // a city wall
        ("#928F8F", "#7C7B7D"), // a power line's pole
        ("#999999", "#7B7E82"), // a cliff, a ridge, a subway
        ("#AAAAAA", "#5E6165"), // a siding, a disused railway, a weir, a breakwater
        ("#BBBBBB", "#5A5D62"), // a road too far off to class, a closed footway
        ("#BBBBCC", "#565869"), // a runway, a taxiway
        ("#99CCFF", "#5C92BD"), // a glacier's edge
        ("#8D618B", "#B383B1"), // a border's band
        ("#845283", "#C592C3"), // the line down it
        ("#008000", "#42A650"), // a protected area's border, a bridleway
        ("#82643A", "#B38D58"), // aboriginal lands' border
        ("#90C17B", "#3F6E3B"), // a tree's crown
        ("#6B8D5E", "#5E8D54"), // its trunk
        ("#6666FF", "#7F89FF"), // a ferry
        ("#FA8072", "#F28470"), // a footpath, steps
        ("#0000FF", "#7089FF"), // a cycleway
        ("#9999FF", "#4C5194"), // a closed one
        ("#AADDAA", "#3B5C3D"), // a closed bridleway
        ("#996600", "#C99E4C"), // a track
        ("#E2C5BB", "#6E5C54"), // a closed one
    ]

    /// The points' icons, and their names, which Carto writes in the icon's
    /// color or a darker one: the commonest of `VectorTilePoints.json`.
    static let points: [Pair] = [
        ("#AC39AC", "#D98BD9"), // a shop
        ("#993399", "#DDA0DD"), // its name
        ("#734A08", "#D4A76A"), // an amenity, and its name
        ("#0092DA", "#4DB5F0"), // transport, accommodation
        ("#0066FF", "#74A6FF"), // their names
        ("#0C8416", "#57C063"), // leisure, a tree, a spring's surroundings
        ("#C77400", "#F0A548"), // food and drink
        ("#BF0000", "#FF7B72"), // health
        ("#D08F55", "#E0A46E"), // a summit
        ("#7981B0", "#9AA3D6"), // a station
        ("#4957AD", "#96A4F0"), // its name
        ("#8461C4", "#B49AE8"), // a memorial, an artwork
        ("#0565BF", "#6DB0F2"), // a toilet, drinking water
        ("#000033", "#C9CBE8"), // a place of worship
    ]

    // MARK: By what it is put down as

    /// Where an area's color is not its line's.
    static let fills: [Pair] = [
        ("#AAAAAA", "#55585C"), // a breakwater
    ]

    /// A street's surface, and its plate's.
    static let surfaces: [Pair] = [
        ("#E892A2", "#93405A"), // a motorway
        ("#F9B29C", "#9B5338"), // a trunk road
        ("#FCD6A4", "#8E6D30"), // a primary road
        ("#F7FABF", "#70733A"), // a secondary road
        ("#FFFFFF", "#4D5157"), // a tertiary road, a street, a service road
        ("#EDEDED", "#44474C"), // a living street
        ("#DDDDE8", "#41424C"), // a pedestrian street
        ("#DDDDDD", "#3E4146"), // a road of no class yet
        ("#AAAAAA", "#55585C"), // a minor road being built
    ]

    /// Its casing, darker than the ground it crosses.
    static let casings: [Pair] = [
        ("#DC2A67", "#4F1A2B"), // a motorway
        ("#C84E2F", "#532513"), // a trunk road
        ("#A06B00", "#4A370D"), // a primary road
        ("#707D05", "#383B0F"), // a secondary road
        ("#8F8F8F", "#0E0F11"), // a tertiary road
        ("#BBBBBB", "#0E0F11"), // a street, a service road
        ("#999999", "#0E0F11"), // a pedestrian street
    ]

    /// The edge round a name, the band under a path and the glow under a
    /// stream: the dark ground, so each is cut out of what it crosses.
    static let halos: [Pair] = [
        ("#FFFFFF", "#0F1113"),
    ]

    /// Names, plates' numbers and the one-way arrows.
    static let text: [Pair] = [
        ("#222222", "#ECEEF0"), // a place
        ("#000000", "#D9DCDF"), // a street
        ("#444444", "#B5B8BC"), // a building
        ("#666666", "#A6A9AD"), // a neighborhood, a house number, a lift
        ("#999999", "#8C8F93"), // a ridge
        ("#9D6C9D", "#CC9FCC"), // a country, a region
        ("#4D80B3", "#82B5E8"), // water
        ("#008000", "#62BE68"), // a protected area
        ("#82643A", "#C59D66"), // aboriginal lands
        ("#620728", "#F5BCCA"), // a motorway's number
        ("#5F1C0C", "#F7C6B4"), // a trunk road's
        ("#503000", "#F3DBAA"), // a primary road's
        ("#364000", "#E4E9A2"), // a secondary road's
        ("#3B3B3B", "#E1E3E6"), // a tertiary road's
        ("#741334", "#E9A5B7"), // a motorway's arrow
        ("#612617", "#EBB09C"), // a trunk road's
        ("#543800", "#E5C78D"), // a primary road's
        ("#444C03", "#D4DA8D"), // a secondary road's
        ("#424242", "#BBBEC2"), // a tertiary road's
        ("#555555", "#ABAEB2"), // a street's
        ("#6E6E6E", "#9B9EA2"), // a living street's
        ("#595959", "#A7AAAE"), // a pedestrian street's
        ("#B31806", "#FF9F90"), // a footpath's
        ("#000080", "#A1B2FF"), // a cycleway's
        ("#664400", "#E2B868"), // a track's
        ("#003400", "#82D68C"), // a bridleway's
    ]

    /// The colors of the pictures an area is filled with, each a little
    /// lighter than the ground it lies on, as Carto's are a little darker.
    static let patterns: [Pair] = [
        ("#F2EFE9", "#1C1E20"), // the paths between allotments: the land
        ("#AAD3DF", "#1E4866"), // water that is not always there
        ("#6B8D5E", "#58935F"), // a wood's leaves
        ("#759E6C", "#41703C"), // an orchard's trees, a vineyard's rows
        ("#0E5500", "#4F9B46"), // a plant nursery
        ("#88B78E", "#3F664B"), // a cemetery's graves
        ("#A6E0AB", "#3B6E47"), // a dog park's paws
        ("#E6E6E6", "#585A5E"), // a quarry's hammers
        ("#999999", "#6F7276"), // a ridge's dots, a shingle beach's stones
        ("#CCCCCC", "#3E3B39"), // rock and scree
        ("#665544", "#8C7C57"), // a beach's sand
        ("#5599CC", "#3B79AA"), // a reef
        ("#FFFFFF", "#7FA7BB"), // a salt pond's crust
        ("#BBBB99", "#43532F"), // scrub
        ("#44AAFF", "#3583C8"), // a wetland's water
        ("#77BB88", "#4F9361"), // its reeds and grass
        ("#779966", "#4B7C4B"), // a mangrove's trees
        ("#99BB88", "#609057"), // a swamp's
    ]
}
