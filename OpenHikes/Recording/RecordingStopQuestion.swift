//
//  RecordingStopQuestion.swift
//  OpenHikes
//
//  The one question a Stop asks, whichever Stop was tapped.
//
//  Stop is in three places: the bar of the recording's own screen, the
//  capsule on the map that stands in for that bar on every other screen —
//  see ``MapActivityCapsule`` — and the Live Activity, whose Stop opens the
//  app and asks here — see ``TrailWidgetDeepLink/stopRecordingURL()``. Each
//  would need the name alert, the discard alert behind it and the save, and
//  copies of a question come to ask different things. So the question is this
//  object's, on the model, and it is put up with what the map's controls
//  open — see ``MapControlModals`` — from the map sheet's contents or a place
//  card over them, whichever is in front.
//
//  What it asks is ``RecordingStopStep``'s rule: a recording with a line is
//  asked its name, one with nothing to save is ended, and one with nothing
//  to save but a photograph or a place is asked before those go. The name
//  alert offers the other ending too, *Discard Recording*, which asks once
//  more in an alert of its own: a dialog raised from an alert's button is
//  never presented — see ``RecordingStopAlerts``.
//
//  How it ended goes out as an ``ActivityEnding``, for the view that owns
//  the sheet's path.
//

import Foundation
import Observation
import OpenHikesData
import os

@MainActor
@Observable
final class RecordingStopQuestion {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    private let recorder: HikeRecorder
    private let endings: EventFeed<ActivityEnding>

    /// Whether the name alert is up.
    var isAskingName = false
    /// Whether the discard question is up.
    var isConfirmingDiscard = false
    /// What the name alert's field says.
    var nameDraft = ""
    /// The name the alert's field opened with, taken once when the hiker
    /// asked to stop: the walk's town, trail and day where it has them, else
    /// the draft's own name. Handed to the recorder with whatever the field
    /// says by then — see ``HikeRecorder/stop(customName:offeredTitle:)``.
    ///
    /// Taken in ``ask()`` rather than read where the alert is drawn, because
    /// ``HikeRecorder/suggestedTitle()`` reads the live distance, and a body
    /// that read it would run again on every accepted fix.
    private(set) var offeredTitle: String?
    /// The recording the question was asked about, which an answer acts on
    /// only while it is still the one under way. The capsule's question can
    /// stay up while the watch or an intent ends that recording and starts
    /// another, and *Discard Recording* given for the first must not delete
    /// the second, nor *Save* stop it under the first one's name.
    @ObservationIgnored private var askedSession: UUID?

    init(recorder: HikeRecorder, endings: EventFeed<ActivityEnding>) {
        self.recorder = recorder
        self.endings = endings
    }

    /// What Stop does: asks for a name, asks before throwing away what the
    /// hiker put on a walk with no line, or ends an empty one.
    ///
    /// Settled first, because a recording the live figures call empty can
    /// still have fixes on their way to its journal — see
    /// ``HikeRecorder/settledStopStep()``. A tap while an earlier one is still
    /// counting does nothing. And a recording being recovered is recovered
    /// first: the Live Activity's Stop can be what launched the app.
    ///
    /// A walk whose resume was refused is asked as the paused walk it still
    /// is: the panel the refusal left up offers Stop, and a failed recording
    /// has no Stop step — see ``HikeRecorder/reopenRefusedResume()``.
    func ask() async {
        await recorder.settleAutomaticRecovery()
        recorder.reopenRefusedResume()
        let step = await recorder.settledStopStep()
        // Read with the step's answer, before any suspension, so both are
        // about one recording.
        askedSession = recorder.sessionID
        switch step {
        case .askName: await askForName()
        case .confirmDiscard: isConfirmingDiscard = true
        case .endEmpty: await discard()
        case nil: break
        }
    }

    /// Asks whether to throw the recording away: a failed save's *Discard
    /// Recording*, on the screen of the recording it is about.
    func confirmDiscard() {
        askedSession = recorder.sessionID
        isConfirmingDiscard = true
    }

    /// The name alert's *Discard Recording*: asks once more, about the
    /// recording the name was asked for rather than whichever is under way
    /// by now — see ``askedSession``.
    func discardInstead() {
        isConfirmingDiscard = true
    }

    /// Saves the recording under the name the field holds — or under the one
    /// it was offered, when the field still says that or says nothing. See
    /// ``RecordingStopName``.
    func save() async {
        guard isStillAsked() else { return }
        let customName = RecordingStopName.typed(nameDraft, over: offeredTitle)
        do {
            let hike = try await recorder.stop(customName: customName, offeredTitle: offeredTitle)
            endings.send(.recordingSaved(hikeID: hike.id))
        } catch {
            // The recording is still there, and its screen says why — see
            // ``RecordingCard``'s *Retry Save*.
            HikeRecorder.logger.error(
                "Recording save failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Saves again after a failed save, the card's *Retry Save*, and lands
    /// where a Stop's save lands, through the same ending, so that a saved
    /// recording opens one way whichever save wrote it.
    func retrySave() async {
        do {
            let hike = try await recorder.retrySave()
            endings.send(.recordingSaved(hikeID: hike.id))
        } catch {
            // Still failed, and its screen still says so.
            HikeRecorder.logger.error(
                "Recording save retry failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Throws the recording away. A discard the recorder refused leaves it
    /// where it was, and says nothing here: its screen does.
    func discard() async {
        guard isStillAsked() else { return }
        let hikeID = recorder.currentHike?.id
        await recorder.discard()
        if recorder.phase == .idle {
            endings.send(.recordingDiscarded(hikeID: hikeID))
        }
    }

    /// Whether the recording under way is the one the question was asked
    /// about — see ``askedSession``. An answer for one that has gone is
    /// dropped: what it was about has ended without it.
    private func isStillAsked() -> Bool {
        guard recorder.sessionID == askedSession else {
            HikeRecorder.logger.notice("Stop's answer came after its recording ended; dropped")
            return false
        }
        return true
    }

    /// Opens the name alert holding the offered name.
    ///
    /// The field was once prefilled and then emptied again, because Save
    /// without typing sent the default through as a typed name and the hike
    /// was flagged user-named for good. The text is back, and what keeps that
    /// from coming back with it is the save reading the field against what it
    /// opened with — see ``RecordingStopName``.
    private func askForName() async {
        let offered = await recorder.suggestedTitle() ?? recorder.currentHike?.title
        offeredTitle = offered
        nameDraft = offered ?? ""
        isAskingName = true
    }
}
