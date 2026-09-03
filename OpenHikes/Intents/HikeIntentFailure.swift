//
//  HikeIntentFailure.swift
//  OpenHikes
//
//  Everything an intent can refuse to do, and the sentence it refuses with.
//
//  Separate from ``RecordingFailure`` rather than an alias for it: the two
//  answer different questions. A `RecordingFailure` says why the *recorder*
//  stopped; this says why the *request* could not be honoured, and half of its
//  cases — no recording running, nothing recorded yet — are not failures of
//  anything, merely answers the walker has to hear.
//

import AppIntents
import Foundation

nonisolated enum HikeIntentFailure: LocalizedError, Equatable, Sendable {
    /// Asked to start a recording while one is already running.
    case alreadyRecording
    /// The recording stopped and saved, but trail matching found more than one
    /// route it could have been and is waiting for the walker to choose. There
    /// is no way to answer that by voice, so the app has to be opened.
    case awaitingRouteReview
    /// The last recording is still being written, or an interrupted one is
    /// still being recovered. Both are brief, and both are states in which
    /// starting a new hike would silently do nothing.
    case busyFinishing
    /// Stopping ended in something the recorder does not have a word for. The
    /// underlying text is logged where it is caught rather than carried here:
    /// every string this enum holds is read out loud.
    case couldNotSave
    /// Asked to stop, pause or report on a recording that is not running.
    case noActiveRecording
    /// Nothing has been recorded or imported yet.
    case noHikesYet
    /// Asked to resume one that is not paused.
    case notPaused
    /// The recorder refused, in its own words.
    case recording(RecordingFailure)
    /// The store could not be read. Carries nothing for the same reason
    /// ``couldNotSave`` does not.
    case storage
    /// The walker's calendar could not name the day being asked about. Not a
    /// store failure — nothing was read — and so not ``storage``, whose
    /// sentence would say otherwise.
    case unknownDay

    var errorDescription: String? {
        switch self {
        case .busyFinishing: "OpenHikes is still finishing your last recording."
        case .couldNotSave: "Your hike couldn't be saved."
        case .unknownDay: "OpenHikes couldn't work out which day that is."
        case .noActiveRecording: "OpenHikes isn't recording a hike right now."
        case .alreadyRecording: "OpenHikes is already recording a hike."
        case .notPaused: "That hike isn't paused."
        case .recording(let failure): failure.errorDescription
        case .awaitingRouteReview:
            "Your hike is saved, but it needs you to pick which trail you followed."
        case .noHikesYet: "There aren't any hikes in OpenHikes yet."
        case .storage: "Your hikes couldn't be read."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .alreadyRecording, .noActiveRecording, .notPaused, .noHikesYet, .unknownDay:
            nil
        case .busyFinishing: "Try again in a moment."
        case .recording(let failure): failure.recoverySuggestion
        case .awaitingRouteReview: "Open OpenHikes to finish reviewing it."
        // Fixed rather than the store's own words: what SwiftData has to say
        // about a failed fetch is a sentence for a developer, and this one is
        // spoken. It is logged in `HikeIntentCoordinator.fetch(_:)` instead.
        case .couldNotSave, .storage: "Open OpenHikes to check on your hikes."
        }
    }
}

/// What the system reads out when an intent throws.
///
/// `AppIntents` renders a thrown error through this conformance and ignores
/// `LocalizedError` — so without it, every refusal above reaches Siri as the
/// framework's own generic "there was a problem" line.
nonisolated extension HikeIntentFailure: CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource {
        let reason = errorDescription ?? "Something went wrong."
        guard let recoverySuggestion else { return "\(reason)" }
        return "\(reason) \(recoverySuggestion)"
    }
}
