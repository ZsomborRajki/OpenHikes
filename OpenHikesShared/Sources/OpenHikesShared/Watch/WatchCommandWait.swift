//
//  WatchCommandWait.swift
//  OpenHikesShared
//
//  Which button on the watch is waiting for the phone, and which answer ends
//  that wait.
//
//  ## Why an answer can arrive for a press nobody is waiting on
//
//  A command's answer comes back through `WCSession`'s reply or error
//  handler, whenever the session gets round to calling it. Losing the phone
//  ends the wait at once, so the screen does not hold every button disabled
//  for a phone it cannot see, and that lets the hiker press again before the
//  first press has been answered. When the first answer then lands, it ends
//  a wait that is not its own: taking every answer as the current one cleared
//  the second press's wait, so the buttons came back while it was still
//  unanswered, and put the first press's refusal beside the second
//  (issue #1124). An answer delivered twice does the same to whatever press
//  follows the first copy.
//
//  So every press keeps its command's identity, which the phone echoes in its
//  outcome and the watch puts on its own failures, and only the answer to the
//  press still waiting ends the wait or says anything to the hiker. Any other
//  is late.
//
//  ## What a late answer still does
//
//  The phone's reading in it is a snapshot like any other, and the model
//  takes it through the snapshot's own freshness rule
//  (``WatchCommandAnswer/reading(holding:)``) whichever press it answers: a
//  timestamp says whether it is current, and the press it answers does not.
//
//  ## Why it is here
//
//  The watch has no test bundle. `WatchModel` keeps one of these, asks it
//  before sending, and hands it every answer, so the whole decision runs on
//  the host.
//

import Foundation

/// The button waiting for the phone's answer, and the refusal the hiker has
/// not yet read.
public struct WatchCommandWait: Equatable, Sendable {
    /// The command sent and not yet answered, or `nil` when the buttons are
    /// free.
    public private(set) var pending: WatchRecordingCommand?
    /// The sentence the last answered press earned, until the hiker reads it
    /// or presses again.
    public private(set) var refusal: String?

    public init() {
        pending = nil
        refusal = nil
    }

    /// What the waiting button does, for the screen to mark and to disable
    /// the others by.
    public var pendingAction: WatchRecordingCommand.Action? { pending?.action }

    /// The hiker pressed `action`: the command to send, or `nil` while another
    /// press is still waiting. Send the returned command unchanged, because
    /// its identity is what its answer is matched on.
    public mutating func press(
        _ action: WatchRecordingCommand.Action,
        id: UUID = UUID()
    ) -> WatchRecordingCommand? {
        guard pending == nil else { return nil }
        let command = WatchRecordingCommand(action: action, id: id)
        refusal = nil
        pending = command
        return command
    }

    /// An answer arrived. Returns whether it ended the wait: only the answer
    /// to the press still waiting does, and only that one says anything to
    /// the hiker. Any other is late — see this file's header.
    @discardableResult public mutating func receive(_ answer: WatchCommandAnswer) -> Bool {
        guard let pending, answer.commandID == pending.id else { return false }
        self.pending = nil
        refusal = answer.refusal
        return true
    }

    /// The phone went out of reach. No answer the hiker should wait on is
    /// coming, so the buttons are free again; one that lands later is late.
    public mutating func phoneLost() {
        pending = nil
    }

    /// The hiker read the refusal.
    public mutating func acknowledgeRefusal() {
        refusal = nil
    }
}
