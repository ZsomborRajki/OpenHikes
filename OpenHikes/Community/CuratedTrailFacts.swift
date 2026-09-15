//
//  CuratedTrailFacts.swift
//  OpenHikes
//
//  What OpenStreetMap says about a waymarked route, beyond its line.
//
//  A curated route arrives with no author, no date and no photographs, so the
//  screen showing one has three empty places where a published hike has
//  something to say. These are what goes there — and they are not a
//  consolation prize: a blaze colour, a number, where the path starts and
//  where it ends are the things a hiker reads off a signpost at the trailhead,
//  and no hiker's upload carries any of them.
//
//  Measured coverage on named `route=hiking` relations, which is why these
//  four and not others: `osmc:symbol` ~100%, `network` ~99%, `operator`
//  65-70%, `from`/`to` ~59% in the Alps and ~88% in the UK. `distance` is
//  2% in the Alps and is therefore never trusted — the length on screen is
//  always measured from the geometry, the same rule ``CommunityImport``
//  already follows for a published hike's stated distance.
//
//  Everything here is optional and every consumer is total over `nil`. A
//  region tagged by one mapper on one evening and a region tagged by a
//  national walking association both have to render, and the difference
//  between them is how many rows appear rather than whether the screen works.
//

import Foundation

/// The colours OpenStreetMap's `osmc:symbol` draws a waymark in.
///
/// A closed set rather than the raw string, because the value is rendered as a
/// swatch and an unknown colour has to degrade to *no swatch* rather than to a
/// default one — a red blaze drawn grey is worse than a blaze drawn as text.
/// The vocabulary is the one `osmc:symbol` documents; anything outside it is
/// ``other``, which keeps the name and drops the swatch.
nonisolated enum WaymarkColour: String, CaseIterable, Hashable, Sendable {
    case black = "black"
    case blue = "blue"
    case brown = "brown"
    case green = "green"
    case grey = "grey"
    case orange = "orange"
    case purple = "purple"
    case red = "red"
    case white = "white"
    case yellow = "yellow"

    /// The colour `raw` names, or `nil` when it names none of them.
    ///
    /// Trimmed and lowercased before matching, because this is text off a
    /// public database that people edit by hand — the same suspicion
    /// ``TrailSurface/init(osmSurface:tracktype:)`` applies to its own tag.
    init?(osmColour raw: String?) {
        guard let trimmed = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !trimmed.isEmpty,
            let match = Self(rawValue: trimmed)
        else { return nil }
        self = match
    }

    var displayName: String {
        switch self {
        case .black: "Black"
        case .blue: "Blue"
        case .brown: "Brown"
        case .green: "Green"
        case .grey: "Grey"
        case .orange: "Orange"
        case .purple: "Purple"
        case .red: "Red"
        case .white: "White"
        case .yellow: "Yellow"
        }
    }
}

/// The waymark a hiker follows on the ground: its colour and its number.
///
/// Two fields because a signpost carries two things and either can be absent.
/// "Red 411" and "Red" and "411" are all real waymarks; "" is not, which is
/// why ``init(osmcSymbol:colour:reference:)`` fails rather than producing an
/// empty one.
nonisolated struct TrailWaymark: Hashable, Sendable {
    var colour: WaymarkColour?
    /// The route number as it is painted, from OSM's `ref`.
    var reference: String?

    /// The waymark `osmc:symbol`, `colour` and `ref` describe, or `nil` when
    /// they describe nothing.
    ///
    /// `osmc:symbol` is a colon-separated field whose **first** component is
    /// the colour the route is drawn in — `red:red:white_bar:411:black` is a
    /// red route. Only that component is read: the rest describes the shape
    /// painted on the background (`white_bar`, `yellow_diamond`), which is a
    /// vocabulary of some hundreds of values that would each need a glyph to
    /// be worth rendering, and a name for a shape nobody can see is not worth
    /// a row. The `colour` tag is the fallback for a route that carries one
    /// without an `osmc:symbol`.
    init?(osmcSymbol: String?, colour: String?, reference: String?) {
        let symbolColour = osmcSymbol?
            .split(separator: ":", omittingEmptySubsequences: false)
            .first
            .map(String.init)
        self.colour = WaymarkColour(osmColour: symbolColour)
            ?? WaymarkColour(osmColour: colour)
        self.reference = BoundedText.bounded(reference, to: .credit)
        guard self.colour != nil || self.reference != nil else { return nil }
    }

    /// "Red waymark 411", "Red waymark", "Waymark 411" — whichever halves
    /// there are.
    ///
    /// The word *waymark* rather than the bare colour, because "Red" beside a
    /// distance reads as a second measurement. It is also what makes the
    /// number legible: "411" alone is a figure, and "waymark 411" is a thing
    /// painted on a rock.
    var displayName: String {
        switch (colour, reference) {
        case let (colour?, reference?): "\(colour.displayName) waymark \(reference)"
        case let (colour?, nil): "\(colour.displayName) waymark"
        case let (nil, reference?): "Waymark \(reference)"
        case (nil, nil): ""
        }
    }
}

/// Whether a route brings the hiker back to where they parked.
///
/// The single most decision-relevant fact about a trail after its length, and
/// the one this data set can always answer — `roundtrip=yes` where somebody
/// tagged it, and the geometry itself where nobody did. See
/// ``CuratedTrailFacts/shape(roundtrip:route:)``.
nonisolated enum TrailShape: Hashable, Sendable {
    /// Ends where it began.
    case loop
    /// Ends somewhere else. The hiker walks back or arranges a lift.
    case pointToPoint

    var displayName: String {
        switch self {
        case .loop: "Loop"
        case .pointToPoint: "Point to point"
        }
    }
}

/// Everything OpenStreetMap says about a curated route that is not its line.
nonisolated struct CuratedTrailFacts: Hashable, Sendable {
    var waymark: TrailWaymark?
    var shape: TrailShape?
    /// Where the route begins, in OSM's `from`.
    var origin: String?
    /// Where it ends, in OSM's `to`.
    var destination: String?
    /// What it passes on the way, in OSM's `via`.
    var via: String?
    /// The body that maintains and signs it, in OSM's `operator`.
    var maintainer: String?
    /// Where to read more, in OSM's `website`.
    ///
    /// A `URL` rather than a string so a malformed value is dropped here
    /// rather than drawn as a link that goes nowhere. Only `http` and `https`
    /// survive — see ``CuratedTrailFacts/link(_:)`` — because this is text off
    /// a public database and a `javascript:` or `file:` value handed to
    /// `openURL` is somebody else's decision about what this app opens.
    var website: URL?

    /// Whether there is anything here at all.
    ///
    /// The section that draws these is absent rather than empty when this is
    /// true, which is the rule every late-arriving section on the preview
    /// screen already follows — see ``CommunityHikeView/surfaceSection``.
    var isEmpty: Bool {
        waymark == nil && shape == nil && origin == nil && destination == nil
            && via == nil && maintainer == nil && website == nil
    }

    /// "Mülenen to Rölleren", "From Mülenen", "To Rölleren" — whichever halves
    /// there are, or `nil` when there are none.
    ///
    /// One row rather than two, because the pair is one fact: a hiker reading
    /// *From* on its own line and *To* on the next has to put them back
    /// together to learn the thing either was for.
    var journey: String? {
        switch (origin, destination) {
        case let (origin?, destination?): "\(origin) to \(destination)"
        case let (origin?, nil): "From \(origin)"
        case let (nil, destination?): "To \(destination)"
        case (nil, nil): nil
        }
    }
}

nonisolated extension CuratedTrailFacts {
    /// The facts `tags` carries, with `route` deciding the shape where the
    /// tags do not.
    init(tags: [String: String], route: [RouteCoordinate]) {
        waymark = TrailWaymark(
            osmcSymbol: tags["osmc:symbol"],
            colour: tags["colour"],
            reference: tags["ref"]
        )
        shape = Self.trailShape(roundtrip: tags["roundtrip"], route: route)
        origin = BoundedText.bounded(tags["from"], to: .credit)
        destination = BoundedText.bounded(tags["to"], to: .credit)
        via = BoundedText.bounded(tags["via"], to: .credit)
        maintainer = BoundedText.bounded(tags["operator"], to: .credit)
        website = Self.link(tags["website"])
    }

    /// How far apart a loop's two ends may be and still be one place, in
    /// metres.
    ///
    /// A route relation is a bag of ways whose ends are wherever the mapper
    /// stopped drawing, so a circuit around a lake routinely begins and ends
    /// on opposite sides of the same car park. Generous enough to call that a
    /// loop, tight enough that an out-and-back along a ridge is not one.
    static let loopToleranceMeters: Double = loopToleranceMetres

    /// The figure behind ``loopToleranceMeters``, spelled here so the number
    /// is read beside the paragraph that argues for it rather than as a
    /// literal in an expression.
    private static let loopToleranceMetres: Double = 150

    /// The shape `roundtrip` claims, or the one the geometry shows.
    ///
    /// The tag first, because a mapper who wrote `roundtrip=yes` knows
    /// something the endpoints may not show — a route whose two ends are a
    /// street apart is still a loop to the person who walks it. Geometry
    /// second, because the tag is on 15% of Alpine relations and the question
    /// is worth answering for the other 85%.
    ///
    /// `nil` only when there is no tag *and* no route to measure, which is the
    /// listing pass: a row in the list says nothing about shape until its line
    /// has arrived.
    ///
    /// Named `trailShape` rather than `shape` because the property it feeds is
    /// called that, and a static member sharing a stored property's name is
    /// unreachable through `Self.` from inside the initialiser that sets it.
    static func trailShape(roundtrip: String?, route: [RouteCoordinate]) -> TrailShape? {
        switch roundtrip?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "yes": return .loop
        case "no": return .pointToPoint
        default: break
        }
        guard let first = route.first, let last = route.last, route.count > 2 else {
            return nil
        }
        let gap = RouteGeometry.distanceMeters(
            from: first.clCoordinate,
            to: last.clCoordinate
        )
        return gap <= loopToleranceMeters ? .loop : .pointToPoint
    }

    /// The web address `raw` names, if it names one this app will open.
    ///
    /// Scheme-checked rather than merely parsed. `URL(string:)` accepts a
    /// great deal that is not a web page, and what is being read here is a
    /// free-text field on a public database — so the two schemes a *website*
    /// tag can honestly mean are the two that are allowed through.
    static func link(_ raw: String?) -> URL? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else { return nil }
        return url
    }
}
