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
    /// What a tap on Stop does first, for the recording as it stands.
    ///
    /// Read in the Stop button's action and never in a `body`: the point
    /// count moves with every accepted fix.
    var stopStep: RecordingStopStep {
        RecordingStopStep(
            pointCount: stats.pointCount,
            holdsKeepsakes: currentHike.map { $0.hasPhotos || !$0.places.isEmpty } ?? false
        )
    }
}
