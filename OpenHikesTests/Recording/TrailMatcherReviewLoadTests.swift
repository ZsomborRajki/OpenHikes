//
//  TrailMatcherReviewLoadTests.swift
//  OpenHikesTests
//
//  How much of an ordinary walk ends up on the review screen.
//
//  The matcher abstains from a leg far more often than it looks: over the
//  bundled 330-point walk, ordinary consumer GPS noise leaves 50-90 of its 329
//  legs below the confidence margin. That is not a defect — abstaining is the
//  conservative answer, and those legs are drawn as the raw fixes rather than
//  moved onto a trail nobody can vouch for.
//
//  It does mean the review screen is one rule away from being useless. Surface
//  every non-confident leg and an ordinary walk ends with 74-130 sections to
//  read, against 4-8 today; a prompt that appears in that shape after every
//  walk is worse than the silence it replaces, and would be a behaviour change
//  to a shipped flow. Surface none of them and a cut switchback corner is
//  never disclosed, which is the bug ``TrailMatcher/minimumDeclinedDetourMeters``
//  exists to fix.
//
//  So the rule has to hold at both ends, and the two ends are tested apart:
//  `TrailMatcherJunctionTests` proves the corner *is* offered, and this proves
//  an ordinary walk is still quiet. Neither is safe without the other.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Trail matcher review load")
struct TrailMatcherReviewLoadTests {
    /// Reproducible GPS noise. A fixed seed keeps the walk identical from run
    /// to run, so a change in the numbers below is a change in the matcher
    /// rather than in the draw.
    private struct SeededNoise {
        var state: UInt64 = 0xDEAD_BEEF

        mutating func unitInterval() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((state >> 11) & 0xFFFF_FFFF) / Double(0xFFFF_FFFF)
        }

        /// Box-Muller, so the offsets are normally distributed rather than
        /// uniform — a uniform draw never produces the occasional bad fix that
        /// is exactly what pushes a leg below the confidence margin.
        mutating func gaussian() -> Double {
            let uniform = max(1e-9, unitInterval())
            return (-2 * log(uniform)).squareRoot()
                * cos(2 * .pi * unitInterval())
        }
    }

    /// The bundled GPX walk, re-timed as a dense recording and jittered by
    /// `metres` of horizontal error.
    ///
    /// Three seconds between fixes puts every leg well inside both sparse
    /// thresholds — 90 s and 200 m — which is the point: this is the dense
    /// path, the one the sparse qualifier used to exclude from review
    /// entirely.
    private func walk(noise metres: Double) throws -> [RecordingPoint] {
        let url = try #require(
            Bundle.main.url(
                forResource: UITestTrailTagFixture.gpxName,
                withExtension: "gpx"
            ),
            "the app bundle should carry the GPX fixture UI tests import"
        )
        let route = try GPXImport.load(from: url).route
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var noiseSource = SeededNoise()
        return route.enumerated().map { index, coordinate in
            let metresPerDegreeLatitude = 111_320.0
            let latitudeOffset = metres * noiseSource.gaussian() / metresPerDegreeLatitude
            let longitudeOffset = metres * noiseSource.gaussian()
                / (metresPerDegreeLatitude * cos(coordinate.latitude * .pi / 180))
            return RecordingPoint(
                latitude: coordinate.latitude + latitudeOffset,
                longitude: coordinate.longitude + longitudeOffset,
                timestamp: start.addingTimeInterval(Double(index) * 3),
                horizontalAccuracy: max(5, metres),
                elevation: 600
            )
        }
    }

    private func graph() throws -> TrailGraph {
        let provider = try #require(
            BundledTrailGraphProvider(
                fixtureName: UITestTrailTagFixture.trailGraphName
            )
        )
        return try #require(provider.cachedGraph(covering: []))
    }

    @Test(
        "an ordinary walk does not fill the review screen",
        arguments: [0.0, 3.0, 5.0, 8.0]
    )
    func ordinaryWalkStaysQuiet(noise: Double) throws {
        let points = try walk(noise: noise)

        let result = TrailMatcher.match(points: points, graph: try graph())

        // Guard against passing vacuously. If the matcher ever became
        // confident about the whole walk there would be nothing to suppress,
        // and the assertion below would hold for the wrong reason.
        let legCount = points.count - 1
        #expect(result.matchedLegCount < legCount)
        // What those non-confident legs must not do is reach the walker. The
        // trail each of them declined is no longer than the line it drew
        // instead, so there is no lost distance to report and nothing to ask
        // about.
        #expect(result.ambiguities.isEmpty)
        #expect(result.ambiguousLegCount == 0)
        let sections = RouteReviewSection.sections(in: result)
        #expect(sections.allSatisfy { section in section.kind != .ambiguous })
    }

    /// The counter and the screen are the same number, by construction.
    ///
    /// They were once computed independently, and a dense leg the matcher was
    /// unsure about incremented neither — it was invisible to both.
    @Test("the ambiguous count is exactly what the walker is shown")
    func ambiguousCountMatchesTheOffers() throws {
        let result = TrailMatcher.match(
            points: try walk(noise: 5),
            graph: try graph()
        )

        #expect(result.ambiguousLegCount == result.ambiguities.count)
    }
}
