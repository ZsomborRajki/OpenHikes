//
//  StoreFailureAttributionTests.swift
//  OpenHikesTests
//
//  "Store failure attribution", split out of StorageStartupTests.swift so
//  that a file declares one @Suite. That file's header still holds the
//  context the two share.
//

import Foundation
@testable import OpenHikes
import SwiftData
import SwiftUI
import Testing

/// Which of the two stores failed — and the finding that the app cannot tell.
///
/// `Hike` lives in a mirrored store and `HikeLocalState` in an unmirrored one,
/// and losing them does not cost the same thing: the sidecar holds tile and
/// photo bookkeeping this device can rebuild, while the mirrored store holds
/// the user's hikes. They are nonetheless two configurations of *one*
/// `ModelContainer`, so either failing fails the open, and both arrive at
/// ``StorageStartupIssue`` as the same string.
///
/// This suite pins that rather than papering over it. The assertions are
/// written as claims about today's behaviour, so the day someone attributes a
/// failure to a store, they fail and say what changed.
@MainActor
@Suite("Store failure attribution")
struct StoreFailureAttributionTests {
    private func issue(corrupting store: KeyPath<StartupStoreSandbox, URL>) throws -> StorageStartupIssue {
        let sandbox = StartupStoreSandbox()
        try sandbox.corrupt(sandbox[keyPath: store])
        let load = try OpenHikesModel.loadContainer(
            persistent: { try sandbox.openContainer() },
            fallback: { try sandbox.inMemoryFallback() }
        )
        return try #require(load.startupIssue)
    }

    /// The device-local store failing is not survivable on its own terms: it
    /// takes the mirrored store down with it, and the launch runs on temporary
    /// storage as though the hikes themselves were unreadable.
    @Test("a corrupt device-local store fails the launch as hard as a corrupt hike store")
    func localStoreFailureIsAlsoAStartupIssue() throws {
        _ = try issue(corrupting: \.localURL)
    }

    /// The finding. ``StorageStartupIssue`` carries only its
    /// `underlyingDescription`, and SwiftData reports both as the same
    /// `loadIssueModelContainer` with no explanation attached — so nothing
    /// downstream, `OpenHikesView`'s "Saved Hikes Unavailable" alert included,
    /// can say which store went.
    ///
    /// Left as it is on purpose: attributing it means opening each
    /// configuration separately to find out which one throws, which is a second
    /// store-open on the launch path to produce detail that cannot help the
    /// user recover. Recorded here so it stays a known cost rather than
    /// becoming a surprise.
    @Test("the two failures are reported identically, so the alert cannot name a cause")
    func failuresAreIndistinguishable() throws {
        let mirrored = try issue(corrupting: \.hikesURL)
        let deviceLocal = try issue(corrupting: \.localURL)

        #expect(
            mirrored == deviceLocal,
            """
            These have started reporting differently. If the description now names a store, \
            StorageStartupIssue can carry which one failed, and the alert can stop telling a \
            user their hikes are unavailable when only the sidecar is.
            """
        )
    }
}
