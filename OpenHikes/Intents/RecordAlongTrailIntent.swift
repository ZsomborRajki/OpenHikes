//
//  RecordAlongTrailIntent.swift
//  OpenHikes
//
//  "Start recording along the Rennsteig" — the last of the two shortcut slots
//  ``OpenHikesShortcuts`` deliberately left unspent, and the one that was
//  blocked on a decision rather than on plumbing.
//
//  ## The decision, and what it was between
//
//  Starting a recording *and* naming a trail to follow is the one gesture that
//  asks for both at once, and *a live recording outranks the selected trail,
//  on every surface, without qualification* is settled — which means the trail
//  the hiker just said out loud is precisely the thing that leaves the widget
//  the moment this runs. That is the rule working correctly and it is also,
//  from the hiker's side, the app ignoring what they just said.
//
//  Three ways out were weighed on #481. The one taken is **say it back**: the
//  dialog names the trail being followed, so the hiker *hears* the part the
//  screen will not show. It costs one sentence and touches none of the three
//  places the precedence rule is applied — ``TrailWidgetEntry/init``,
//  `HikeLiveActivityController.accepts(_:)` and
//  `HikeRecordingControlState.init(snapshot:)` — which is what the third
//  option (a recording payload that carries the followed trail) would have
//  re-opened, and that needs a design for the small widget family and a reload
//  budget rather than a fresh reading of `TrailWidgetEntry`.
//
//  The first option — accept it silently — was rejected for being the same
//  code with the hiker told nothing. Building this without the dialog would
//  have *been* option one, chosen by default rather than on purpose.
//
//  ## Why it does not bring the app forward
//
//  ``OpenHikeIntent`` sets `openAppWhenRun` because showing the hike is the
//  whole of what it does. Here the recording is, and a recording is meant to
//  start with the phone in a pocket — that is what
//  ``StartHikeRecordingIntent``'s `.background` mode is for, and taking it
//  away would make "start recording along X" a worse way to start a recording
//  than "start recording".
//
//  So the trail request is left where ``HikeOpenRequests`` puts it and is
//  applied by the view tree whenever there is one: immediately if the app is
//  in front, and otherwise the next time the hiker looks at the map — which is
//  the moment a drawn route is worth anything at all. The recording, which is
//  the part that cannot wait, starts either way.
//

import AppIntents
import Foundation
import OpenHikesShared

/// Not `nonisolated`, for the reason ``HikeEntity`` gives: `@Parameter` and
/// `@Dependency` wrap mutable stored properties.
struct RecordAlongTrailIntent: AppIntent, HikeCoordinatingIntent {
    static let title: LocalizedStringResource = "Record Along a Trail"
    // periphery:ignore - see `StartHikeRecordingIntent.description`.
    static let description = IntentDescription(
        "Starts recording a hike and follows one of your saved trails.",
        categoryName: "Recording"
    )
    /// The same pair ``StartHikeRecordingIntent`` declares, and for the same
    /// reason: `recorder.start()` is the only call that asks Core Location
    /// anything, and the prompt it may put up cannot be shown from the
    /// background.
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "Trail")
    var hike: HikeEntity

    @Dependency var appCoordinator: HikeIntentCoordinator

    @Dependency var openRequests: HikeOpenRequests

    /// Resolved the way the coordinator is — see ``HikeIntentContext``.
    @MainActor
    private var requests: HikeOpenRequests {
        HikeIntentContext.openRequestsOverride ?? openRequests
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        if await coordinator.authorization.needsForeground {
            try await continueInForeground(
                IntentDialog("OpenHikes needs your location before it can record a hike.")
            )
        }
        // The trail first, so a hiker who is looking at the app sees the route
        // appear as the recording starts rather than a moment after it. The
        // order matters for nothing else: neither call can fail because of the
        // other.
        await requests.open(hikeID: hike.id)
        let recording = try await coordinator.startRecording()
        return .result(
            dialog: IntentDialog("\(Self.confirmation(following: hike.name, recording: recording))")
        )
    }

    /// The sentence the whole decision comes down to.
    ///
    /// It names the trail **the hiker asked for**, not
    /// ``LiveRecordingReport/trailName``. Those are different things and the
    /// difference is the point: the report's name is whatever OpenStreetMap
    /// way the live matcher has snapped to, which at the moment a recording
    /// starts is usually nothing and is never guaranteed to be the route the
    /// hiker named. Speaking the matched name here would answer a question
    /// nobody asked, and speaking nothing would be option one.
    ///
    /// Internal rather than `private` so a suite can read it: `perform()` can
    /// only be run by the system, and this sentence is the whole of what #481
    /// decided.
    nonisolated static func confirmation(
        following trailName: String,
        recording: LiveRecordingReport
    ) -> String {
        guard !trailName.isEmpty else {
            // The entity had no name to speak. Falls back to exactly what
            // `StartHikeRecordingIntent` would have said, since that is what
            // this has become.
            return recording.trailName.map { "Recording your hike on \($0)." }
                ?? "Recording your hike."
        }
        return "Recording your hike, following \(trailName)."
    }
}
