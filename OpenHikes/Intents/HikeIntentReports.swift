//
//  HikeIntentReports.swift
//  OpenHikes
//
//  What an intent hands back, and the sentence Siri says out of it.
//
//  These are plain `Sendable` values rather than a `Hike` or a live
//  `HikeRecorder`: an intent is answered off the back of state that belongs to
//  the app's main actor, and the answer travels to a system process that has
//  no business holding a SwiftData row. Keeping the wording here — rather than
//  in the `AppIntent` structs — is also what lets a suite assert on what the
//  walker is told without going anywhere near AppIntents.
//

import Foundation

/// What Core Location will do to a recording started right now, which is what
/// decides whether "start a hike" can be answered without the app on screen.
///
/// A separate type from ``RecordingLocationAuthorization`` so the intents do
/// not reach through the recorder into Core Location's vocabulary; the mapping
/// is one line in ``HikeIntentCoordinator``.
nonisolated enum HikeIntentAuthorization: Equatable, Sendable {
    case denied
    case granted
    /// Authorized, but at reduced accuracy — which is a *second* prompt, and
    /// one the recorder walks into on both the start and the resume path. It
    /// is as foreground-only as the first, so it is reported as its own answer
    /// rather than folded into ``granted``.
    case reducedAccuracy
    /// Nobody has been asked. The prompt is a foreground event, so an intent
    /// that finds this has to bring the app forward rather than silently fail
    /// to start.
    case undecided

    /// Whether starting or resuming from here would meet a prompt that only
    /// exists in the foreground.
    var needsForeground: Bool {
        switch self {
        case .reducedAccuracy, .undecided: true
        // `.denied` deliberately not: nothing on screen can undo a refusal
        // either, so bringing the app forward would buy an interruption and
        // no prompt. The recorder's own "allow location access in Settings"
        // is the whole answer.
        case .denied, .granted: false
        }
    }
}

/// A recording as it stands right now.
nonisolated struct LiveRecordingReport: Equatable, Sendable {
    let distance: Measurement<UnitLength>
    let elapsed: TimeInterval
    let isPaused: Bool
    /// The trail under the walker, when the live matcher has one. Spoken back
    /// because "2.4 km along the Kalvarienberg path" is the answer somebody
    /// asks a phone in their pocket for.
    let trailName: String?
    /// Whether ``trailName`` describes a match newer fixes have already
    /// overtaken — ``RecordingStats/isCurrentTrailStale``, which the recording
    /// screen dims the trail card for. Carried here so the sentence can hedge
    /// the same way the screen does; a walker who stepped off the path a
    /// minute ago must not be told flatly that they are still on it.
    let isTrailNameStale: Bool
}

/// A hike that is finished and saved.
nonisolated struct FinishedHikeReport: Equatable, Sendable {
    let id: UUID
    let title: String
    let date: Date
    let distance: Measurement<UnitLength>
    /// `nil` for a route carrying no clock — an imported GPX without
    /// timestamps. See ``HikeRouteStatistics``.
    let duration: TimeInterval?
}

/// Everything walked between two instants, which is how "today" is asked.
nonisolated struct HikeTotalsReport: Equatable, Sendable {
    let hikeCount: Int
    let distance: Measurement<UnitLength>
}

// MARK: - What gets said

nonisolated extension LiveRecordingReport {
    /// One sentence, spoken.
    ///
    /// `width: .wide` rather than the `.abbreviated` every screen in the app
    /// uses: this string is read aloud as often as it is displayed, and a
    /// speech synthesiser handed "2.4 km" is being asked to guess. `usage:
    /// .road` is kept, so the reader still hears their own region's units. The
    /// duration beside it goes through ``HikeFormat/spokenDuration(_:)`` for
    /// the same reason — half a wide sentence reads worse than none of one.
    var spokenSummary: String {
        let length = distance.formatted(
            .measurement(width: .wide, usage: .road)
        )
        let clock = HikeFormat.spokenDuration(elapsed)
        let lead = isPaused
            ? "Your hike is paused at \(length)"
            : "You're \(length) in"
        guard let trailName, !trailName.isEmpty else {
            return "\(lead), \(clock) elapsed."
        }
        // "last on" rather than "on" for a match newer fixes have overtaken.
        // It is the sentence's whole hedge, and it is the difference between
        // telling somebody where they are and telling them where they were.
        return isTrailNameStale
            ? "\(lead), last on \(trailName), \(clock) elapsed."
            : "\(lead) on \(trailName), \(clock) elapsed."
    }
}

nonisolated extension FinishedHikeReport {
    var spokenSummary: String {
        let length = distance.formatted(
            .measurement(width: .wide, usage: .road)
        )
        let day = date.formatted(date: .abbreviated, time: .omitted)
        guard let duration else {
            return "\(title): \(length) on \(day)."
        }
        return "\(title): \(length) in \(HikeFormat.spokenDuration(duration)) on \(day)."
    }
}

nonisolated extension HikeTotalsReport {
    /// Reads back the count as well as the distance, because zero and "one
    /// hike of no length" are different answers and the distance alone tells
    /// them apart only by accident.
    func spokenSummary(for label: String) -> String {
        guard hikeCount > 0 else { return "You haven't recorded a hike \(label)." }
        let length = distance.formatted(
            .measurement(width: .wide, usage: .road)
        )
        let hikes = hikeCount == 1 ? "1 hike" : "\(hikeCount) hikes"
        return "\(length) across \(hikes) \(label)."
    }
}
