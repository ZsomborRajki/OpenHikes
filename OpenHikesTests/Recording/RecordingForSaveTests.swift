//
//  RecordingForSaveTests.swift
//  OpenHikesTests
//
//  What Stop prepares beside the line: the ends of the recording that were
//  not walked, which the saved hike says and *Edit Route* offers to take off
//  — see ``RecordingPreparation/forSave(points:startedAt:graph:gapDistances:)``.
//
//  The sections trail matching leaves a question on are the other half, held
//  by `RouteReviewTests` and `HikeRecorderTests+Checks.swift`.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

@Suite("Recording prepared for save")
struct RecordingForSaveTests {
    private enum Walk {
        static let start = Date(timeIntervalSince1970: 1_750_000_000)
        static let latitude = 47.63
        static let longitude = 12.86
        static let metersPerDegree = 111_000.0
        static let secondsPerFix: TimeInterval = 10
        /// A fix every ten metres: a metre a second.
        static let walkedStep = 10.0
        static let walkedFixes = 60
        /// A fix every hundred and fifty: fifteen metres a second.
        static let drivenStep = 150.0
        static let drivenFixes = 20
    }

    /// `count` fixes `step` metres apart, going north from `meters` along.
    private static func fixes(count: Int, step: Double, from meters: Double, at index: Int) -> [RecordingPoint] {
        (0..<count).map { offset in
            RecordingPoint(
                latitude: Walk.latitude + (meters + Double(offset + 1) * step) / Walk.metersPerDegree,
                longitude: Walk.longitude,
                timestamp: Walk.start.addingTimeInterval(Double(index + offset + 1) * Walk.secondsPerFix),
                horizontalAccuracy: 8
            )
        }
    }

    private static let origin = RecordingPoint(
        latitude: Walk.latitude,
        longitude: Walk.longitude,
        timestamp: Walk.start,
        horizontalAccuracy: 8
    )
    private static let walked = [origin] + fixes(count: Walk.walkedFixes, step: Walk.walkedStep, from: 0, at: 0)
    private static let walkedMeters = Double(Walk.walkedFixes) * Walk.walkedStep
    private static let driven = fixes(
        count: Walk.drivenFixes,
        step: Walk.drivenStep,
        from: walkedMeters,
        at: Walk.walkedFixes
    )

    @Test("a recording left running through the drive home is saved saying how far was not on foot")
    func theDriveIsSaidAtStop() async throws {
        let prepared = try await RecordingPreparation.forSave(
            points: Self.walked + Self.driven,
            startedAt: Walk.start,
            graph: nil,
            gapDistances: [:]
        )

        let ends = try #require(prepared.notOnFoot)
        #expect(ends.leadingMeters == nil)
        let carried = try #require(ends.trailingMeters)
        let drivenMeters = Double(Walk.drivenFixes) * Walk.drivenStep
        #expect(carried.isApproximatelyEqual(to: drivenMeters, absoluteTolerance: drivenMeters * 0.1))
        #expect(!ends.isChecked, "nobody has looked yet")
        #expect(prepared.assembly == nil, "with no trail graph there is no section to keep")
        #expect(prepared.route.count == Self.walked.count + Self.driven.count, "the line itself is saved whole")
    }

    @Test("a walk from start to finish says nothing")
    func aWalkSaysNothing() async throws {
        let prepared = try await RecordingPreparation.forSave(
            points: Self.walked,
            startedAt: Walk.start,
            graph: nil,
            gapDistances: [:]
        )

        #expect(prepared.notOnFoot == nil)
        #expect(prepared.assembly == nil)
    }
}
