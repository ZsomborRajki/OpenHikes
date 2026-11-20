//
//  RecordingStop.swift
//  OpenHikes
//
//  What a tap on Stop asks, and whose name the save then writes.
//
//  Stop used to ask one thing whatever it was stopping: a name, with Save
//  and Cancel. That left two walks badly served.
//
//  A recording started by mistake has nothing to name. Saving it failed, with
//  an alert that a hike needs two points, and left it paused, where the one
//  way out was the discard button a paused recording has. So a recording with
//  no line to save is ended by Stop itself, without a question when it holds
//  nothing, and with the discard question when the hiker has already put a
//  photograph or a place on it.
//
//  What counts as no line is the journal's answer, not the live figures'.
//  The widget's fixes wait in the App Group for the next merge, and a merge
//  can be running when Stop is tapped, so a walk the live count gives one
//  point can already hold two: the line the save would have kept. Stop
//  waits for those before it calls a walk empty — see
//  ``HikeRecorder/settledStopStep()``.
//
//  And a walk worth throwing away could only be thrown away from a pause. The
//  name alert now offers that too — see ``RecordingCard`` — so Stop is the one
//  place a recording ends, kept or not.
//
//  ## The name in the field
//
//  The alert opens with the offered name in its field, selected, rather than
//  empty over a placeholder: a hiker who wants a word changed changes the
//  word, and one who wants another name types over it. A field left as it
//  opened is therefore not a name anybody typed, and saving it must not mark
//  the hike as named by hand — which is what a prefilled field did before it
//  was emptied, and why ``RecordingStopName`` reads the field against what
//  was offered rather than taking its text.
//

import Foundation
import OpenHikesData
import os

/// What a tap on Stop does first.
nonisolated enum RecordingStopStep: Equatable {
    /// The walk has a line: ask what to call it, with the ways out beside
    /// the name.
    case askName
    /// Too short to be a hike, but it holds photographs or places: ask
    /// before they go with it.
    case confirmDiscard
    /// Nothing recorded and nothing attached: end it.
    case endEmpty

    /// The fewest points a recording can be saved with — the line
    /// ``RecordingPreparation`` refuses to go below, as
    /// ``RecordingFailure/tooShort``.
    static let savablePointCount = 2

    /// - Parameters:
    ///   - pointCount: The points the recording has kept.
    ///   - holdsKeepsakes: Whether its draft carries anything the hiker put
    ///     there: a photograph or a place.
    init(pointCount: Int, holdsKeepsakes: Bool) {
        if pointCount >= Self.savablePointCount {
            self = .askName
        } else {
            self = holdsKeepsakes ? .confirmDiscard : .endEmpty
        }
    }
}

/// The name the stop alert's field holds when the hiker saves.
nonisolated enum RecordingStopName {
    /// The name the hiker typed, or `nil` when the field says what it opened
    /// with or says nothing — either way the hike keeps the name it was
    /// offered, as a name the app chose.
    ///
    /// ``HikeTitleEdit`` is the rename field's rule for the same question,
    /// so the two fields cannot come to answer it differently.
    static func typed(_ field: String, over offered: String?) -> String? {
        switch HikeTitleEdit.of(field, against: offered ?? "") {
        case .unchanged: nil
        case .renamed(let name): name
        }
    }
}

extension HikeRecorder {
    /// What a tap on Stop does first, for the recording as the live figures
    /// have it.
    ///
    /// Read in the Stop button's action and never in a `body`: the point
    /// count moves with every accepted fix. A recording this calls empty may
    /// not be — see ``settledStopStep()``, which is what the button acts on.
    var stopStep: RecordingStopStep {
        stopStep(pointCount: stats.pointCount)
    }

    /// What a tap on Stop does first, once every fix the walk has is counted,
    /// or `nil` when there is no longer a recording to stop — or this tap
    /// came while an earlier one was still counting.
    ///
    /// A walk the live figures give a line is answered at once. One they do
    /// not is answered only after the fixes still on their way to the journal
    /// have landed: a merge already running, and the widget's fixes waiting in
    /// the App Group for the next one. Ending a recording on the live count
    /// alone threw those away with it — a phone fix and a widget fix is a line
    /// that ``stop(customName:offeredTitle:)``, which merges first, saves.
    /// And the count is then read off the journal, normalized as the save
    /// normalizes it, rather than off the live figures, which a merge rebuilds
    /// only when no fix lands inside its read.
    ///
    /// Every wait is here, before the answer, so that nothing can land between
    /// an empty answer and the discard it leads to: the caller acts on it
    /// without a suspension, and ``discard()`` stops the sensors before its
    /// own first one.
    func settledStopStep() async -> RecordingStopStep? {
        guard isStoppable, !isSettlingStop else { return nil }
        let live = stopStep
        guard live != .askName, let journal, let sessionID else { return live }
        isSettlingStop = true
        defer { isSettlingStop = false }
        // Bounded as the merge's own refresh is: a merge is scheduled by
        // every accepted fix, and a walk that keeps getting them past a count
        // of one is no longer empty, which the last answer will say.
        for _ in 0..<Self.journalMergeRefreshAttemptLimit {
            await pendingFixMergeTask?.value
            await mergePendingWidgetFixes(for: sessionID)
            await journalQueue.drain()
            if pendingFixMergeTask == nil { break }
        }
        let journaled: Int
        do {
            let points = try await journal.loadSession()?.points ?? []
            journaled = await RecordingPreparation.normalizedPointsOffMain(points).count
        } catch {
            // A journal that cannot be read cannot be saved either, and
            // nothing here may decide unasked that it held nothing.
            Self.logger.error(
                "Stop could not count the journal: \(error.localizedDescription, privacy: .public)"
            )
            return self.sessionID == sessionID && isStoppable ? .confirmDiscard : nil
        }
        guard self.sessionID == sessionID, isStoppable else { return nil }
        return stopStep(pointCount: max(stats.pointCount, journaled))
    }

    /// The phases Stop is offered in.
    private var isStoppable: Bool {
        phase == .waitingForFix || phase == .recording || phase == .paused
    }

    private func stopStep(pointCount: Int) -> RecordingStopStep {
        RecordingStopStep(
            pointCount: pointCount,
            holdsKeepsakes: currentHike.map { $0.hasPhotos || !$0.places.isEmpty } ?? false
        )
    }
}
