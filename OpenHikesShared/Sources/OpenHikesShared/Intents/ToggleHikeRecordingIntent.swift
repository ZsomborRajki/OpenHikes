//
//  ToggleHikeRecordingIntent.swift
//  OpenHikesShared
//
//  The action shared by the app and its Control Center control.
//
//  A control's AppIntent type has to be visible to the widget extension that
//  draws the control and to the app process that performs it. The protocol is
//  the narrow bridge back to the app's recorder; the shared package never
//  owns or guesses recording state.
//

import AppIntents

@preconcurrency
@MainActor
public protocol HikeRecordingControlHandling: Sendable {
    /// Starts or stops the walker's hike, whichever the recorder's own phase
    /// calls for when this runs.
    ///
    /// - Parameter canPromptForLocation: whether this call is running
    ///   somewhere Core Location's prompts can actually appear. `false` from a
    ///   background tap, where a prompt would never be shown and the handler
    ///   answers ``HikeRecordingControlOutcome/requiresForegroundAuthorization``
    ///   instead of starting a recording nobody could permit.
    func toggleHikeRecording(
        canPromptForLocation: Bool
    ) async throws -> HikeRecordingControlOutcome
}

public enum HikeRecordingControlOutcome: Equatable, Sendable {
    case completed
    case requiresForegroundAuthorization
}

public struct ToggleHikeRecordingIntent: AppIntent {
    public static let title: LocalizedStringResource = "Toggle Hike Recording"
    public static let supportedModes: IntentModes = [
        .background,
        .foreground(.dynamic),
    ]

    @Dependency private var recordingControl: any HikeRecordingControlHandling

    public init() {
        // Required for App Intents metadata construction.
    }

    /// - Note: `continueInForeground(_:)` rather than
    ///   `needsToContinueInForegroundError(_:)`, for the reason the recording
    ///   intents in the app carry: that error re-*runs* `perform()`, and the
    ///   re-run would find the same unanswered authorization, because nothing
    ///   between the two runs asked Core Location. Continuing carries on in
    ///   the same `perform()`, where the second call is allowed to reach the
    ///   recorder and let *it* put the prompt up.
    public func perform() async throws -> some IntentResult {
        switch try await recordingControl.toggleHikeRecording(
            canPromptForLocation: false
        ) {
        case .completed:
            return .result()
        case .requiresForegroundAuthorization:
            try await continueInForeground(
                IntentDialog(
                    "OpenHikes needs your location before it can record a hike."
                )
            )
            _ = try await recordingControl.toggleHikeRecording(
                canPromptForLocation: true
            )
            return .result()
        }
    }
}
