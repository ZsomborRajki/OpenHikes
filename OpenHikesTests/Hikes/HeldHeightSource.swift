//
//  HeldHeightSource.swift
//  OpenHikesTests
//
//  A height source that answers each question only when told to, and in
//  whatever order it is told.
//
//  Cancellation is cooperative: nothing in ``CuratedElevationSourcing``
//  promises that a question the trail maker has given up on returns before
//  the next one is asked. Two questions out at once, answered oldest first, is
//  the state ``TrailDraftElevation`` has to get right, and there is no way to
//  be in it against a source that answers immediately.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Synchronization

/// `final class` behind a `Mutex` rather than an actor, like the elevation
/// suite's own stub: the call arrives off the main actor, and the suite reads
/// what was asked between main-actor turns without suspending.
nonisolated final class HeldHeightSource: CuratedElevationSourcing, @unchecked Sendable {
    private struct Question {
        let pointCount: Int
        let continuation: CheckedContinuation<[Double], Never>
    }

    private struct State {
        var askedCounts: [Int] = []
        /// The questions not yet answered, by their number — the first
        /// question asked is 1.
        var waiting: [Int: Question] = [:]
    }

    private let state = Mutex(State())

    /// How many points each question asked about, in the order they were
    /// asked.
    var askedCounts: [Int] { state.withLock(\.askedCounts) }

    /// The numbers of the questions still waiting for an answer, lowest
    /// first.
    var outstanding: [Int] { state.withLock { $0.waiting.keys.sorted() } }

    @concurrent
    func heights(at coordinates: [CLLocationCoordinate2D]) async -> [Double] {
        await withCheckedContinuation { continuation in
            state.withLock { current in
                current.askedCounts.append(coordinates.count)
                current.waiting[current.askedCounts.count] = Question(
                    pointCount: coordinates.count,
                    continuation: continuation
                )
            }
        }
    }

    /// Answers question `number` with `heights`, cycled to the length it asked
    /// about — the source refuses an answer of the wrong length, and that is
    /// not what any case here is about.
    func answer(_ number: Int, with heights: [Double]) {
        guard let question = state.withLock({ $0.waiting.removeValue(forKey: number) }) else { return }
        question.continuation.resume(
            returning: (0..<question.pointCount).map { heights[$0 % heights.count] }
        )
    }

    /// Answers everything still out, so no case leaves a task suspended
    /// forever behind it.
    func answerAll(with heights: [Double]) {
        for number in outstanding { answer(number, with: heights) }
    }
}
