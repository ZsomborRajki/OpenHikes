//
//  HikeRow.swift
//  OpenHikes
//
//  A single hike row, used both in the Hikes list and in search suggestions.
//
//  A row whose hike is being recorded or walked carries a badge naming the
//  phase — *Finding GPS*, *Recording*, *Paused*, *Active* — and the phase is
//  read here, by the row, never by the list that builds it. The list only
//  decides *which* row is under way (``HikeRowActivity/init(_:recorder:walk:)``),
//  which moves when a recording or a walk starts or ends. The phase moves at
//  the first fix, at every pause and resume, and at every stop Auto-Pause
//  calls, and ``MapSheetHikes`` is the costliest body in the app: reading the
//  word there re-ran the whole list for each of them, to change one capsule.
//

import OpenHikesData
import SwiftUI

struct HikeRow: View {
    struct Status {
        let title: String
        let tint: Color
    }

    let hike: Hike
    var isSelected: Bool = false
    /// What is under way on this hike, if anything. Its phase is read by this
    /// body — see the file's header.
    var activity: HikeRowActivity?

    var body: some View {
        let status = activity?.status(of: hike)
        TrailListRow(
            title: hike.displayTitle,
            badge: status.map { TrailListRow.Badge(title: $0.title, tint: $0.tint) },
            subtitle: hike.subtitle,
            selectionTint: isSelected ? hike.tintOpaque : nil,
            identifier: "hike-row"
        ) {
            TrailListRowGlyph(systemName: hike.symbol, tint: hike.tintOpaque)
        }
    }
}

/// A recording or a walk under way on a row's hike: which one, and where to
/// read its phase.
///
/// Holds the recorder or the walk session rather than its phase, so the list
/// that builds a row reads neither phase — see `HikeRow.swift`'s header.
enum HikeRowActivity {
    /// The recorder's own draft, whose phase is the recorder's.
    case recording(HikeRecorder)
    /// A draft marked as recording that this recorder is not recording: one
    /// another device mirrored here, or one a launch has not recovered yet.
    case recordingElsewhere
    /// The trail being walked.
    case walk(TrailWalkSession)

    /// What is under way on `hike`, or `nil` when nothing is.
    ///
    /// Reads the recorder's current hike and the walked hike, and neither
    /// phase: a walk's `walkedHikeID` and `phase` are set and cleared
    /// together, so the hike alone says whether a walk is on it. A recording
    /// outranks a walk, as it does on every surface — though a hike can only
    /// carry one of the two, since a recording's own draft never gets a walk.
    init?(_ hike: Hike, recorder: HikeRecorder, walk: TrailWalkSession) {
        let currentHikeID = recorder.currentHike?.id
        if hike.belongsToActiveRecording(currentHikeID: currentHikeID) {
            self = hike.id == currentHikeID ? .recording(recorder) : .recordingElsewhere
        } else if walk.walkedHikeID == hike.id {
            self = .walk(walk)
        } else {
            return nil
        }
    }

    /// The badge, read off the phase as it is now. Called by the row's body
    /// and nowhere else, so a phase change re-runs the row.
    ///
    /// `Active` / `Paused` for a walk, exactly as a recording's row carries
    /// `Recording` / `Paused`: the one thing about the row that changes, so a
    /// walk left running by mistake is visible from the list and one tap from
    /// the controls that end it.
    func status(of hike: Hike) -> HikeRow.Status {
        switch self {
        case .recording(let recorder): Self.status(of: recorder.phase)
        case .recordingElsewhere: HikeRow.Status(title: String(localized: "Recording"), tint: .red)
        case .walk(let walk):
            switch walk.phase {
            case .paused: HikeRow.Status(title: String(localized: "Paused"), tint: .secondary)
            case .following, nil: HikeRow.Status(title: String(localized: "Active"), tint: hike.tintOpaque)
            }
        }
    }

    private static func status(of phase: HikeRecorder.Phase) -> HikeRow.Status {
        switch phase {
        case .idle: HikeRow.Status(title: String(localized: "Recording"), tint: .red)
        case .recovering: HikeRow.Status(title: String(localized: "Recovering"), tint: .orange)
        case .waitingForFix: HikeRow.Status(title: String(localized: "Finding GPS"), tint: .orange)
        case .recording: HikeRow.Status(title: String(localized: "Recording"), tint: .red)
        case .paused: HikeRow.Status(title: String(localized: "Paused"), tint: .secondary)
        case .saving: HikeRow.Status(title: String(localized: "Saving"), tint: .orange)
        case .failed: HikeRow.Status(title: String(localized: "Needs Attention"), tint: .red)
        }
    }
}
