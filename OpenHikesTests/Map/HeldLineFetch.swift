//
//  HeldLineFetch.swift
//  OpenHikesTests
//
//  ``SelectedLine``'s fetch, held at one of its calls until the test opens
//  it, so that a read is still out while something else happens around it:
//  a tile drawn while a comparison waits, or a selection that moves on
//  before the read it started has landed.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Synchronization

nonisolated final class HeldLineFetch: Sendable {
    private let calls = Mutex(0)
    private let heldCall: Int
    private let release = DispatchSemaphore(value: 0)

    /// - Parameter heldCall: which call to hold, counting from one.
    init(holding heldCall: Int) {
        self.heldCall = heldCall
    }

    func fetch(_ context: ModelContext, _ id: PersistentIdentifier) throws -> Hike? {
        let call = calls.withLock { count in
            count += 1
            return count
        }
        if call == heldCall { release.wait() }
        return try SelectedLine.fetchHike(context, id)
    }

    func open() { release.signal() }
}
