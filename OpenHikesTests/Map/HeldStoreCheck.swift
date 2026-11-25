//
//  HeldStoreCheck.swift
//  OpenHikesTests
//
//  ``SelectedLineStoreWatch``'s look at the store's history, held at its
//  start until the test opens it, so that something can happen while the
//  check is in flight: a selection that moves on, or an edit written while
//  the watch has yet to bring a saved row in.
//

import Foundation
@testable import OpenHikes
import Synchronization

/// Only checks made once it is armed are held, so the one a follow starts
/// with goes through.
nonisolated final class HeldStoreCheck: Sendable {
    private let gate = Mutex<(isOpen: Bool, waiting: [CheckedContinuation<Void, Never>])>((false, []))
    private let arrivals = Mutex<Int?>(nil)

    var arrived: Int { arrivals.withLock { $0 ?? 0 } }

    func arm() { arrivals.withLock { $0 = 0 } }

    func making(_ request: StoreHistoryCheck.Request) async -> StoreHistoryCheck.Answer {
        let isArmed = arrivals.withLock { count in
            count = count.map { $0 + 1 }
            return count != nil
        }
        guard isArmed else { return await StoreHistoryCheck.answer(request) }
        await withCheckedContinuation { continuation in
            let isOpen = gate.withLock { state in
                if !state.isOpen { state.waiting.append(continuation) }
                return state.isOpen
            }
            if isOpen { continuation.resume() }
        }
        return await StoreHistoryCheck.answer(request)
    }

    func open() {
        let waiting = gate.withLock { state in
            state.isOpen = true
            defer { state.waiting = [] }
            return state.waiting
        }
        for continuation in waiting { continuation.resume() }
    }
}
