//
//  ResumeOnceTests.swift
//  OpenHikesTests
//
//  "Continuation resumption", split out of PhotoLibraryReaderTests.swift so
//  that a file declares one @Suite. That file's header still holds the
//  context the two share.
//

import Foundation
@testable import OpenHikes
import Photos
import Testing

@Suite("Continuation resumption")
struct ResumeOnceTests {
    private static let firstValue = 11
    private static let secondValue = 22
    private static let racers = [31, 32, 33, 34, 35, 36, 37, 38]

    /// The failure mode here is a crash rather than a wrong answer, which is
    /// why the guard exists and why this test is worth its length: without it
    /// the second `resume` is `SWIFT TASK CONTINUATION MISUSE`, a fatal error
    /// that takes the whole bundle down rather than failing one test.
    @Test("a callback that arrives twice resumes once, with the first value")
    func theSecondResumeIsDropped() async {
        let value: Int = await withCheckedContinuation { continuation in
            let gate = ResumeOnce(continuation)
            gate.resume(Self.firstValue)
            gate.resume(Self.secondValue)
        }
        #expect(value == Self.firstValue)
    }

    /// PhotoKit's callbacks arrive on a queue this app does not own, so two of
    /// them can be in flight at once. A check-then-set that is not atomic
    /// passes the sequential test above and fails here.
    @Test("callbacks racing each other resume the continuation once")
    func racingResumesResumeOnce() async {
        let value: Int = await withCheckedContinuation { continuation in
            let gate = ResumeOnce(continuation)
            for candidate in Self.racers {
                Task.detached { gate.resume(candidate) }
            }
        }
        #expect(Self.racers.contains(value))
    }

    /// Resuming from off the main actor is the shape the image callbacks
    /// actually have; the sequential test above resumes inline on whatever
    /// actor the test runs on and would not notice isolation being added.
    @Test("a callback delivered off the main actor still resumes")
    func aResumeFromOffTheMainActorArrives() async {
        let expected = Self.firstValue
        let value: Int = await withCheckedContinuation { continuation in
            let gate = ResumeOnce(continuation)
            Task.detached { gate.resume(expected) }
        }
        #expect(value == expected)
    }
}
