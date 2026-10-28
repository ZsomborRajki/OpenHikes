//
//  HeldPlaceSearchSource.swift
//  OpenHikesTests
//
//  An injected point source whose requests and answers are observed through
//  continuations. It deliberately lets canceled requests answer when released,
//  so the caller's protection against late transport answers is exercised.
//

import Foundation
@testable import OpenHikes
import OpenHikesData

actor HeldPlaceSearchSource: TrailPointSourcing {
    private let answer: [TrailPlace]
    private(set) var calls = 0
    private(set) var cancelledCalls = 0
    private var answers = 0
    private var isHolding: Bool
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var started: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var finished: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(answer: [TrailPlace], holding: Bool = true) {
        self.answer = answer
        isHolding = holding
    }

    func places(near _: CommunitySearchArea, showing _: Set<TrailPlaceSymbol>) async -> [TrailPlace] {
        calls += 1
        let observers = started.filter { $0.count <= calls }
        started.removeAll { $0.count <= calls }
        for observer in observers { observer.continuation.resume() }
        if isHolding {
            await withCheckedContinuation { waiting.append($0) }
        }
        if Task.isCancelled { cancelledCalls += 1 }
        answers += 1
        let answered = finished.filter { $0.count <= answers }
        finished.removeAll { $0.count <= answers }
        for observer in answered { observer.continuation.resume() }
        return answer
    }

    func waitUntilAsked(_ count: Int = 1) async {
        guard calls < count else { return }
        await withCheckedContinuation { started.append((count, $0)) }
    }

    func waitUntilAnswered(_ count: Int = 1) async {
        guard answers < count else { return }
        await withCheckedContinuation { finished.append((count, $0)) }
    }

    func release() {
        isHolding = false
        let requests = waiting
        waiting = []
        for request in requests { request.resume() }
    }
}
