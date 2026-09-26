//
//  WatchFixWindow.swift
//  OpenHikesShared
//
//  The earliest moment a fix can have been taken and still belong to the
//  watch recording it is delivered to.
//
//  ## Why a recording needs one
//
//  Core Location does not promise that a fix is new. The first delivery after
//  `startUpdatingLocation()` can be the last position the watch had cached,
//  minutes or hours old, and Apple's location guide says to read the timestamp
//  for exactly that reason. `WatchFixPolicy` has no opinion about age — the
//  first accurate fix of a recording is kept whenever it was taken — and
//  `WatchWalkAccumulator` adds the whole gap from it to the next fix. One
//  cached fix an hour old was a recording ten seconds long with an hour of
//  active time and a kilometre it never walked (#720).
//
//  ## Why at the recorder, and not in the accumulator
//
//  The accumulator is also what a journal is replayed into, and a journal
//  holds only fixes that were kept. Asking it to judge age would ask a replay
//  to know when each leg of the original recording opened, which is state it
//  has no line for. The window is the recorder's instead: opened at Start,
//  reopened at every resume, and consulted before a fix reaches the
//  accumulator at all.
//
//  ## Why a resume moves it
//
//  A paused recording drops what arrives, but a fix *taken* during the pause
//  can still be *delivered* after the resume — the same late batch as above,
//  only shorter. Admitted, it would open the new leg at a moment the hiker had
//  paused, and the leg's first real fix would count the rest of the pause as
//  walking. So a resume is the start of a leg in the same sense Start is the
//  start of the first.
//
//  What stays admitted is a late batch from inside the recording: Core
//  Location batches deliveries on a watch whose screen is off, and every fix
//  in one taken since the window opened is as good as one delivered at once.
//

import Foundation

/// When fixes started counting for the leg of a recording now running.
public struct WatchFixWindow: Sendable, Equatable {
    /// The first moment a fix may have been taken at and still be kept.
    public private(set) var opensAt: Date

    /// A window opening when a recording starts, or when one carries on.
    public init(opensAt: Date) {
        self.opensAt = opensAt
    }

    /// Moves the window to a resume, so a fix taken while the recording was
    /// paused is not the one that opens the new leg.
    ///
    /// Never backwards: a resume the clock places before the window already
    /// opened would admit fixes the earlier opening refused.
    public mutating func reopen(at date: Date) {
        opensAt = max(opensAt, date)
    }

    /// Whether a fix taken at `timestamp` belongs to this recording.
    public func admits(_ timestamp: Date) -> Bool {
        timestamp >= opensAt
    }
}
