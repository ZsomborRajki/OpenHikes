//
//  HikeActivityAttributes.swift
//  OpenHikesShared
//
//  The payload behind the Lock Screen and Dynamic Island Live Activity, for
//  the two things a walker can have running: a recording, and an imported
//  trail they are following.
//
//  It carries the same facts the home screen widget draws, and deliberately
//  through the same types — ``SharedRecordingSnapshot`` and
//  ``SharedTrailSnapshot`` are what build it, and ``TrailWidgetMetric`` is
//  what it renders. A Live Activity that rounded a distance differently from
//  the widget two inches above it would be the same bug the widget's own
//  formatting lives in this package to prevent.
//
//  What it does *not* carry is the polyline. ActivityKit gives an activity's
//  attributes and content state a combined 4 KB, and the widget's decimated
//  route is 180 coordinates — an order of magnitude over on its own. A Live
//  Activity is a status line, not a map, so the shape is dropped and the
//  progress bar keeps the thing the shape was there to convey.
//
//  The type's *name* is a storage contract in the same sense as
//  `SharedStore.appGroupID` and `TrailWidgetKind.id`: ActivityKit identifies a
//  running activity by its attributes type, so renaming this strands every
//  activity a previous build started.
//
//  ActivityKit itself is not imported here. Its `ActivityAttributes` protocol
//  is `@available(macOS, unavailable)`, and this package is compiled for macOS
//  by `swift test` — so the conformance lives behind `#if os(iOS)` in
//  `HikeActivityAttributes+ActivityKit.swift` and everything worth testing
//  lives here, where the host can reach it.
//

import Foundation

public struct HikeActivityAttributes: Codable, Hashable, Sendable {
    /// What the activity is about. Fixed for its whole life — ActivityKit
    /// only ever replaces the ``ContentState``, so anything that could change
    /// belongs there instead.
    ///
    /// One attributes type with two subjects rather than two types, because a
    /// walker can only be doing one of these at a time and the system should
    /// show one activity either way. Two types would make "end whichever is
    /// running" something every caller had to spell out twice.
    public enum Subject: Codable, Hashable, Sendable {
        case recording(sessionID: UUID)
        case following(hikeID: UUID)

        public var isRecording: Bool {
            if case .recording = self { return true }
            return false
        }

        /// The hike this activity is about, if it names one. A recording has
        /// a session rather than a saved hike, and deep-links to the recording
        /// screen instead — see ``HikeActivityAttributes/deepLink``.
        public var hikeID: UUID? {
            if case .following(let id) = self { return id }
            return nil
        }
    }

    public var subject: Subject
    /// The trail's name, or what to call a recording that has no name yet.
    public var title: String
    /// The route's tint, so the activity's progress bar matches the line the
    /// walker sees on the map and in the widget.
    public var tintHex: String
    /// When the walk started. Recordings show elapsed time from here; a follow
    /// uses it only to order activities.
    public var startedAt: Date
    /// The followed trail's total length. `nil` for a recording, which has no
    /// end to measure against — that asymmetry is the whole difference between
    /// the two presentations this payload drives.
    public var routeDistanceMeters: Double?

    public init(
        subject: Subject,
        title: String,
        tintHex: String,
        startedAt: Date,
        routeDistanceMeters: Double? = nil
    ) {
        self.subject = subject
        self.title = title
        self.tintHex = tintHex
        self.startedAt = startedAt
        self.routeDistanceMeters = routeDistanceMeters
    }

    /// Everything that changes while the activity runs.
    ///
    /// Optional for anything one subject has and the other doesn't, rather
    /// than split into two states: ActivityKit allows exactly one
    /// `ContentState` per attributes type, and a `nil` reads the same as the
    /// widget's "omit the chip" rule — a route imported without elevations
    /// shows fewer facts, not a row of dashes.
    public struct ContentState: Codable, Hashable, Sendable {
        /// What a recording is doing. A follow is always ``running``: it has
        /// no clock of its own to stop.
        ///
        /// A `String` raw value rather than the synthesized case-name coding,
        /// so the wire form is legible in a log and stays put if the cases are
        /// ever reordered.
        public enum RunState: String, Codable, Hashable, Sendable {
            case running = "running"
            case paused = "paused"
            case finished = "finished"
        }

        /// Recording: metres walked so far. Following: metres covered along
        /// the route. The same field because it means the same thing to the
        /// walker, and because a 4 KB budget is not the place for two.
        public var distanceMeters: Double
        public var elevationGainMeters: Double?
        /// The trail's height where the walker was matched — following only,
        /// and read off the route profile rather than from GPS, exactly as
        /// ``SharedTrailSnapshot/LiveFix/elevationMeters`` is.
        public var currentElevationMeters: Double?
        public var averageSpeedMetersPerSecond: Double?
        public var pointCount: Int?
        /// How far the last matched fix sat from the trail. `nil` means there
        /// is no usable fix at all — off route, or none yet — which is a
        /// different statement from "on it, zero metres away", and the reason
        /// this is optional rather than a large number.
        public var offRouteMeters: Double?
        /// Recording only: whether fixes are being taken, deliberately not,
        /// or done with.
        ///
        /// Three cases rather than a paused flag because the third one is
        /// reachable and says something different. A recording that has been
        /// stopped and saved stays on the Lock Screen for a few minutes
        /// showing what the walk came to — and a final panel reading "Paused"
        /// would be telling the walker their hike is still waiting for them.
        public var runState: RunState

        /// Whether the recording is deliberately stopped but not finished.
        /// Kept as the question most callers actually ask; ``runState`` is the
        /// stored answer.
        public var isPaused: Bool { runState == .paused }

        /// Whether the clock should be running. A finished walk's elapsed time
        /// is a result, not a measurement still being taken.
        public var isTicking: Bool { runState == .running }
        /// Recording time, the same figure `HikeRecorder.elapsedSeconds()`
        /// reports, so the activity and the recording screen cannot disagree.
        ///
        /// Carried as a duration rather than as a start date so the view can
        /// re-anchor a self-ticking `Text(timerInterval:)` on every update
        /// without the two drifting apart. See ``timerStart``.
        public var elapsedSeconds: TimeInterval
        public var updatedAt: Date

        public init(
            distanceMeters: Double,
            elevationGainMeters: Double? = nil,
            currentElevationMeters: Double? = nil,
            averageSpeedMetersPerSecond: Double? = nil,
            pointCount: Int? = nil,
            offRouteMeters: Double? = nil,
            runState: RunState = .running,
            elapsedSeconds: TimeInterval = 0,
            updatedAt: Date = .now
        ) {
            self.distanceMeters = distanceMeters
            self.elevationGainMeters = elevationGainMeters
            self.currentElevationMeters = currentElevationMeters
            self.averageSpeedMetersPerSecond = averageSpeedMetersPerSecond
            self.pointCount = pointCount
            self.offRouteMeters = offRouteMeters
            self.runState = runState
            self.elapsedSeconds = elapsedSeconds
            self.updatedAt = updatedAt
        }

        /// The instant a live timer should count from to read
        /// ``elapsedSeconds`` at ``updatedAt``.
        ///
        /// This is what lets the Lock Screen clock tick once a second while
        /// the app sends nothing at all: `Text(timerInterval:)` is rendered by
        /// the system, so the activity's update budget is spent on distance
        /// and ascent rather than on the seconds hand.
        public var timerStart: Date {
            updatedAt.addingTimeInterval(-elapsedSeconds)
        }
    }

    /// Where tapping the activity goes — the same links the widget uses, so a
    /// tap lands in the same place from either surface.
    public var deepLink: URL? {
        switch subject {
        case .recording: TrailWidgetDeepLink.recordingURL()
        case .following(let hikeID): TrailWidgetDeepLink.url(hikeID: hikeID)
        }
    }
}
