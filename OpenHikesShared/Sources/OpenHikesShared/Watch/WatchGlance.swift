//
//  WatchGlance.swift
//  OpenHikesShared
//
//  What the watch's complication knows about the watch's own recording, and
//  every decision it makes about it.
//
//  ## One way in, and it stays on the watch
//
//  The complication is a second process on the watch, and the recording lives
//  in the app's: ``WatchStore`` keeps the library, the trail packages and the
//  finished walks, never a live recording. So the recorder writes this small
//  snapshot into the watch's own App Group, and the widget extension reads it
//  and nothing else. It never crosses to the phone — see
//  ``WatchRecordedWalk`` for why a recording in progress never does — and the
//  complication never computes a figure: distance and the clock are the
//  recorder's, exactly as the phone's widget draws its snapshot.
//
//  ## The decisions live here
//
//  *The watch app* in the repository instructions: anything worth asserting
//  belongs in this package, where `swift test` reaches it. The extension is
//  WidgetKit and SwiftUI; what it shows, when a glance is too old to believe,
//  and when a redraw is worth spending are ``WatchGlanceDisplay`` and
//  ``WatchGlanceReloadPolicy``.
//

import Foundation

/// The watch recording as the complication sees it.
public struct WatchGlance: Codable, Equatable, Sendable {
    /// A `String` raw value, for the reason every payload state here has one:
    /// legible on disk and stable if the cases are reordered.
    public enum State: String, Codable, Sendable {
        case idle = "idle"
        case paused = "paused"
        case recording = "recording"
    }

    public var state: State
    public var distanceMeters: Double
    /// The recording's clock with its pauses taken out, as of ``updatedAt``.
    public var activeSeconds: TimeInterval
    public var updatedAt: Date

    public init(state: State, distanceMeters: Double, activeSeconds: TimeInterval, updatedAt: Date) {
        self.state = state
        self.distanceMeters = distanceMeters
        self.activeSeconds = activeSeconds
        self.updatedAt = updatedAt
    }

    public static func idle(at date: Date) -> Self {
        Self(state: .idle, distanceMeters: 0, activeSeconds: 0, updatedAt: date)
    }
}

/// What the complication draws.
public enum WatchGlanceDisplay: Equatable, Sendable {
    /// Nothing is being recorded: the app's glyph, and a tap opens it.
    case idle
    /// A paused recording: the distance and the frozen clock.
    case paused(distance: String, elapsed: String)
    /// A running one: the distance, and a clock the system ticks from
    /// `timerStart` without a timeline entry per second.
    case recording(distance: String, timerStart: Date)

    /// How long a recording's glance is believed without a fresh write.
    ///
    /// Generous on purpose. The recorder writes on every phase change and
    /// whenever the distance has moved enough to be worth a redraw, so a
    /// hiker standing still for an hour with a recording running writes
    /// nothing, and that recording is still true. What this catches is the
    /// app having gone away without saying so — a crash mid-walk — where a
    /// complication showing a clock ticking for a walk that ended at noon is
    /// the one wrong answer worth avoiding.
    public static let staleAfter: TimeInterval = 6 * 3600

    public init(_ glance: WatchGlance?, now: Date, locale: Locale = .current) {
        guard let glance, glance.state != .idle,
              now.timeIntervalSince(glance.updatedAt) < Self.staleAfter else {
            self = .idle
            return
        }
        let distance = WidgetFormat.length(meters: glance.distanceMeters, locale: locale)
        switch glance.state {
        case .recording:
            let timerStart = glance.updatedAt.addingTimeInterval(-glance.activeSeconds)
            self = .recording(distance: distance, timerStart: timerStart)
        case .paused:
            self = .paused(distance: distance, elapsed: WidgetFormat.duration(seconds: glance.activeSeconds))
        case .idle:
            self = .idle
        }
    }
}

/// Whether a new glance is worth writing and a complication reload.
///
/// WidgetKit budgets a watch's reloads the way it budgets a phone's, and the
/// phone widget's argument holds here twice over: a reload per fix would
/// spend the day's budget in the first hour of a walk and the battery with
/// it. So a change of state always reloads — starting, pausing, resuming and
/// stopping are what the hiker looks at the wrist to confirm — and the
/// distance only once it has moved far enough, long enough after the last.
public enum WatchGlanceReloadPolicy {
    /// How far the distance has to move before the figure is redrawn.
    public static let minimumDistanceMeters = 250.0
    /// And how long after the last redraw.
    public static let minimumInterval: TimeInterval = 5 * 60

    public static func shouldReload(from previous: WatchGlance?, to next: WatchGlance) -> Bool {
        guard let previous else { return true }
        if previous.state != next.state { return true }
        guard next.state == .recording else { return false }
        return abs(next.distanceMeters - previous.distanceMeters) >= minimumDistanceMeters
            && next.updatedAt.timeIntervalSince(previous.updatedAt) >= minimumInterval
    }
}

/// Where the glance is kept between the app and the extension.
public enum WatchGlanceStore {
    /// The watch's own App Group — the app and its complication, never the
    /// phone. Registered for both bundle identifiers in the developer portal.
    public static let appGroupID = "group.tappium.com.OpenHikes.watch"
    /// The complication's widget kind, which the app reloads by.
    public static let widgetKind = "WatchRecordingGlance"
    private static let fileName = "watch-glance.json"

    static func url(in container: URL) -> URL {
        container.appending(path: fileName)
    }

    private static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// The last glance written, or `nil` with none or no container.
    public static func load(from container: URL? = nil) -> WatchGlance? {
        guard let directory = container ?? containerURL,
              let data = try? Data(contentsOf: url(in: directory)) else { return nil }
        return try? JSONDecoder().decode(WatchGlance.self, from: data)
    }

    /// Writes `glance` atomically, so the extension never reads half of one.
    @discardableResult public static func save(_ glance: WatchGlance, to container: URL? = nil) -> Bool {
        guard let directory = container ?? containerURL,
              let data = try? JSONEncoder().encode(glance) else { return false }
        return (try? data.write(to: url(in: directory), options: .atomic)) != nil
    }
}
