//
//  WatchAutoPause.swift
//  OpenHikesShared
//
//  Auto-Pause on the watch's own recordings (#1470): what `WatchRecorder`
//  does with ``AutoPauseWatch``'s answers, decided here because the watch has
//  no test bundle (*The watch app* in AGENTS.md).
//
//  ## The phone's rule, fed by the watch's fixes
//
//  The same ``AutoPauseWatch``, so a stop is the same five minutes in the
//  same area on either device, and a walk recorded on the wrist reaches the
//  phone cut where a phone would have cut it. What the watch does not have
//  is motion: it reads no Core Motion, so the rule runs as it does on a
//  phone whose Motion & Fitness was refused. A stop with fixes arriving is
//  called five minutes in; a silence, by the fixes before it showing the
//  hiker standing, or by the fix that ends it. Nor does it have a barometric
//  height, so no fix carries one to the rule, which then reads ground and
//  not height, as the phone does without a barometer.
//
//  ## What a pause costs here
//
//  Nothing more than walking. A pause by hand on the watch already keeps the
//  location feed running, because the workout session that keeps the app
//  alive needs it (`WatchRecorder.pause()`), so an auto-pause changes nothing
//  about what the watch spends. The fixes delivered during one are held and
//  shown to the rule, not added to the track, and once the rule says the
//  hiker has walked away the ones of that walk are handed back in order, as
//  the first of the next segment.
//
//  ## Whose pause it is
//
//  Only the app's own pause ends by itself. Resume ends it at once, and the
//  switch going off makes it the hiker's. A relaunch under the workout
//  session HealthKit hands back takes it up again (``resumePause()``): the
//  hiker never saw the process end, the screen told them the recording
//  resumes when they walk on, and the watch has no reminder to tell them
//  otherwise, as the phone's has for the pause a relaunch makes the hiker's
//  there. Nothing of the stop's own place was kept, so the first fix after
//  the relaunch stands for it.
//
//  ## A walk away the clock got ahead of
//
//  A stop with no fix in it is called by the clock, on the fixes before the
//  silence showing the hiker standing. Should a walk away be delivered in a
//  late batch, its first fix is older than the moment the stop was called,
//  and the stop may have been shorter than one. Nothing can be done about
//  the cut by then, so the departure says so (``Departure/beganBeforeThePause``)
//  and the recorder logs it: whether a watch in a workout batches its fixes
//  at all is a device question.
//

import Foundation

/// One watch recording's Auto-Pause: the rule, the switch, and the fixes
/// held while the app's own pause is in force.
///
/// Generic over what the recorder holds for a fix, so the recorder can be
/// handed back the `CLLocation`s of the walk away and a suite can script
/// plain values.
public struct WatchAutoPause<Location: Sendable>: Sendable {
    /// The walk away from a stop the app paused at.
    public struct Departure: Sendable {
        /// The first fix of the walk away was taken then: resume from there.
        public let since: Date
        /// The fixes of the walk away, oldest first, for the track.
        public let walkedAway: [Location]
        /// Whether the walk away began before the clock called the pause:
        /// its fixes arrived late, and the stop may have been shorter than
        /// one.
        public let beganBeforeThePause: Bool
    }

    private struct Held: Sendable {
        let fix: AutoPauseWatch.Fix
        let location: Location
    }

    /// More than a walk away is ever remembered by, with room for the loose
    /// fixes between them: the phone's figure
    /// (`RecordingAutoPause.maximumHeldFixes`).
    static var maximumHeldFixes: Int { 64 }

    private var watch: AutoPauseWatch
    /// The newest fixes of the pause in force, oldest first. An array where
    /// the phone holds a `Deque`: this package links no dependencies, and
    /// shifting at most ``maximumHeldFixes`` per fix costs nothing.
    private var held: [Held] = []

    /// Whether the pause in force is one the app made, and will end by
    /// itself.
    public private(set) var isPaused = false
    /// When the pause in force was called, or `nil` for one taken up after
    /// a relaunch.
    private var calledAt: Date?
    /// Whether the pause in force was taken up after a relaunch and still
    /// waits for a fix to stand for its place.
    private var awaitsPlace = false

    /// The hiker's switch. Turned off, it forgets the place being watched
    /// and makes a pause the app made the hiker's.
    public var isEnabled = true {
        didSet { if !isEnabled { reset() } }
    }

    public init(policy: AutoPausePolicy = .standard) {
        watch = AutoPauseWatch(policy: policy)
    }

    /// When ``tick(at:)`` could first call the place being watched a stop,
    /// or `nil` when nothing could be called: the recorder's one timer.
    public var decisionDate: Date? {
        isEnabled && !isPaused ? watch.decisionDate : nil
    }

    /// Shows the rule a fix delivered to a running recording, kept for the
    /// track or not.
    ///
    /// - Returns: when the stop began, if this fix makes one: pause from
    ///   then. The fix is the stop's, and joins no track.
    public mutating func observe(_ fix: AutoPauseWatch.Fix) -> Date? {
        guard isEnabled, !isPaused, case .stopped(let since) = watch.observe(fix) else { return nil }
        return pause(since: since, calledAt: fix.timestamp)
    }

    /// Asks the rule whether the hiker has stopped with no fix to say so.
    ///
    /// - Returns: when the stop began, if it is one now: pause from then.
    public mutating func tick(at now: Date) -> Date? {
        guard isEnabled, !isPaused, case .stopped(let since) = watch.tick(at: now, motion: .unknown) else {
            return nil
        }
        return pause(since: since, calledAt: now)
    }

    /// Takes up the app's pause after a relaunch, from wherever the hiker is
    /// when the next fix good enough to place them arrives.
    public mutating func resumePause() {
        guard isEnabled else { return }
        reset()
        isPaused = true
        awaitsPlace = true
    }

    /// A fix delivered while the app's own pause is in force.
    ///
    /// - Returns: the walk away, if this fix makes one certain. The pause is
    ///   over then, and the fixes it holds are the next segment's.
    public mutating func hold(_ fix: AutoPauseWatch.Fix, as location: Location) -> Departure? {
        guard isPaused else { return nil }
        held.append(Held(fix: fix, location: location))
        if held.count > Self.maximumHeldFixes { held.removeFirst() }
        if awaitsPlace {
            awaitsPlace = !watch.resumeStop(at: fix)
            return nil
        }
        guard case .departed(let since) = watch.observe(fix) else { return nil }
        let walkedAway = held.filter { $0.fix.timestamp >= since }.map(\.location)
        let beganBeforeThePause = calledAt.map { since < $0 } ?? false
        isPaused = false
        calledAt = nil
        held = []
        return Departure(since: since, walkedAway: walkedAway, beganBeforeThePause: beganBeforeThePause)
    }

    /// Forgets the place being watched and any pause the app made: a pause
    /// or a resume by hand, and every way a recording begins or ends.
    public mutating func reset() {
        isPaused = false
        calledAt = nil
        awaitsPlace = false
        held = []
        watch.reset()
    }

    private mutating func pause(since: Date, calledAt: Date) -> Date {
        isPaused = true
        self.calledAt = calledAt
        held = []
        return since
    }
}
