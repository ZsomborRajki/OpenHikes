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

/// Whether Core Location has been asked yet, which is the one thing that
/// decides whether "start a hike" can be answered without the app on screen.
///
/// A separate type from ``RecordingLocationAuthorization`` so the intents do
/// not reach through the recorder into Core Location's vocabulary; the mapping
/// is one line in ``HikeIntentCoordinator``.
nonisolated enum HikeIntentAuthorization: Equatable, Sendable {
    case denied
    case granted
    /// Nobody has been asked. The prompt is a foreground event, so an intent
    /// that finds this has to hand the walker back to the app rather than
    /// silently fail to start.
    case undecided
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
    /// .road` is kept, so the reader still hears their own region's units.
    var spokenSummary: String {
        let length = distance.formatted(
            .measurement(width: .wide, usage: .road)
        )
        let clock = HikeFormat.duration(elapsed)
        let lead = isPaused
            ? "Your hike is paused at \(length)"
            : "You're \(length) in"
        guard let trailName, !trailName.isEmpty else {
            return "\(lead), \(clock) elapsed."
        }
        return "\(lead) on \(trailName), \(clock) elapsed."
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
        return "\(title): \(length) in \(HikeFormat.duration(duration)) on \(day)."
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
