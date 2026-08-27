//
//  GPXFuzzCorpus.swift
//  OpenHikesTests
//
//  Malformed GPX, generated reproducibly.
//
//  The import's fixtures had all been written by hand, which means they had
//  all been written by somebody who knew what a GPX file looks like — and the
//  file that breaks a parser is by definition one nobody thought to write. Two
//  real defects had already been found in this parser by reading it rather
//  than by running it, so the malformed-input surface was where the next one
//  was going to be.
//
//  Generated rather than enumerated because the interesting inputs are the
//  *combinations*: a truncation is harmless, a stray end tag is harmless, and
//  the pair of them together is a different code path. Seeded rather than
//  random because a corpus that cannot be regenerated reports a crash at an
//  input that no longer exists.
//

import Foundation

/// One generated input, carrying the recipe that produced it so a failure
/// names something a reader can act on rather than only a seed.
nonisolated struct MalformedGPXSample: Sendable {
    let label: String
    let bytes: Data
}

/// Builds GPX documents and then breaks them.
enum GPXFuzzCorpus {
    /// One named way to damage a document, carrying the edit it performs.
    ///
    /// A `CaseIterable` enum interpreted by a `switch` was the first shape and
    /// is the wrong one twice over: nineteen ways to break a file is nineteen
    /// branches in one function, and the `default:` such a split needs turns a
    /// newly added case into a silent no-op that every test still passes. A
    /// value holding its own edit has no branch to grow and cannot be declared
    /// without saying what it does.
    struct Corruption {
        let name: String
        let damage: (String, inout SeededGenerator) -> String
    }

    /// Every number this file needs, named. The values are arbitrary; what
    /// matters is that a coordinate is inside Mercator's range unless a
    /// corruption deliberately pushes it out, and that the documents stay
    /// small enough for a few hundred of them to cost nothing.
    private enum Shape {
        static let baseLatitude = 47.6
        static let baseLongitude = 12.8
        static let denseStep = 0.0001
        static let sparseStep = 0.001
        static let minimalStep = 0.00001
        static let baseElevation = 600
        static let outOfRangeLatitude = "91.0"
        static let shallowNesting = 200
        static let deepNesting = 2000
        static let exponentDigits = 400
        static let estimatedBytesPerPoint = 40
        static let latitudeCycle = 1000
        // The bytes below are the fixture rather than a quantity, so naming
        // each one individually would add `overlongEncodingLeadByte = 0xC0`
        // and say nothing the comment above it does not.
        // swiftlint:disable no_magic_numbers
        /// A UTF-16 little-endian mark in front of UTF-8 text, which is how a
        /// Windows exporter's output arrives when it has guessed wrong.
        static let utf16LittleEndianMark: [UInt8] = [0xFF, 0xFE]
        /// An overlong encoding, a lone surrogate half and a stray ASCII byte:
        /// bytes that are not text under any encoding the parser will try.
        static let undecodable: [UInt8] = [
            0xFF, 0xFE, 0x00, 0x00, 0xC0, 0x80, 0xED, 0xA0, 0x80, 0x41,
        ]
        // swiftlint:enable no_magic_numbers
        static let latin1Ceiling: UInt32 = 0x100
        static let questionMark: UInt8 = 0x3F
    }

    /// Spellings of a double that XML text permits and `Double.init` accepts,
    /// but that no elevation or coordinate can be.
    nonisolated static let nonFiniteSpellings = [
        "NaN", "nan", "-nan", "inf", "INF", "Infinity", "-Infinity",
        "1e400", "-1e400", "0x1p+1024",
    ]

    // MARK: Well-formed base documents

    /// A valid document with `pointCount` track points, used as the thing to
    /// break. Deliberately carries metadata, an elevation and a time on every
    /// point: a corruption is only interesting if there was something there to
    /// lose.
    static func wellFormed(pointCount: Int) -> String {
        let points = (0..<pointCount).map { index in
            let latitude = Shape.baseLatitude + Double(index) * Shape.denseStep
            let longitude = Shape.baseLongitude + Double(index) * Shape.denseStep
            let minute = String(format: "%02d", index % 60)
            return "<trkpt lat=\"\(latitude)\" lon=\"\(longitude)\">"
                + "<ele>\(Shape.baseElevation + index)</ele>"
                + "<time>2024-06-01T08:\(minute):00Z</time></trkpt>"
        }
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<gpx version=\"1.1\" creator=\"fuzz\""
            + " xmlns=\"http://www.topografix.com/GPX/1/1\">"
            + "<metadata><name>Fuzz Walk</name>"
            + "<time>2024-06-01T08:00:00Z</time></metadata>"
            + "<trk><name>Fuzz Track</name><trkseg>"
            + points.joined()
            + "</trkseg></trk></gpx>"
    }

    /// A document with exactly `pointCount` track points and nothing else, for
    /// driving the point ceiling. Kept minimal so a run at half a million
    /// points is a string operation rather than a memory problem of its own.
    static func minimalPoints(_ pointCount: Int) -> String {
        var body = ""
        body.reserveCapacity(pointCount * Shape.estimatedBytesPerPoint)
        for index in 0..<pointCount {
            let offset = Double(index % Shape.latitudeCycle) * Shape.minimalStep
            body += "<trkpt lat=\"\(Shape.baseLatitude + offset)\""
                + " lon=\"\(Shape.baseLongitude)\"></trkpt>"
        }
        return "<gpx version=\"1.1\"><trk><trkseg>\(body)</trkseg></trk></gpx>"
    }

    // MARK: Generated corpus

    /// `count` seeded samples. Each draws a base document, then applies one to
    /// three corruptions in sequence — the stacking is the point, since a
    /// parser that survives each damage alone can still be walked into a state
    /// no single one reaches.
    static func generated(count: Int, seed: UInt64) -> [MalformedGPXSample] {
        var generator = SeededGenerator(seed: seed)
        return (0..<count).map { index in
            var text = wellFormed(pointCount: Int.random(in: 1...6, using: &generator))
            var applied: [String] = []
            for _ in 0..<Int.random(in: 1...3, using: &generator) {
                guard let corruption = all.randomElement(using: &generator)
                else { continue }
                text = corruption.damage(text, &generator)
                applied.append(corruption.name)
            }
            return MalformedGPXSample(
                label: "seed \(seed) case \(index) [\(applied.joined(separator: "+"))]",
                bytes: bytes(from: text)
            )
        }
    }

    /// One sample per corruption, so the exhaustive sweep does not depend on
    /// a random draw having happened to reach every case.
    static func oneOfEach(seed: UInt64) -> [MalformedGPXSample] {
        var generator = SeededGenerator(seed: seed)
        return all.map { corruption in
            let damaged = corruption.damage(wellFormed(pointCount: 4), &generator)
            return MalformedGPXSample(
                label: "\(corruption.name) (seed \(seed))",
                bytes: bytes(from: damaged)
            )
        }
    }

    // MARK: Hand-written awkward documents

    /// The inputs that are not a corrupted good document but a different kind
    /// of file altogether, plus the specific shapes this parser has already
    /// been shown to mishandle. Named rather than generated so a regression in
    /// one of them reads as a sentence instead of as a seed.
    static let named: [MalformedGPXSample] = [
        sample("an empty file", ""),
        sample("nothing but whitespace", "   \n\t  \n"),
        sample("a lone BOM", "\u{FEFF}"),
        sample("valid XML that is not GPX", "<html><body><p>Not a hike</p></body></html>"),
        sample("a GPX root with nothing in it", "<gpx version=\"1.1\"></gpx>"),
        sample("a GPX root that never closes", "<gpx version=\"1.1\"><trk><trkseg>"),
        sample("an XML declaration and nothing else", "<?xml version=\"1.0\"?>"),
        sample("a track segment with no points", "<gpx><trk><trkseg></trkseg></trk></gpx>"),
        sample(
            "a track point with no attributes at all",
            "<gpx><trk><trkseg><trkpt></trkpt><trkpt></trkpt></trkseg></trk></gpx>"
        ),
        sample(
            "a closing tag with no opening tag",
            "<gpx><trk><trkseg></trkpt></trkseg></trk></gpx>"
        ),
        sample(
            "an end tag for an ancestor that is still open",
            "<gpx><trk><trkseg><trkpt lat=\"47.6\" lon=\"12.8\"></gpx>"
        ),
        sample("elevations that are not numbers", elevationDocument(nonFiniteSpellings)),
        sample("coordinates past the poles and the antimeridian", coordinateDocument([
            ("91.0", "12.8"), ("-91.0", "12.8"), ("47.6", "181.0"),
            ("47.6", "-181.0"), ("86.0", "12.8"), ("-0.0", "-0.0"),
        ])),
        sample("coordinates that are not numbers", coordinateDocument([
            ("", "12.8"), ("north", "12.8"), ("47.6", ""),
            ("NaN", "12.8"), ("47.6", "Infinity"), ("47,6", "12,8"),
        ])),
        sample(
            "a point count of one, which is parseable but not a route",
            "<gpx><trk><trkseg><trkpt lat=\"47.6\" lon=\"12.8\"/></trkseg></trk></gpx>"
        ),
        sample("times in every shape an exporter writes", timeDocument([
            "2024-06-01T08:00:00Z", "2024-06-01T08:00:00", "2024-06-01T08:00:00+02:00",
            "2024-06-01T08:00:00.123Z", "", "yesterday", "0000-00-00T00:00:00Z",
            "2024-06-01 08:00:00", "999999999999-06-01T08:00:00Z",
        ])),
        MalformedGPXSample(
            label: "bytes that are not text in any encoding",
            bytes: Data(Shape.undecodable)
        ),
        MalformedGPXSample(
            label: "a UTF-16 BOM on a UTF-8 document",
            bytes: Data(Shape.utf16LittleEndianMark) + Data(wellFormed(pointCount: 3).utf8)
        ),
        MalformedGPXSample(
            label: "a NUL in the middle of a track point",
            bytes: Data("<gpx><trk><trkseg><trkpt lat=\"47.6\" lon=\"1".utf8)
                + Data([0x00])
                + Data("2.8\"/></trkseg></trk></gpx>".utf8)
        ),
    ]

    // MARK: Corruptions

    /// Damage to the document's shape: tags, nesting, attributes, truncation.

    static let byteOrderMark = Corruption(name: "byteOrderMark") { text, _ in
        "\u{FEFF}" + text
    }

    static let deepNesting = Corruption(name: "deepNesting") { text, generator in
        let depth = Int.random(
            in: Shape.shallowNesting...Shape.deepNesting,
            using: &generator
        )
        return nested(text, depth: depth)
    }

    static let duplicateAttribute = Corruption(name: "duplicateAttribute") { text, _ in
        replaceFirst("<trkpt lat=", with: "<trkpt lat=\"1\" lat=", in: text)
    }

    static let mismatchedEndTag = Corruption(name: "mismatchedEndTag") { text, _ in
        replaceFirst("</trkpt>", with: "</trkseg>", in: text)
    }

    static let missingCoordinateAttribute = Corruption(
        name: "missingCoordinateAttribute"
    ) { text, _ in
        replaceFirst(" lon=", with: " nol=", in: text)
    }

    static let quoteInAttribute = Corruption(name: "quoteInAttribute") { text, _ in
        replaceFirst("<trkpt lat=\"", with: "<trkpt lat=\"\"><\"", in: text)
    }

    static let strayEndTag = Corruption(name: "strayEndTag") { text, _ in
        replaceFirst("<trkseg>", with: "<trkseg></trkpt></gpx>", in: text)
    }

    static let truncated = Corruption(name: "truncated") { text, generator in
        truncate(text, using: &generator)
    }

    static let unknownNamespace = Corruption(name: "unknownNamespace") { text, _ in
        replaceFirst("http://www.topografix.com/GPX/1/1", with: "urn:not:gpx", in: text)
    }

    static let unterminatedAttribute = Corruption(name: "unterminatedAttribute") { text, _ in
        replaceFirst("lon=\"12.8\"", with: "lon=\"12.8", in: text)
    }

    /// Damage to what the document says rather than to how it says it: values
    /// that parse as XML and then mean nothing.

    static let bareAmpersand = Corruption(name: "bareAmpersand") { text, _ in
        replaceFirst("Fuzz Walk", with: "Fuzz & Walk", in: text)
    }

    static let emptyCoordinateValue = Corruption(name: "emptyCoordinateValue") { text, _ in
        replaceFirstAttribute("lat", with: "", in: text)
    }

    static let garbageCoordinate = Corruption(name: "garbageCoordinate") { text, _ in
        replaceFirstAttribute("lon", with: "twelve point eight", in: text)
    }

    static let latin1Bytes = Corruption(name: "latin1Bytes") { text, _ in
        replaceFirst("Fuzz Walk", with: "Fuzz W\u{00E4}lk\u{00FF}", in: text)
    }

    static let nonFiniteElevation = Corruption(name: "nonFiniteElevation") { text, generator in
        let spelling = nonFiniteSpellings.randomElement(using: &generator) ?? "NaN"
        return replaceFirst(
            "<ele>\(Shape.baseElevation)</ele>",
            with: "<ele>\(spelling)</ele>",
            in: text
        )
    }

    static let nullByte = Corruption(name: "nullByte") { text, _ in
        replaceFirst("<ele>", with: "<ele>\u{0000}", in: text)
    }

    static let outOfRangeCoordinate = Corruption(name: "outOfRangeCoordinate") { text, _ in
        replaceFirstAttribute("lat", with: Shape.outOfRangeLatitude, in: text)
    }

    static let undefinedEntity = Corruption(name: "undefinedEntity") { text, _ in
        replaceFirst("Fuzz Walk", with: "&nbsp;&notreal;", in: text)
    }

    static let wildExponent = Corruption(name: "wildExponent") { text, _ in
        replaceFirstAttribute(
            "lat",
            with: "4" + String(repeating: "7", count: Shape.exponentDigits),
            in: text
        )
    }

    /// The sweep, and the pool the generated corpus draws from. A corruption
    /// missing from here is one no test runs, which is the price of dropping
    /// the enum — so the suite asserts this count rather than trusting it.
    static let all: [Corruption] = [
        bareAmpersand, byteOrderMark, deepNesting, duplicateAttribute,
        emptyCoordinateValue, garbageCoordinate, latin1Bytes, mismatchedEndTag,
        missingCoordinateAttribute, nonFiniteElevation, nullByte,
        outOfRangeCoordinate, quoteInAttribute, strayEndTag, truncated,
        undefinedEntity, unknownNamespace, unterminatedAttribute, wildExponent,
    ]

    private static func truncate(
        _ text: String,
        using generator: inout SeededGenerator
    ) -> String {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count > 1 else { return text }
        let cut = Int.random(in: 1..<scalars.count, using: &generator)
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[0..<cut])
        return String(view)
    }

    private static func nested(_ text: String, depth: Int) -> String {
        let open = String(repeating: "<wrap>", count: depth)
        let close = String(repeating: "</wrap>", count: depth)
        return replaceFirst("<trkseg>", with: "<trkseg>" + open + close, in: text)
    }

    // MARK: Document shapes

    private static func elevationDocument(_ elevations: [String]) -> String {
        let points = elevations.enumerated().map { index, elevation in
            let latitude = Shape.baseLatitude + Double(index) * Shape.sparseStep
            return "<trkpt lat=\"\(latitude)\" lon=\"\(Shape.baseLongitude)\">"
                + "<ele>\(elevation)</ele></trkpt>"
        }
        return "<gpx><trk><trkseg>\(points.joined())</trkseg></trk></gpx>"
    }

    private static func coordinateDocument(_ pairs: [(String, String)]) -> String {
        let points = pairs.map { latitude, longitude in
            "<trkpt lat=\"\(latitude)\" lon=\"\(longitude)\">"
                + "<ele>\(Shape.baseElevation)</ele></trkpt>"
        }
        return "<gpx><trk><trkseg>\(points.joined())</trkseg></trk></gpx>"
    }

    private static func timeDocument(_ times: [String]) -> String {
        let points = times.enumerated().map { index, time in
            let latitude = Shape.baseLatitude + Double(index) * Shape.sparseStep
            return "<trkpt lat=\"\(latitude)\" lon=\"\(Shape.baseLongitude)\">"
                + "<time>\(time)</time></trkpt>"
        }
        return "<gpx><trk><trkseg>\(points.joined())</trkseg></trk></gpx>"
    }

    // MARK: Helpers

    private static func sample(_ label: String, _ text: String) -> MalformedGPXSample {
        MalformedGPXSample(label: label, bytes: bytes(from: text))
    }

    /// Encodes as UTF-8 with a deliberate escape hatch: a corruption that
    /// produces a Latin-1 byte has to survive as *bytes*, because handing the
    /// parser a string Swift has already made valid would test nothing.
    private static func bytes(from text: String) -> Data {
        guard text.contains("\u{00FF}") else { return Data(text.utf8) }
        return Data(text.unicodeScalars.map { scalar in
            scalar.value < Shape.latin1Ceiling
                ? UInt8(scalar.value)
                : Shape.questionMark
        })
    }

    private static func replaceFirst(
        _ needle: String,
        with replacement: String,
        in text: String
    ) -> String {
        guard let range = text.range(of: needle) else { return text }
        return text.replacingCharacters(in: range, with: replacement)
    }

    private static func replaceFirstAttribute(
        _ name: String,
        with value: String,
        in text: String
    ) -> String {
        guard let start = text.range(of: "\(name)=\""),
              let end = text.range(of: "\"", range: start.upperBound..<text.endIndex)
        else { return text }
        return text.replacingCharacters(
            in: start.upperBound..<end.lowerBound,
            with: value
        )
    }
}
