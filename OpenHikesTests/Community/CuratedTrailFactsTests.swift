//
//  CuratedTrailFactsTests.swift
//  OpenHikesTests
//
//  What a signpost says, read off tags nobody in this project wrote.
//
//  ``CuratedTrailFacts`` is the half of a curated route that a published hike
//  has no equivalent for — a blaze colour, a painted number, where the path
//  begins and where it ends. Every one of those is free text on a database
//  anybody may edit, which is why almost every case below is about the *bad*
//  shape of a tag rather than the good one: the colour that is not a colour,
//  the `osmc:symbol` component that looks like one and is not, the `website`
//  that is a `javascript:` URL, the `from` that is one space. The good shapes
//  get a line each, because they are the half that has never broken.
//
//  Nothing here needs a transport seam, and that is the argument for testing
//  these types rather than the actor around them: a tag dictionary and an
//  array of coordinates are the entire input, and they are the same two
//  objects whether they arrived from Overpass, from
//  ``SeededCuratedTrailSource``, or from the literals below.
//
//  No formatted figure is asserted anywhere in here, deliberately. These
//  fields are text OpenStreetMap already wrote; the length drawn beside them
//  is measured and formatted elsewhere, and this machine's simulator region is
//  not the region it measures in.
//

import Foundation
@testable import OpenHikes
import Testing

/// The four fact types a curated route's detail rows are built from.
@Suite("Curated trail facts")
struct CuratedTrailFactsTests {
    // MARK: - Fixtures

    /// The Berchtesgaden box every measurement behind this feature was taken
    /// in. Any point on earth would do — the shape rules are about a gap in
    /// metres and not about where the gap is — but a real one keeps the
    /// fixtures below readable as a place.
    private static let startLatitude = 47.63
    private static let startLongitude = 12.98

    /// Metres in one degree of latitude on the sphere ``RouteGeometry``
    /// measures on: its 6_371_008.8 m radius times a degree in radians.
    ///
    /// Spelled out so ``line(endGapMeters:)`` can be asked for a gap in the
    /// unit ``CuratedTrailFacts/loopToleranceMeters`` is stated in, rather
    /// than leaving a reader to work out what 0.0013° of latitude is meant to
    /// mean.
    private static let metersPerDegreeLatitude = 111_194.9

    /// How far either side of the tolerance the two boundary cases sit. Wide
    /// enough that the approximation above cannot be the thing deciding them,
    /// narrow enough that they are still about the tolerance.
    private static let toleranceMargin = 40.0

    /// One relation's tags in the shape the Alpine boxes actually carry them:
    /// an `osmc:symbol`, a `ref`, an `operator`, a `from`/`to` pair.
    ///
    /// `name`, `network` and `distance` are here because real relations carry
    /// them and none of them reaches a field on these facts — `distance` most
    /// deliberately of the three. It is tagged on 2% of Alpine relations, and
    /// the length drawn on a row is always measured from the line that is
    /// actually drawn.
    private static let hochkalterTags = [
        "name": "Wimbachgries — Hochkalter",
        "route": "hiking",
        "network": "lwn",
        "osmc:symbol": "red:red:white_bar:411:black",
        "ref": "411",
        "from": "Ramsau bei Berchtesgaden",
        "to": "Hintersee",
        "via": "Wimbachklamm",
        "operator": "Deutscher Alpenverein, Sektion Berchtesgaden",
        "website": "https://www.alpenverein-berchtesgaden.de/touren/411",
        "distance": "11.4",
    ]

    private static func facts(
        _ tags: [String: String] = [:],
        route: [RouteCoordinate] = []
    ) -> CuratedTrailFacts {
        CuratedTrailFacts(tags: tags, route: route)
    }

    private static func waymark(
        symbol: String? = nil,
        colour: String? = nil,
        reference: String? = nil
    ) -> TrailWaymark? {
        TrailWaymark(osmcSymbol: symbol, colour: colour, reference: reference)
    }

    /// A line running north whose two ends are `endGapMeters` apart.
    ///
    /// Three points rather than two, because a line of two is refused before
    /// its gap is ever measured — see `aTwoPointLineIsNotAShape`, which is
    /// the case that says so.
    private static func line(endGapMeters: Double) -> [RouteCoordinate] {
        let ridgeDegrees = 1000.0 / metersPerDegreeLatitude
        let endDegrees = endGapMeters / metersPerDegreeLatitude
        return [
            RouteCoordinate(latitude: startLatitude, longitude: startLongitude),
            RouteCoordinate(latitude: startLatitude + ridgeDegrees, longitude: startLongitude),
            RouteCoordinate(latitude: startLatitude + endDegrees, longitude: startLongitude),
        ]
    }

    // MARK: - The colour vocabulary

    /// Every case has to be reachable from the tag it is written as, because
    /// the raw value *is* the parser: a case renamed for how it reads on
    /// screen and not for how OSM spells it would silently stop matching, and
    /// the only symptom would be a swatch that quietly went missing.
    @Test("every colour is reachable from the word OSM writes it as", arguments: WaymarkColour.allCases)
    func everyColourRoundTripsThroughItsTag(colour: WaymarkColour) {
        #expect(WaymarkColour(osmColour: colour.rawValue) == colour)
        #expect(!colour.displayName.isEmpty)
    }

    /// Hand-edited text arrives shouted, padded and newline-terminated, and
    /// all three spellings are the same colour on the ground.
    @Test("a colour survives the casing and the padding it was typed with")
    func colourIsTrimmedAndLowercased() {
        #expect(WaymarkColour(osmColour: "  RED\n") == .red)
        #expect(WaymarkColour(osmColour: "Yellow") == .yellow)
    }

    /// The case the closed vocabulary exists for. An unrecognised colour has
    /// to become *no swatch*, never a default one: a route blazed turquoise
    /// and drawn grey tells a hiker something about the paint on the rock
    /// that is not true, where a route with no swatch at all tells them
    /// nothing and is right.
    ///
    /// `rot` and `vert` are in here because the tag is written by mappers in
    /// their own language often enough to matter, and `#c41e3a` because a
    /// `colour` tag is also allowed to be a hex triplet — neither is a case,
    /// and neither may guess at one.
    @Test(
        "a colour outside the vocabulary is no colour rather than a default one",
        arguments: ["turquoise", "pink", "rot", "vert", "#c41e3a", "", "   ", nil] as [String?]
    )
    func unknownColourIsNoColour(raw: String?) {
        #expect(WaymarkColour(osmColour: raw) == nil)
    }

    // MARK: - What is painted on the rock

    /// The whole of what `osmc:symbol` is read for. `red:red:white_bar:411:black`
    /// is a red route: the first component is the colour, and the components
    /// after it describe a background, a shape and a foreground that this app
    /// draws none of.
    @Test("the first component of osmc:symbol is the colour")
    func firstSymbolComponentIsTheColour() throws {
        let waymark = try #require(Self.waymark(symbol: "red:red:white_bar:411:black", reference: "411"))

        #expect(waymark.colour == .red)
        #expect(waymark.reference == "411")
    }

    /// The other real shape of the tag: an empty background component, which
    /// makes `yellow::yellow_diamond` three components of which the middle is
    /// nothing. It parses only because the split is told to keep empty
    /// subsequences — dropping them would slide `yellow_diamond` into second
    /// place and, on a symbol whose *first* component were empty, would put a
    /// shape name where the colour belongs.
    @Test("an osmc:symbol with an empty background still names its colour")
    func emptyBackgroundComponentStillParses() {
        #expect(Self.waymark(symbol: "yellow::yellow_diamond")?.colour == .yellow)
    }

    /// The guard against reading the wrong component. Every part of
    /// `blue:white:blue_bar` is a word this vocabulary knows, so a parser that
    /// took the background or searched for the first recognisable word would
    /// answer white here and be wrong in a way nothing else would catch.
    @Test("a later component that looks like a colour is not the colour")
    func laterComponentsAreNotRead() {
        #expect(Self.waymark(symbol: "blue:white:blue_bar")?.colour == .blue)
    }

    /// `osmc:symbol` is on roughly every named route, but `colour` alone is
    /// what a relation tagged by hand in one evening tends to carry.
    @Test("a route with no osmc:symbol falls back to its colour tag")
    func colourTagIsTheFallback() {
        #expect(Self.waymark(colour: " Green ")?.colour == .green)
    }

    /// Two tags that disagree is an ordinary state for a relation several
    /// people have edited, so the order has to be decided rather than
    /// discovered. `osmc:symbol` is the waymarking vocabulary and wins.
    @Test("osmc:symbol wins over a colour tag that disagrees with it")
    func symbolOutranksTheColourTag() {
        #expect(Self.waymark(symbol: "red:red:white_bar", colour: "blue")?.colour == .red)
    }

    /// The fallback is a fallback for an *unusable* symbol as well as an
    /// absent one. A relation whose symbol names a colour there is no swatch
    /// for, beside a plain `colour` tag there is one for, keeps the swatch.
    @Test("an unusable osmc:symbol still falls back to the colour tag")
    func unknownSymbolColourFallsBack() {
        #expect(Self.waymark(symbol: "turquoise::bar", colour: "blue")?.colour == .blue)
    }

    /// "" is not a waymark, and a row saying nothing is worse than no row. The
    /// four ways a relation reaches this with nothing to paint: no tags at
    /// all, three empty strings, a symbol whose colour component is empty
    /// beside a blank `ref`, and a colour nobody has a swatch for with no
    /// number behind it.
    @Test("a relation with nothing painted on it has no waymark")
    func nothingPaintedIsNoWaymark() {
        #expect(Self.waymark() == nil)
        #expect(Self.waymark(symbol: "", colour: "", reference: "") == nil)
        #expect(Self.waymark(symbol: "::white_bar", reference: "  ") == nil)
        #expect(Self.waymark(symbol: "turquoise::bar", colour: "rot") == nil)
    }

    /// Both halves are optional independently, and a signpost carrying one of
    /// them is the common case rather than a degraded one. The wording is the
    /// assertion: *waymark* is the word that stops "Red" reading as a second
    /// measurement beside the distance, and that turns the figure 411 into a
    /// thing painted on a rock.
    @Test("the waymark reads as a signpost whichever halves it has")
    func displayNameCoversEveryCombination() {
        let both = Self.waymark(symbol: "red:red:white_bar:411:black", reference: "411")

        #expect(both?.displayName == "Red waymark 411")
        #expect(Self.waymark(colour: "red")?.displayName == "Red waymark")
        #expect(Self.waymark(reference: "411")?.displayName == "Waymark 411")
    }

    /// The fourth combination, which the initialiser refuses to build — so
    /// what is pinned here is both halves of that: that it is refused, and
    /// that the empty branch behind it renders as nothing rather than as a
    /// stray "waymark" with nothing beside it, for whoever reaches it by
    /// clearing a field later.
    @Test("an empty waymark is refused, and renders as nothing if one is made")
    func emptyWaymarkIsRefusedAndRendersAsNothing() throws {
        #expect(Self.waymark() == nil)

        var waymark = try #require(Self.waymark(colour: "red", reference: "411"))
        waymark.colour = nil
        waymark.reference = nil

        #expect(waymark.displayName.isEmpty)
    }

    /// A `ref` is a painted number and a painted number is short, but this one
    /// is a free-text column on a public database and the row it lands in is
    /// drawn beside a distance. Bounded rather than refused, on the argument
    /// ``CommunityListingTextTests`` makes for a title: cut text still says
    /// which waymark this is.
    @Test("an over-long ref is bounded rather than drawn")
    func referenceIsBounded() throws {
        let sent = String(repeating: "4", count: TextBound.credit.characters * 10)

        let waymark = try #require(Self.waymark(reference: sent))

        #expect(waymark.reference?.count == TextBound.credit.characters)
    }

    // MARK: - Loop or not

    /// The tag is believed over the geometry, and this is the case that is
    /// only right because of it: a route whose two ends are four kilometres
    /// apart looks like a point-to-point from the endpoints alone, and a
    /// mapper who wrote `roundtrip=yes` knows something the endpoints do not
    /// show — most often a relation that stops short of closing itself.
    @Test("roundtrip=yes is believed over ends that are a valley apart")
    func roundtripTagBeatsDistantEnds() {
        let shape = CuratedTrailFacts.trailShape(roundtrip: "yes", route: Self.line(endGapMeters: 4000))

        #expect(shape == .loop)
    }

    /// And the same in the other direction, which is the half that keeps the
    /// rule honest: a tagged point-to-point whose two ends happen to be in one
    /// car park — an out-and-back sharing its trailhead — is not a loop
    /// because the geometry says so.
    @Test("roundtrip=no is believed over ends in the same car park")
    func roundtripTagBeatsCloseEnds() {
        let shape = CuratedTrailFacts.trailShape(roundtrip: "no", route: Self.line(endGapMeters: 20))

        #expect(shape == .pointToPoint)
    }

    @Test("the roundtrip tag survives the casing and padding it was typed with")
    func roundtripTagIsTrimmedAndLowercased() {
        #expect(CuratedTrailFacts.trailShape(roundtrip: " YES\n", route: []) == .loop)
        #expect(CuratedTrailFacts.trailShape(roundtrip: "No ", route: []) == .pointToPoint)
    }

    /// `roundtrip` is a yes/no key and is nonetheless written as prose, as a
    /// number and in other languages. None of those is an answer, and falling
    /// through to the geometry is better than guessing which way they lean —
    /// the geometry is measured and `circular` is somebody's typing.
    @Test(
        "a roundtrip value nobody documented falls through to the line",
        arguments: ["circular", "1", "true", "ja", "unknown"]
    )
    func undocumentedRoundtripValueFallsThrough(raw: String) {
        let shape = CuratedTrailFacts.trailShape(roundtrip: raw, route: Self.line(endGapMeters: 20))

        #expect(shape == .loop)
    }

    /// The generous half of the tolerance, and what it is generous for: a
    /// relation drawn around a lake routinely begins and ends on opposite
    /// sides of the same car park, because that is where two different mappers
    /// stopped drawing. A hundred metres of tarmac is one place to the person
    /// walking it.
    @Test("two ends inside the tolerance are one place")
    func endsInsideToleranceAreALoop() {
        let gap = CuratedTrailFacts.loopToleranceMeters - Self.toleranceMargin
        let shape = CuratedTrailFacts.trailShape(roundtrip: nil, route: Self.line(endGapMeters: gap))

        #expect(shape == .loop)
    }

    /// The tight half, which is the one a hiker is let down by if it slips: a
    /// route called a loop that ends somewhere else is a hiker who parked in
    /// the wrong place, and every metre the tolerance grows buys another
    /// out-and-back that gets called one.
    @Test("two ends beyond the tolerance are two places")
    func endsBeyondToleranceArePointToPoint() {
        let gap = CuratedTrailFacts.loopToleranceMeters + Self.toleranceMargin
        let shape = CuratedTrailFacts.trailShape(roundtrip: nil, route: Self.line(endGapMeters: gap))

        #expect(shape == .pointToPoint)
    }

    /// The listing pass. Rows arrive with their tags and without their lines,
    /// so an untagged relation has *no* answer at that point rather than a
    /// provisional one — and a shape row that appeared as a guess and then
    /// changed when the geometry landed would be worse than a row that
    /// arrived late.
    @Test("no tag and no line is no answer")
    func nothingToGoOnIsNil() {
        #expect(CuratedTrailFacts.trailShape(roundtrip: nil, route: []) == nil)
        #expect(Self.facts().shape == nil)
    }

    /// A relation that is one unbroken way arrives as two points, and they are
    /// not "a pair of endpoints rather than a walk" — they are exactly the two
    /// ends of the walk, which is the only thing this reads. Refusing them
    /// would drop the shape from the row's subtitle, the map callout and the
    /// *On the Trail* section for a trail that plainly has one.
    ///
    /// Two is also the shortest line that can arrive: ``CuratedTrailDecoding``
    /// keeps a member way only while it has more than one point, and
    /// ``CuratedTrailDecoding/assemble(_:)`` answers empty for a set whose
    /// total length is zero. So there is no degenerate shorter case below this
    /// to exclude.
    @Test("a line of two points has a shape, because two ends are all this reads")
    func aTwoPointLineIsAShape() {
        let gapDegrees = (CuratedTrailFacts.loopToleranceMeters + Self.toleranceMargin)
            / Self.metersPerDegreeLatitude
        let open = [
            RouteCoordinate(latitude: Self.startLatitude, longitude: Self.startLongitude),
            RouteCoordinate(
                latitude: Self.startLatitude + gapDegrees,
                longitude: Self.startLongitude
            ),
        ]

        #expect(CuratedTrailFacts.trailShape(roundtrip: nil, route: open) == .pointToPoint)
    }

    /// The two words the rows are drawn with, and the reason the distinction
    /// is worth a row at all: *Loop* means the car is where it was left, and
    /// *Point to point* means somebody has to come back for it. Pinned here
    /// because the case names are what the rest of this file reasons in and
    /// the words are what a hiker reads, and nothing else in the app would
    /// notice the two drifting apart.
    @Test("each shape is worded for the decision it decides")
    func shapesAreWordedForTheDecisionTheyDecide() {
        #expect(TrailShape.loop.displayName == "Loop")
        #expect(TrailShape.pointToPoint.displayName == "Point to point")
    }

    // MARK: - The website row

    /// The two schemes a `website` tag can honestly mean. The uppercase one is
    /// in here because the tag is typed by hand and a scheme compared without
    /// being lowercased would drop a perfectly good link.
    @Test(
        "an ordinary web address is kept",
        arguments: [
            "https://www.alpenverein-berchtesgaden.de/touren/411",
            "http://www.wanderwege.ch/route/411",
            "HTTPS://www.wandern.de/tour/hochkalter",
        ]
    )
    func webAddressesAreKept(raw: String) {
        #expect(CuratedTrailFacts.link(raw) != nil)
    }

    /// Padding is stripped rather than carried into the URL, which is the
    /// difference between a link and a link with a newline in it.
    @Test("a padded address is trimmed rather than refused")
    func paddedAddressIsTrimmed() throws {
        let url = try #require(CuratedTrailFacts.link("  https://www.wanderwege.ch/route/411\n"))

        #expect(url.absoluteString == "https://www.wanderwege.ch/route/411")
    }

    /// The reason this is scheme-checked rather than merely parsed. What is
    /// being read is a free-text field on a public database, and what it is
    /// handed to is `openURL` — so a `javascript:` or `file:` value is
    /// somebody else's decision about what this app opens, and `URL(string:)`
    /// accepts every one of them happily.
    ///
    /// `mailto:` and `ftp:` are not attacks and are refused all the same: the
    /// row says *website*, and a row that opens a half-composed mail is a row
    /// that lied about what tapping it does. A bare hostname is refused rather
    /// than guessed at, because guessing a scheme is how `file:` gets in.
    @Test(
        "an address that is not a web page is refused",
        arguments: [
            "javascript:alert(document.cookie)",
            "file:///etc/passwd",
            "ftp://example.org/trail.gpx",
            "mailto:info@alpenverein-berchtesgaden.de",
            "www.wanderwege.ch",
            "   ",
            "",
            nil,
        ] as [String?]
    )
    func nonWebAddressIsRefused(raw: String?) {
        #expect(CuratedTrailFacts.link(raw) == nil)
    }

    // MARK: - The journey row

    /// One row rather than two, because the pair is one fact: a hiker reading
    /// *From* on its own line and *To* on the next has to put them back
    /// together to learn the thing either was for.
    @Test("both ends read as one journey")
    func journeyReadsAsOneSentence() {
        #expect(Self.facts(Self.hochkalterTags).journey == "Ramsau bei Berchtesgaden to Hintersee")
    }

    /// `from` and `to` are tagged on roughly 59% of Alpine relations, and not
    /// as a pair — one without the other is ordinary, and has to read as a
    /// sentence on its own rather than as half of one.
    @Test("one end alone still reads as a sentence")
    func oneEndedJourneysAreWorded() {
        #expect(Self.facts(["from": "Ramsau bei Berchtesgaden"]).journey == "From Ramsau bei Berchtesgaden")
        #expect(Self.facts(["to": "Hintersee"]).journey == "To Hintersee")
    }

    /// A tag that is present and blank is the same as an absent one, and the
    /// case that proves it is the one where the two would differ on screen:
    /// without the bounding underneath, this renders as "Ramsau to " with the
    /// sentence walked off the end of the row.
    @Test("a blank end is an absent end")
    func blankEndDegradesToTheOneSidedSentence() {
        let facts = Self.facts(["from": "Ramsau", "to": "  \n "])

        #expect(facts.destination == nil)
        #expect(facts.journey == "From Ramsau")
    }

    @Test("a route that says neither end has no journey")
    func neitherEndIsNoJourney() {
        #expect(Self.facts().journey == nil)
    }

    // MARK: - Whether the section appears at all

    /// A relation with nothing but a name and a line is a real and common
    /// thing, and the section that draws these is absent rather than empty
    /// when it happens — the rule every late-arriving section on this screen
    /// already follows.
    @Test("a relation with nothing to say has no section")
    func nothingToSayIsEmpty() {
        #expect(Self.facts().isEmpty)
    }

    /// Any one field is enough to be worth a section, so each is checked on
    /// its own: a field quietly left out of `isEmpty` would hide a whole
    /// section for exactly the relations that only carry that field.
    @Test(
        "any single fact is enough to draw the section",
        arguments: [
            ["osmc:symbol": "red:red:white_bar:411:black"],
            ["colour": "blue"],
            ["ref": "411"],
            ["roundtrip": "yes"],
            ["from": "Ramsau bei Berchtesgaden"],
            ["to": "Hintersee"],
            ["via": "Wimbachklamm"],
            ["operator": "Deutscher Alpenverein, Sektion Berchtesgaden"],
            ["website": "https://www.alpenverein-berchtesgaden.de/touren/411"],
        ]
    )
    func anySingleFactFillsTheSection(tags: [String: String]) {
        #expect(!Self.facts(tags).isEmpty)
    }

    /// The case that matters more than any single-field one: a relation
    /// covered in tags that all turn out to say nothing. Every field here is
    /// present in the dictionary and every one of them is dropped — blank
    /// text, a colour with no swatch, a `roundtrip` value that is not an
    /// answer, a website that is not a web page — and what must not happen is
    /// a section drawn with nothing in it because the tags were counted
    /// rather than the facts.
    @Test("tags that are present and say nothing leave the section absent")
    func tagsThatSayNothingLeaveTheSectionAbsent() {
        let facts = Self.facts([
            "osmc:symbol": "turquoise::bar",
            "colour": "  ",
            "ref": " ",
            "roundtrip": "circular",
            "from": "\n",
            "to": "",
            "via": "   ",
            "operator": " ",
            "website": "javascript:alert(document.cookie)",
        ])

        #expect(facts.isEmpty)
    }

    /// The whole of a well-tagged relation, read once end to end, so the
    /// mapping from tag key to field is pinned somewhere: `operator` is the
    /// maintainer and `via` is not the journey, and either could be swapped
    /// for the other without a single case above noticing.
    ///
    /// The shape comes from the line rather than a tag, because this
    /// relation carries no `roundtrip` — as 85% of Alpine relations do not.
    @Test("a fully tagged relation fills every row")
    func fullyTaggedRelationFillsEveryRow() {
        let facts = Self.facts(Self.hochkalterTags, route: Self.line(endGapMeters: 20))

        #expect(facts.waymark?.displayName == "Red waymark 411")
        #expect(facts.shape == .loop)
        #expect(facts.journey == "Ramsau bei Berchtesgaden to Hintersee")
        #expect(facts.via == "Wimbachklamm")
        #expect(facts.maintainer == "Deutscher Alpenverein, Sektion Berchtesgaden")
        #expect(facts.website?.absoluteString == Self.hochkalterTags["website"])
        #expect(!facts.isEmpty)
    }
}
