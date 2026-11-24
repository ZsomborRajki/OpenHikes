//
//  WatchLibraryPublication.swift
//  OpenHikes
//
//  The library as the watch has been sent it, and what still has to go.
//
//  The library rides on the session's application context, with the
//  Auto-Pause and junction warnings switches beside it, and a context can be
//  refused: before activation, during a switch to another watch, or by
//  `updateApplicationContext` throwing. Something is counted sent only once
//  the session has taken it. Marked sent before the write, a refused context
//  left the phone believing the watch had switches it never got, and with
//  nothing pending a later notification carrying the same switch had nothing
//  to send again.
//
//  A value with the write handed in, so a suite can refuse one and accept
//  the next; `WatchSessionCoordinator` hands in the session's own, and tries
//  again on activation, when the watch comes to the front, and on every
//  change of a switch or of the library.
//

import Foundation
import OpenHikesShared

struct WatchLibraryPublication {
    /// The library last handed over, sent again when only a switch changed.
    private(set) var latest: SharedHikeCatalog?
    /// Whether ``latest`` still has to reach the watch: it came before the
    /// session could take it, its write was refused, or a switch has moved
    /// since the last one taken.
    private(set) var isPending = false
    // swiftlint:disable discouraged_optional_boolean
    /// The switches as the last context the session took carried them; `nil`
    /// before the first one, which carries both whatever they are.
    private(set) var sentAutoPause: Bool?
    private(set) var sentJunctionWarnings: Bool?
    // swiftlint:enable discouraged_optional_boolean

    /// `catalog` is the library now, and waits for ``flush(defaults:write:)``.
    mutating func offer(_ catalog: SharedHikeCatalog) {
        latest = catalog
        isPending = true
    }

    /// Makes the library pending again when a switch in `defaults` is not
    /// what the watch was last sent, and says whether anything is pending.
    /// The suite's notification names no key, so this is asked on every one.
    mutating func switchesMayHaveChanged(defaults: UserDefaults) -> Bool {
        if !isPending,
           WatchSessionCoordinator.catalogToResend(
               latest,
               sentAutoPause: sentAutoPause,
               sentJunctionWarnings: sentJunctionWarnings,
               defaults: defaults
           ) != nil {
            isPending = true
        }
        return isPending
    }

    /// Writes the pending library through `write`, with the switches as
    /// `defaults` holds them now, and counts it sent only once `write`
    /// returns. A throw leaves it pending and the last switches taken as
    /// they were. Nothing pending writes nothing.
    mutating func flush(
        defaults: UserDefaults,
        write: (WatchLibraryDigest) throws -> Void
    ) throws {
        guard isPending, let latest else { return }
        let digest = WatchSessionCoordinator.digest(of: latest, defaults: defaults)
        try write(digest)
        isPending = false
        sentAutoPause = digest.autoPauseEnabled
        sentJunctionWarnings = digest.junctionWarningsEnabled
    }
}
