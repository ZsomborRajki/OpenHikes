//
//  AutoPauseEvidenceTests.swift
//  OpenHikesSharedTests
//
//  That a recorded stop can be written down, read back and shown to the watch
//  again with the same answer the recorder got, timer included.
//

import Foundation
@testable import OpenHikesShared
import Testing

// swiftlint:disable no_magic_numbers

@Suite("Auto-pause evidence")
struct AutoPauseEvidenceTests {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)
    private static let trailhead = 47.63
    private static let metersPerDegree = WatchGeodesy.earthRadiusMeters * .pi / 180

    /// A fix `north` metres up the path from the trailhead.
    private static func fix(
        north: Double,
        at seconds: TimeInterval,
        accuracy: Double = 8,
        elevation: Double? = nil,
        speed: Double? = nil,
        motion: AutoPauseWatch.Motion = .unknown
    ) -> AutoPauseWatch.Fix {
        AutoPauseWatch.Fix(
            latitude: trailhead + north / metersPerDegree,
            longitude: 12.86,
            timestamp: start.addingTimeInterval(seconds),
            horizontalAccuracy: accuracy,
            elevation: elevation,
            speed: speed,
            motion: motion
        )
    }

    @Test("a record is read back as it was written")
    func roundTrip() {
        let records: [AutoPauseEvidence.Record] = [
            .fix(Self.fix(north: 1.0 / 3, at: 0.25, elevation: 612.4, speed: 1.3, motion: .onFoot), kept: true),
            .fix(Self.fix(north: 0, at: 10, accuracy: 65), kept: false),
            .motion(.stationary, at: Self.start.addingTimeInterval(42.5)),
            .motion(.carried, at: Self.start.addingTimeInterval(90)),
        ]

        let read = records.map(AutoPauseEvidence.line(for:)).map(AutoPauseEvidence.record(from:))

        #expect(read == records)
    }

    @Test(
        "a line that is not a record is skipped",
        arguments: ["", "time,latitude,longitude", "fix,1,2,3", "motion,later,stationary", "fix,1,2,3,4,,,flying,1"]
    )
    func otherLines(line: String) {
        #expect(AutoPauseEvidence.record(from: line) == nil)
    }

    /// A bench: two fixes, then nothing for twenty minutes, then the walk
    /// away. No record falls on the fifth minute, so only the timer can have
    /// called the stop then.
    @Test("a replay rings the recorder's timer between records")
    func replayRingsTheTimer() {
        let records: [AutoPauseEvidence.Record] = [
            .fix(Self.fix(north: 0, at: 0), kept: true),
            .fix(Self.fix(north: 2, at: 40), kept: false),
            .fix(Self.fix(north: 33, at: 1200, speed: 1), kept: true),
            .fix(Self.fix(north: 67, at: 1230, speed: 1), kept: true),
        ]

        let decisions = AutoPauseEvidence.replay(records)

        #expect(decisions == [
            AutoPauseEvidence.Decision(at: Self.start.addingTimeInterval(300), event: .stopped(since: Self.start)),
            AutoPauseEvidence.Decision(
                at: Self.start.addingTimeInterval(1230),
                event: .departed(since: Self.start.addingTimeInterval(1200))
            ),
        ])
    }

    @Test("a replay hears each change of motion")
    func replayLooksAtMotion() {
        let satDown: [AutoPauseEvidence.Record] = [
            .fix(Self.fix(north: 0, at: 0), kept: true),
            .motion(.stationary, at: Self.start.addingTimeInterval(20)),
        ]
        let walkedOn: [AutoPauseEvidence.Record] = [
            .motion(.onFoot, at: Self.start.addingTimeInterval(100)),
            .motion(.stationary, at: Self.start.addingTimeInterval(400)),
        ]

        #expect(AutoPauseEvidence.replay(satDown + [.motion(.unknown, at: Self.start.addingTimeInterval(400))]) == [
            AutoPauseEvidence.Decision(at: Self.start.addingTimeInterval(300), event: .stopped(since: Self.start)),
        ])
        #expect(AutoPauseEvidence.replay(satDown + walkedOn).isEmpty, "a silence walked in is the next fix's to decide")
    }

    @Test("a replay under another policy gives that policy's answer")
    func replayUnderAnotherPolicy() {
        var patient = AutoPausePolicy.standard
        patient.minimumStopSeconds = 600
        let records: [AutoPauseEvidence.Record] = [
            .fix(Self.fix(north: 0, at: 0), kept: true),
            .fix(Self.fix(north: 2, at: 400), kept: false),
        ]

        #expect(AutoPauseEvidence.replay(records).count == 1)
        #expect(AutoPauseEvidence.replay(records, policy: patient).isEmpty)
    }
}

// swiftlint:enable no_magic_numbers
