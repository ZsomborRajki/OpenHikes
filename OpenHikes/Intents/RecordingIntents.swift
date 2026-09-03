//
//  RecordingIntents.swift
//  OpenHikes
//
//  Start, pause, resume and stop, without taking the phone out.
//
//  All four run in the background: the walker's hands are busy and the phone
//  is in a pocket, so an intent that insisted on bringing the app to the front
//  would be answering a different request than the one asked. The exception is
//  a prompt only the foreground can show — Core Location never asked, or asked
//  and answered at reduced accuracy — where start and resume hand the walker
//  to the app *and carry on there* rather than quietly failing to record.
//

import AppIntents

struct StartHikeRecordingIntent: AppIntent, HikeCoordinatingIntent {
    static let title: LocalizedStringResource = "Start Hike Recording"
    // periphery:ignore - an optional `AppIntent` requirement, read through the
    // AppIntents metadata rather than by any call site.
    static let description = IntentDescription(
        "Starts recording a new hike, with the screen off and the phone in your pocket.",
        categoryName: "Recording"
    )
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Dependency var appCoordinator: HikeIntentCoordinator

    func perform() async throws -> some IntentResult & ProvidesDialog {
        if await coordinator.authorization.needsForeground {
            try await continueInForeground(
                IntentDialog("OpenHikes needs your location before it can record a hike.")
            )
        }
        // Reached in the foreground when the branch above ran, which is the
        // whole point of it: `recorder.start()` is the only call that asks
        // Core Location anything, and the prompt it puts up cannot be shown
        // from the background.
        let recording = try await coordinator.startRecording()
        return .result(dialog: IntentDialog("\(Self.confirmation(for: recording))"))
    }

    /// A just-started recording has walked nothing and lasted no time, so its
    /// own summary would read "You're 0 metres in, 0s elapsed."
    nonisolated private static func confirmation(for recording: LiveRecordingReport) -> String {
        guard let trailName = recording.trailName, !trailName.isEmpty else {
            return "Recording your hike."
        }
        return "Recording your hike on \(trailName)."
    }
}

struct PauseHikeRecordingIntent: AppIntent, HikeCoordinatingIntent {
    static let title: LocalizedStringResource = "Pause Hike Recording"
    // periphery:ignore - see `StartHikeRecordingIntent.description`.
    static let description = IntentDescription(
        "Pauses the hike being recorded, and turns the GPS off until you resume.",
        categoryName: "Recording"
    )
    static let supportedModes: IntentModes = .background

    @Dependency var appCoordinator: HikeIntentCoordinator

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let recording = try await coordinator.pauseRecording()
        return .result(dialog: IntentDialog("\(recording.spokenSummary)"))
    }
}

struct ResumeHikeRecordingIntent: AppIntent, HikeCoordinatingIntent {
    static let title: LocalizedStringResource = "Resume Hike Recording"
    // periphery:ignore - see `StartHikeRecordingIntent.description`.
    static let description = IntentDescription(
        "Picks the paused hike back up where you left it.",
        categoryName: "Recording"
    )
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Dependency var appCoordinator: HikeIntentCoordinator

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Resuming meets the accuracy prompt on the same two lines starting
        // does — `HikeRecorder.resume()` calls `requestTemporaryFullAccuracy()`
        // and then fails with `.preciseLocationRequired` when it did not land
        // — so it earns the same foreground hand-off.
        if await coordinator.authorization.needsForeground {
            try await continueInForeground(
                IntentDialog("OpenHikes needs your location before it can pick your hike back up.")
            )
        }
        let recording = try await coordinator.resumeRecording()
        return .result(dialog: IntentDialog("\(recording.spokenSummary)"))
    }
}

struct StopHikeRecordingIntent: AppIntent, HikeCoordinatingIntent {
    static let title: LocalizedStringResource = "Stop Hike Recording"
    // periphery:ignore - see `StartHikeRecordingIntent.description`.
    static let description = IntentDescription(
        "Stops the hike being recorded and saves it.",
        categoryName: "Recording"
    )
    static let supportedModes: IntentModes = .background

    @Dependency var appCoordinator: HikeIntentCoordinator

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let hike = try await coordinator.stopRecording()
        return .result(dialog: IntentDialog("\(Self.confirmation(for: hike))"))
    }

    /// Named "Saved" rather than "Stopped": stopping is what the walker asked
    /// for, and what they want confirmed is that it survived.
    nonisolated private static func confirmation(for hike: FinishedHikeReport) -> String {
        "Saved \(hike.spokenSummary)"
    }
}
