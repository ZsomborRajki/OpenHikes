//
//  HikeActivityControlIntents.swift
//  OpenHikesShared
//
//  Pause and resume, from the panel already showing the recording.
//
//  ## Why the Live Activity, of all surfaces
//
//  The argument is the one every intent in this app is built on: the hiker's
//  hands are busy and the phone is in a pocket, which is why `IntentModes` is
//  `.background` throughout. A hiker pausing for lunch had three ways to do
//  it — Siri, Control Center, or unlocking and finding the app — and the one
//  surface already lit up, already showing the recording and already under
//  their thumb was the one that could not.
//
//  ## Why the intents live here
//
//  A `LiveActivityIntent` runs in the *app's* process, but its type has to be
//  compiled into the widget extension that draws the button. `OpenHikes/` and
//  `OpenWidget/` are file-system-synchronized groups belonging to different
//  targets, so the shared package is the only place both can see —
//  ``ToggleHikeRecordingIntent`` already proves the same trick for the Control
//  Center control, including App Intents metadata extraction from a SwiftPM
//  library. The protocol below is the narrow bridge back to the app's
//  recorder; this package never owns or guesses recording state.
//
//  ## Why pause and resume and not stop
//
//  Stop does not earn its place. Stopping ends in `.reviewing` rather than in
//  the store whenever trail matching moved the line or found it ambiguous, so
//  a Stop on the Lock Screen would either drop that review silently or open
//  the app anyway — and opening the app is exactly what tapping the panel
//  already does.
//
//  ## Why a refusal has to be *said*
//
//  `resume()` calls `requestTemporaryFullAccuracy()` and fails with
//  `.preciseLocationRequired` when it does not land, and that prompt cannot be
//  shown from the background. A `LiveActivityIntent` has no
//  `continueInForeground(_:)` to fall back on the way
//  ``ToggleHikeRecordingIntent`` does, so the refusal is carried back as an
//  outcome and drawn on the panel. A tap on a locked phone that did nothing
//  and reported nothing is the failure mode this app went out of its way to
//  eliminate in the tile pipeline.
//

import AppIntents

/// What a tap on the panel asked for.
public enum HikeActivityControlAction: String, Sendable {
    case pause = "pause"
    case resume = "resume"
}

/// Why a tap could not do what it said, in the words the panel will use.
///
/// A closed set rather than a message, because the panel is 4 KB of budget and
/// a sentence written in the app would have to cross the wire on every update.
/// The widget spells these — see `HikeActivityControls.wording(for:)`. The
/// cases are alphabetical rather than in order of severity, which
/// `sorted_enum_cases` requires and nothing here minds — no code compares two
/// of these. The raw values are written out for the reason
/// ``WeatherUVCategory``'s are: one of these crosses the wire into an
/// activity's content state, so renaming a case is a decision about a payload
/// rather than a rename.
public enum HikeActivityControlRefusal: String, Codable, Hashable, Sendable {
    /// The recorder refused for a reason the panel has no room to explain.
    case failed = "failed"
    /// Core Location will not give precise fixes, and the prompt that would
    /// fix it cannot be shown from here.
    case needsPreciseLocation = "needsPreciseLocation"
    /// The recording ended, or was never running, between the panel being
    /// drawn and the tap landing.
    case notRecording = "notRecording"
}

public enum HikeActivityControlOutcome: Equatable, Sendable {
    case completed
    case refused(HikeActivityControlRefusal)
}

/// The app's side of a panel button.
@preconcurrency
@MainActor
public protocol HikeActivityControlHandling: Sendable {
    /// Performs `action` against the recorder, and reports what the panel
    /// should say if it could not.
    ///
    /// Does not throw: a `LiveActivityIntent` has nowhere to show an error,
    /// so every failure has to come back as something drawable.
    func performHikeActivityControl(
        _ action: HikeActivityControlAction
    ) async -> HikeActivityControlOutcome
}

// `LiveActivityIntent` is `@available(macOS, unavailable)` and this package is
// compiled for macOS by `swift test`, which is where its whole suite runs. The
// split is the one ``HikeActivityAttributes+ActivityKit`` already makes and
// for the same reason: everything a test can assert — the action, the refusal
// and the protocol — is above this line, and only the two types iOS needs to
// hand the system are below it.
#if os(iOS)

/// Pauses the recording the panel is showing.
public struct PauseHikeActivityIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Pause Hike"
    // periphery:ignore - an optional `AppIntent` requirement, read through
    // the AppIntents metadata rather than by any call site.
    public static let description = IntentDescription(
        "Pauses the hike being recorded, from its Lock Screen panel.",
        categoryName: "Recording"
    )
    public static let isDiscoverable = false

    @Dependency private var activityControl: any HikeActivityControlHandling

    public init() {
        // Required for App Intents metadata construction.
    }

    public func perform() async -> some IntentResult {
        _ = await activityControl.performHikeActivityControl(.pause)
        return .result()
    }
}

/// Resumes the recording the panel is showing.
public struct ResumeHikeActivityIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Resume Hike"
    // periphery:ignore - an optional `AppIntent` requirement, read through
    // the AppIntents metadata rather than by any call site.
    public static let description = IntentDescription(
        "Resumes the paused hike, from its Lock Screen panel.",
        categoryName: "Recording"
    )
    public static let isDiscoverable = false

    @Dependency private var activityControl: any HikeActivityControlHandling

    public init() {
        // Required for App Intents metadata construction.
    }

    public func perform() async -> some IntentResult {
        _ = await activityControl.performHikeActivityControl(.resume)
        return .result()
    }
}

#endif
