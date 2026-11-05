//
//  FailingLineFetch.swift
//  OpenHikesTests
//
//  ``SelectedLine``'s fetch, failing at the calls a test names. A real store
//  does not fail a fetch on demand, and a read that fails is the case a
//  reader has to tell from a row that is gone: see *A read that fails* in
//  `SelectedLine.swift` (#1333).
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Synchronization

/// ``SelectedLine``'s fetch, throwing at the calls it was told to, counting
/// from one, and the store's own answer at every other — held, at the call
/// it was told to hold, until the test opens it, as ``HeldLineFetch`` holds.
nonisolated final class FailingLineFetch: Sendable {
    private struct Failure: Error {}

    private let calls = Mutex(0)
    private let failing: Set<Int>
    private let heldCall: Int?
    private let release = DispatchSemaphore(value: 0)

    init(failing: Set<Int>, holding heldCall: Int? = nil) {
        self.failing = failing
        self.heldCall = heldCall
    }

    var count: Int { calls.withLock { $0 } }

    func fetch(_ context: ModelContext, _ id: PersistentIdentifier) throws -> Hike? {
        let call = calls.withLock { count in
            count += 1
            return count
        }
        if call == heldCall { release.wait() }
        if failing.contains(call) { throw Failure() }
        return try SelectedLine.fetchHike(context, id)
    }

    func open() { release.signal() }
}
