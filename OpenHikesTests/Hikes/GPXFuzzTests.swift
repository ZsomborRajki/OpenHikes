//
//  GPXFuzzTests.swift
//  OpenHikesTests
//
//  The contract every input has to satisfy, however damaged it is: the import
//  either produces a track that the rest of the app can hold, or it throws a
//  `GPXImport.ImportFailure`. Never a trap, never a hang, never a `Track`
//  carrying a value that poisons whatever reads it next.
//
//  The last clause is why this asserts against `RouteProfile` and
//  `HikeRouteStatistics` rather than only against the parser's own output. A
//  non-finite `<ele>` parsed *successfully* — the import was happy, and the
//  trap fired a screen later when the elevation chart asked for its y-domain.
//  A fuzz suite that only checks "did it throw" would have watched that go
//  past.
//
//  Sized to be cheap enough that nobody has a reason to delete it: a few
//  hundred cases over documents of a handful of points each, which is well
//  under a second. The bundle is `parallelizable: false`, so this suite's
//  time is every other suite's time too.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesShared
import Testing

@Suite("GPX fuzzing")
struct GPXFuzzTests {
    /// Cheap enough to keep, wide enough to be worth keeping. Raising this
    /// locally is the way to hunt: the seed is printed with every failure, so
    /// a case found at 20,000 draws can be pinned as a named sample afterwards
    /// and the count put back.
    private static let generatedCaseCount = 300

    @Test("no damaged document can trap, hang, or import something unusable", .timeLimit(.minutes(1)))
    func generatedCorpusHoldsTheContract() {
        let seed = SeededGenerator.defaultSeed
        let corpus = GPXFuzzCorpus.generated(count: Self.generatedCaseCount, seed: seed)

        #expect(corpus.count == Self.generatedCaseCount)
        Self.assertContract(over: corpus)
    }

    /// The generated corpus draws its corruptions at random, so on any single
    /// run it is likely but not guaranteed to have applied all of them. This
    /// makes each one a case in its own right, which is also what stops a
    /// corruption added to the enum from being silently untested.
    @Test("every kind of damage is exercised at least once", .timeLimit(.minutes(1)))
    func eachCorruptionHoldsTheContract() {
        let corpus = GPXFuzzCorpus.oneOfEach(seed: SeededGenerator.defaultSeed)

        #expect(corpus.count == GPXFuzzCorpus.all.count)
        Self.assertContract(over: corpus)
    }

    @Test("files that were never a good document to begin with", .timeLimit(.minutes(1)))
    func namedCorpusHoldsTheContract() {
        Self.assertContract(over: GPXFuzzCorpus.named)
    }

    /// Stacking the damage is the part a hand-written fixture cannot reach.
    /// Run over a wider draw than the standing corpus because the interesting
    /// interactions are rare, and kept separate so its cost is visible.
    @Test("damage stacked on damage still holds the contract", .timeLimit(.minutes(1)))
    func stackedDamageHoldsTheContract() {
        for offset in 0..<4 {
            let seed = SeededGenerator.defaultSeed &+ UInt64(offset) &* 0x9E37_79B9
            Self.assertContract(over: GPXFuzzCorpus.generated(count: 150, seed: seed))
        }
    }

    // MARK: Specific shapes, pinned by name

    /// The two spellings that reach `Double.init` intact and then lose every
    /// comparison they take part in. Named rather than left to the corpus
    /// because the failure they used to cause was a trap in a chart, a long
    /// way from anything with "GPX" in its name.
    @Test("a height that is not a number never becomes one", arguments: GPXFuzzCorpus.nonFiniteSpellings)
    func nonFiniteElevationsAreDropped(spelling: String) throws {
        let document = """
        <gpx><trk><trkseg>
        <trkpt lat="47.6" lon="12.8"><ele>\(spelling)</ele></trkpt>
        <trkpt lat="47.7" lon="12.9"><ele>700</ele></trkpt>
        </trkseg></trk></gpx>
        """
        let track = try Self.load(Data(document.utf8))

        #expect(track.points.count == 2, "a bad height must not cost the point its coordinate")
        #expect(track.points[0].elevation == nil, "\(spelling) was kept as an elevation")
        #expect(track.points[1].elevation == 700)
        let range = RouteProfile(route: track.route).elevationRange
        #expect(range == 700...700)
    }

    /// A stray end tag is the shape that makes an XML parser report the close
    /// of an element it never reported the open of, which is exactly the input
    /// a delegate keeping its own element stack can be walked off the end of.
    @Test("an end tag with nothing open never unbalances the parser's own stack")
    func strayEndTagsAreSurvivable() {
        let documents = [
            "</trkpt>",
            "<gpx></trkpt></gpx>",
            "<gpx><trk><trkseg></trkpt></trkseg></trk></gpx>",
            "<gpx><trk><trkseg><trkpt lat=\"47.6\" lon=\"12.8\"/></trkpt></trkseg></trk></gpx>",
            String(repeating: "</gpx>", count: 64),
        ]
        for document in documents {
            Self.assertOutcome(Data(document.utf8), label: document)
        }
    }

    /// Out-of-range coordinates are dropped, not clamped — a track claiming to
    /// pass within five degrees of a pole is bad data rather than something to
    /// silently move to the edge of the map. The check here is that dropping
    /// them leaves everything else intact.
    @Test("unprojectable points are dropped without taking the route with them")
    func outOfRangePointsAreDropped() throws {
        let document = """
        <gpx><trk><trkseg>
        <trkpt lat="91.0" lon="12.8"/>
        <trkpt lat="47.6" lon="12.8"/>
        <trkpt lat="47.6" lon="181.0"/>
        <trkpt lat="47.7" lon="12.9"/>
        <trkpt lat="NaN" lon="12.8"/>
        </trkseg></trk></gpx>
        """
        let track = try Self.load(Data(document.utf8))

        #expect(track.points.count == 2)
        #expect(track.points.allSatisfy { point in
            Mercator.isRepresentable(
                latitude: point.coordinate.latitude,
                longitude: point.coordinate.longitude
            )
        })
        #expect(track.distanceMeters > 0)
    }

    /// A file that is well-formed XML but simply isn't GPX parses cleanly into
    /// an empty document, so it cannot arrive as `.unreadable`. The distinction
    /// matters because the two failures send the reader somewhere different.
    @Test("a file that isn't GPX is refused for the reason it actually failed")
    func nonGPXIsRefusedAsUnusableRatherThanUnreadable() {
        let notGPX = Data("<html><body><p>Not a hike</p></body></html>".utf8)
        let notXML = Data("this is a photograph, not a track".utf8)

        #expect(throws: GPXImport.ImportFailure.noUsablePoints) {
            try Self.load(notGPX)
        }
        #expect(throws: GPXImport.ImportFailure.unreadable) {
            try Self.load(notXML)
        }
        #expect(throws: GPXImport.ImportFailure.unreadable) {
            try Self.load(Data())
        }
    }

    // MARK: The ceilings

    /// Exactly at the cap is allowed and one past it is refused, stated as a
    /// pair so the inclusive side is a decision rather than an accident.
    @Test("the point ceiling is inclusive at the cap and refuses the next one")
    func pointCeilingBoundary() throws {
        let cap = 50
        let limits = GPXImport.Limits(maximumFileSizeBytes: 1 << 20, maximumPointCount: cap)

        let atCap = try Self.load(
            Data(GPXFuzzCorpus.minimalPoints(cap).utf8),
            limits: limits
        )
        #expect(atCap.points.count == cap)

        #expect(throws: GPXImport.ImportFailure.tooLarge) {
            try Self.load(
                Data(GPXFuzzCorpus.minimalPoints(cap + 1).utf8),
                limits: limits
            )
        }
    }

    /// The same pair for the byte cap. Driven through a small injected limit
    /// rather than by serialising 32 MB: the boundary is the behaviour under
    /// test, and the shipping number is asserted separately as a number.
    @Test("the byte ceiling is inclusive at the cap and refuses the next one")
    func fileSizeCeilingBoundary() throws {
        let document = GPXFuzzCorpus.minimalPoints(8)
        let size = Data(document.utf8).count

        let atCap = try Self.load(
            Data(document.utf8),
            limits: GPXImport.Limits(maximumFileSizeBytes: size, maximumPointCount: 1000)
        )
        #expect(atCap.points.count == 8)

        #expect(throws: GPXImport.ImportFailure.tooLarge) {
            try Self.load(
                Data(document.utf8),
                limits: GPXImport.Limits(maximumFileSizeBytes: size - 1, maximumPointCount: 1000)
            )
        }
    }

    /// A refusal past the point cap has to be told apart from a malformed
    /// file: `XMLParser.parse()` reports an abort and a syntax error the same
    /// way, and the two reach the reader as different sentences.
    @Test("a truncated document past the point cap still reports the cap")
    func abortIsNotMistakenForMalformedInput() {
        let limits = GPXImport.Limits(maximumFileSizeBytes: 1 << 20, maximumPointCount: 4)
        var document = GPXFuzzCorpus.minimalPoints(40)
        document.removeLast("</trkseg></trk></gpx>".count)

        #expect(throws: GPXImport.ImportFailure.tooLarge) {
            try Self.load(Data(document.utf8), limits: limits)
        }
    }

    /// The shipping numbers themselves, so loosening one is a visible edit
    /// rather than a silent one.
    @Test("the shipping ceilings are the ones that were argued for")
    func standardLimitsAreUnchanged() {
        #expect(GPXImport.Limits.standard.maximumFileSizeBytes == 32 * 1024 * 1024)
        #expect(GPXImport.Limits.standard.maximumPointCount == 500_000)
    }

    // MARK: Contract

    /// Runs one corpus through the import and holds every outcome to the
    /// contract. Folds each case down to a single expectation rather than one
    /// per point: a few hundred documents of several points each would
    /// otherwise record tens of thousands of passing expectations, and the
    /// cost of recording them is most of what the suite would spend.
    private static func assertContract(over corpus: [MalformedGPXSample]) {
        for sample in corpus {
            assertOutcome(sample.bytes, label: sample.label)
        }
    }

    /// The `catch` is untyped-looking but isn't: `load` declares
    /// `throws(GPXImport.ImportFailure)`, so the compiler already guarantees
    /// the half of the contract that says nothing else escapes — which is
    /// worth more than an assertion would be, and is why there is no
    /// "something other than an ImportFailure was thrown" branch to write.
    private static func assertOutcome(_ bytes: Data, label: String) {
        do {
            let track = try load(bytes)
            if let complaint = complaint(about: track) {
                Issue.record("\(label): \(complaint)")
            }
        } catch {
            // A typed refusal is a pass. Reading the copy is not incidental:
            // an enum case added without it would present as a blank alert.
            if error.errorDescription == nil {
                Issue.record("\(label): \(error) has no message for the reader")
            }
        }
    }

    /// What is wrong with a track the import was willing to return, or `nil`.
    ///
    /// Deliberately walks the same two consumers the app puts a freshly
    /// imported track through — the elevation chart's y-domain and the stats
    /// grid — because "the parser returned" and "the app can draw it" are
    /// different claims and only the second one matters to a walker.
    private static func complaint(about track: GPXImport.Track) -> String? {
        guard track.distanceMeters.isFinite, track.distanceMeters >= 0 else {
            return "distance is \(track.distanceMeters)"
        }
        guard track.points.count == track.route.count else {
            return "\(track.points.count) points became \(track.route.count) route coordinates"
        }
        if let bad = track.points.first(where: { point in
            !Mercator.isRepresentable(
                latitude: point.coordinate.latitude,
                longitude: point.coordinate.longitude
            ) || (point.elevation.map { !$0.isFinite } ?? false)
        }) {
            return "kept an unusable point \(bad.coordinate) ele \(String(describing: bad.elevation))"
        }

        let profile = RouteProfile(route: track.route)
        if let range = profile.elevationRange,
           !range.lowerBound.isFinite || !range.upperBound.isFinite {
            return "elevation domain is \(range)"
        }
        let statistics = HikeRouteStatistics(
            distanceMeters: track.distanceMeters,
            route: track.route
        )
        if let speed = statistics.maxSpeed, !speed.value.isFinite {
            return "max speed is \(speed.value)"
        }
        if let duration = statistics.duration, !duration.isFinite || duration < 0 {
            return "duration is \(duration)"
        }
        return nil
    }

    /// Writes the bytes and imports them, because `load(from:)` takes a URL and
    /// the file-size ceiling is asked of the file system before the read — a
    /// seam that would go untested by anything handing the parser a `Data`.
    private static func load(
        _ bytes: Data,
        limits: GPXImport.Limits = .standard
    ) throws(GPXImport.ImportFailure) -> GPXImport.Track {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gpx-fuzz-\(UUID().uuidString).gpx")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try bytes.write(to: url, options: .atomic)
        } catch {
            throw .unreadable
        }
        return try GPXImport.load(from: url, limits: limits)
    }
}
