//
//  AutoPauseWatch.swift
//  OpenHikesShared
//
//  When a recording has stopped at a place, and when it has walked away from
//  it again: the rule Auto-Pause pauses and resumes a recording by (#1470).
//
//  ## A stop is a place, not stillness
//
//  In a supermarket a hiker keeps walking. Steps are counted, Core Motion
//  says walking, and GPS gets worse instead of quieter. What marks the stop is
//  that for minutes every position stays inside one small area, so that is
//  the rule: containment around the fix the stop began at, with no height
//  gained, for ``AutoPausePolicy/minimumStopSeconds``. Net displacement
//  between the two ends of a window is not it: on tight switchbacks a hiker
//  can be 20 m from where they stood five minutes ago, and 40 m higher.
//
//  ## Backdated both ways
//
//  A traffic light or a photograph is not a stop, so the rule is slow to
//  decide, and being slow costs nothing: ``Event/stopped(since:)`` names the
//  moment the stop began, and the recorder pauses from there. On the way out
//  the fixes of the walk away are kept until one is plainly outside the area,
//  and ``Event/departed(since:)`` names the first of them, where the next
//  segment starts.
//
//  ## Position decides, motion confirms
//
//  Motion & Fitness can be refused, and a phone on a pram counts no steps. So
//  every decision here can be made on positions alone, and motion only ever
//  answers what a position cannot:
//
//  - **A clock of its own.** Standing still widens the recorder's distance
//    filter, and on a bench under open sky no fix may arrive for the whole
//    lunch. ``tick(at:motion:)`` decides then, when the silence was still
//    from its start: by motion, which said so within
//    ``AutoPausePolicy/motionLagSeconds`` of the last fix, or by the last
//    fixes before it, which showed the hiker standing by the recorder's own
//    rule for widening its filter (``AutoPausePolicy/settledMeters``), not
//    merely staying in the area, which a walk does for half a minute.
//    Otherwise silence might be a tunnel, and only the fix that ends it can
//    tell: one back inside the area makes the whole silence a stop, and one
//    elsewhere is a lost signal. Motion that says on foot or carried at any
//    time in the silence makes it such a silence, however still the device
//    is when the clock runs out.
//  - **On foot, or not.** Leaving on foot ends the stop. A fix that motion or
//    its own speed says was carried — a bus, a lift, the drive home with the
//    recording forgotten — moves the place with it, and the stop holds until
//    the hiker walks away from wherever they were set down.
//
//  ## Why it is here
//
//  A value type with no clock of its own, as `MovementWatch` is, so each row
//  of the issue's table is a scripted stream under `swift test`. In this
//  package, on plain numbers, because the watch's recorder is to take the
//  same answer from it.
//

import Foundation

/// The thresholds a stop is decided by.
///
/// A value rather than constants so that a UI test can ask for a stop of
/// seconds; everything that ships uses ``standard``. The radius and the
/// minutes are the owner's choice and a first guess: no recording so far shows
/// what the inside of a shop looks like to Core Location, and the `DEBUG`
/// evidence log (``AutoPauseEvidence``) is how they are to be settled.
public struct AutoPausePolicy: Sendable, Equatable {
    /// How long every position has to stay in one area before it is a stop.
    public var minimumStopSeconds: TimeInterval
    /// How far from where the stop began a position may be and still be at
    /// it, before the fix's own accuracy is allowed for.
    public var stopRadiusMeters: Double
    /// How much height a stop may span. Read only from fixes that carry a
    /// barometric height: a GPS altitude wanders further than this by itself.
    public var stopHeightMeters: Double
    /// The loosest fix that can say where the hiker is. The recorder's own
    /// figure (`RecordingFixPolicy.maximumHorizontalAccuracy`), so a fix that
    /// may join the track is one that may begin or end a stop.
    public var maximumFixAccuracy: Double
    /// How long the fixes in the area have to show the hiker standing before
    /// a silence may be called a stop with no motion answer and no fix to end
    /// it. The time the recorder's distance takes to call a hiker stationary
    /// (`MovementThresholds.stationaryInterval`), after which it widens its
    /// filter and the fixes stop.
    public var settledSeconds: TimeInterval
    /// How far apart two fixes ``settledSeconds`` apart may be and still show
    /// the hiker standing: the net displacement the recorder's distance calls
    /// stationary (`MovementThresholds.stationaryNetDisplacement`). A walk
    /// stays in a stop's area for half a minute, and is plainly further.
    public var settledMeters: Double
    /// How long after the last fix motion may take to say the device is
    /// still, for the silence to be still from that fix. Any later, and the
    /// first minutes of the silence may have been walked: into a tunnel, and
    /// then a halt inside it.
    public var motionLagSeconds: TimeInterval
    /// The longest gap between two fixes of one walk away. A fix older than
    /// this was taken at the stop, not on the way out of it.
    public var departureGapSeconds: TimeInterval
    /// Faster than a person moves on foot (`MovementThresholds`).
    public var maximumOnFootSpeed: Double

    public init(
        minimumStopSeconds: TimeInterval,
        stopRadiusMeters: Double,
        stopHeightMeters: Double,
        maximumFixAccuracy: Double,
        settledSeconds: TimeInterval,
        settledMeters: Double,
        motionLagSeconds: TimeInterval,
        departureGapSeconds: TimeInterval,
        maximumOnFootSpeed: Double
    ) {
        self.minimumStopSeconds = minimumStopSeconds
        self.stopRadiusMeters = stopRadiusMeters
        self.stopHeightMeters = stopHeightMeters
        self.maximumFixAccuracy = maximumFixAccuracy
        self.settledSeconds = settledSeconds
        self.settledMeters = settledMeters
        self.motionLagSeconds = motionLagSeconds
        self.departureGapSeconds = departureGapSeconds
        self.maximumOnFootSpeed = maximumOnFootSpeed
    }

    public static let standard = Self(
        minimumStopSeconds: 5 * 60,
        stopRadiusMeters: 30,
        stopHeightMeters: 10,
        maximumFixAccuracy: 50,
        settledSeconds: 30,
        settledMeters: 15,
        motionLagSeconds: 60,
        departureGapSeconds: 60,
        maximumOnFootSpeed: 8
    )
}

/// One recording's stops, decided from the fixes it is shown.
public struct AutoPauseWatch: Sendable, Equatable {
    /// What the motion sensors said when a fix was taken.
    public enum Motion: String, Sendable, Equatable {
        /// No answer: refused, unavailable, or not sure.
        case unknown = "unknown"
        case stationary = "stationary"
        case onFoot = "onFoot"
        /// In or on something: a car, a bus, a bicycle.
        case carried = "carried"
    }

    /// A position as the rule reads it. Every delivered fix is one, whether
    /// or not the recorder kept it for the track.
    public struct Fix: Sendable, Equatable {
        public var latitude: Double
        public var longitude: Double
        public var timestamp: Date
        public var horizontalAccuracy: Double
        /// A barometric height, or `nil` for a fix that has none to trust.
        public var elevation: Double?
        /// The speed the fix itself reports, or `nil` when it reports none.
        public var speed: Double?
        public var motion: Motion

        public init(
            latitude: Double,
            longitude: Double,
            timestamp: Date,
            horizontalAccuracy: Double,
            elevation: Double? = nil,
            speed: Double? = nil,
            motion: Motion = .unknown
        ) {
            self.latitude = latitude
            self.longitude = longitude
            self.timestamp = timestamp
            self.horizontalAccuracy = horizontalAccuracy
            self.elevation = elevation
            self.speed = speed
            self.motion = motion
        }
    }

    public enum Event: Sendable, Equatable {
        /// The hiker has been at one place since `since`: pause from there.
        case stopped(since: Date)
        /// The hiker has walked away, and the first fix of that walk was
        /// taken at `since`: resume from there.
        case departed(since: Date)
    }

    /// A place the hiker may be stopping at.
    private struct Candidate: Sendable, Equatable {
        /// The fix every later one has stayed around.
        var anchor: Fix
        /// The fix the newest stretch of standing is measured from.
        var stillSince: Fix
        /// Whether the fixes in the area last showed the hiker standing, as
        /// the recorder's distance would call it: no further from
        /// ``stillSince`` than ``AutoPausePolicy/settledMeters``, at least
        /// ``AutoPausePolicy/settledSeconds`` after it.
        var isSettled = false

        init(anchor: Fix) {
            self.anchor = anchor
            stillSince = anchor
        }
    }

    private struct Stop: Sendable, Equatable {
        var place: Fix
        /// The fixes of a walk away that is not yet certain, oldest first:
        /// each further from the place than the one before it.
        var outbound: [Fix] = []
    }

    private enum State: Sendable, Equatable {
        case walking(Candidate?)
        case stopped(Stop)
    }

    /// The most fixes a walk away is remembered by. It is over within a few:
    /// each has to be further out than the last, and one clear of the area
    /// ends it.
    private static let maximumOutboundFixes = 16

    public let policy: AutoPausePolicy
    private var state = State.walking(nil)
    /// The newest fix this watch has taken. Fixes are stamped with when they
    /// were taken and do not always arrive in that order; an older one is
    /// dropped, as `MovementWatch` drops it.
    private var lastObservedAt: Date?
    /// The newest fix good enough to say where the hiker was: where a
    /// silence begins.
    private var lastPlacedAt: Date?
    /// When motion began saying the device is still, with nothing since but
    /// that or no answer, or `nil` while it says otherwise.
    private var stillSince: Date?
    /// Whether motion has said on foot or carried since ``lastPlacedAt``: a
    /// silence walked or ridden for any part of it, which only the fix that
    /// ends it can decide.
    private var movedSinceFix = false

    public init(policy: AutoPausePolicy = .standard) {
        self.policy = policy
    }

    /// Whether the watch has called a stop that nothing has ended yet.
    public var isStopped: Bool {
        if case .stopped = state { true } else { false }
    }

    /// When ``tick(at:motion:)`` could first call the place being watched a
    /// stop, or `nil` when there is none. The recorder sets its one timer by
    /// this, so a decision does not have to wait for a fix.
    public var decisionDate: Date? {
        guard case .walking(let candidate?) = state else { return nil }
        return candidate.anchor.timestamp.addingTimeInterval(policy.minimumStopSeconds)
    }

    /// Forgets everything: a pause or a resume by hand, or a new recording.
    public mutating func reset() {
        state = .walking(nil)
        lastObservedAt = nil
        lastPlacedAt = nil
        stillSince = nil
        movedSinceFix = false
    }

    /// Shows the watch one fix.
    public mutating func observe(_ fix: Fix) -> Event? {
        guard fix.horizontalAccuracy > 0, fix.latitude.isFinite, fix.longitude.isFinite else { return nil }
        if let lastObservedAt, fix.timestamp <= lastObservedAt { return nil }
        lastObservedAt = fix.timestamp
        if fix.horizontalAccuracy <= policy.maximumFixAccuracy {
            lastPlacedAt = fix.timestamp
            movedSinceFix = false
        }
        hear(fix.motion, at: fix.timestamp)
        switch state {
        case .walking(let candidate): return observeWalking(fix, around: candidate)
        case .stopped(let stop): return observeStopped(fix, at: stop)
        }
    }

    /// Asks whether the place being watched has become a stop with no fix to
    /// say so: the recorder's timer at ``decisionDate``, and each change of
    /// motion.
    public mutating func tick(at now: Date, motion: Motion) -> Event? {
        // Heard before the stop could be called as well as after: a silence
        // walked in its first minutes and halted in later is a tunnel, not a
        // stop, however still the device is when the clock runs out.
        hear(motion, at: now)
        guard case .walking(let candidate?) = state,
              now.timeIntervalSince(candidate.anchor.timestamp) >= policy.minimumStopSeconds,
              // A tunnel, a bus, or a shop walked around in with no fix
              // inside: the fix that ends the silence decides, and taking it
              // for a stop now would cut a walk out of the track.
              !movedSinceFix, motion != .onFoot, motion != .carried
        else { return nil }
        // Still from the start of the silence, by motion, or standing before
        // it, by the fixes, with nothing heard since to say otherwise.
        let stillThroughout = stillSince.flatMap { since in
            lastPlacedAt.map { since.timeIntervalSince($0) <= policy.motionLagSeconds }
        } ?? false
        guard stillThroughout || candidate.isSettled else { return nil }
        return stop(at: candidate.anchor)
    }

    /// Takes in what motion says at `date`, from a change of motion or a fix.
    private mutating func hear(_ motion: Motion, at date: Date) {
        switch motion {
        case .stationary:
            stillSince = stillSince ?? date
        case .onFoot, .carried:
            stillSince = nil
            if let lastPlacedAt, date > lastPlacedAt { movedSinceFix = true }
        // A low-confidence answer ends nothing: Core Motion gives one now
        // and then in the middle of a sit-down.
        case .unknown:
            break
        }
    }

    private mutating func observeWalking(_ fix: Fix, around candidate: Candidate?) -> Event? {
        let canAnchor = fix.horizontalAccuracy <= policy.maximumFixAccuracy
        guard let candidate else {
            if canAnchor { state = .walking(Candidate(anchor: fix)) }
            return nil
        }
        // Somewhere else, or higher or lower: the place being watched was
        // walked through, and this fix is where the next one may begin. A
        // loose fix can say the hiker has left, but is no place to stay
        // around.
        if isOutside(fix, of: candidate.anchor) || (canAnchor && hasClimbed(fix, from: candidate.anchor)) {
            state = .walking(canAnchor ? Candidate(anchor: fix) : nil)
            return nil
        }
        // A loose fix that may be inside the area says nothing either way.
        guard canAnchor else { return nil }
        guard fix.timestamp.timeIntervalSince(candidate.anchor.timestamp) >= policy.minimumStopSeconds else {
            state = .walking(holding(candidate, at: fix))
            return nil
        }
        return stop(at: candidate.anchor)
    }

    /// `candidate` once `fix`, inside its area, has been read for standing,
    /// as `RecordingDistanceAccumulator` reads a fix: the net displacement
    /// across at least ``AutoPausePolicy/settledSeconds``, measured again
    /// from each fix that showed the hiker moving.
    private func holding(_ candidate: Candidate, at fix: Fix) -> Candidate {
        guard fix.timestamp.timeIntervalSince(candidate.stillSince.timestamp) >= policy.settledSeconds else {
            return candidate
        }
        var held = candidate
        held.isSettled = distance(from: candidate.stillSince, to: fix) < policy.settledMeters
        if !held.isSettled { held.stillSince = fix }
        return held
    }

    private mutating func stop(at anchor: Fix) -> Event {
        state = .stopped(Stop(place: anchor))
        return .stopped(since: anchor.timestamp)
    }

    private mutating func observeStopped(_ fix: Fix, at stop: Stop) -> Event? {
        // Only a fix that could join the track can start the next segment.
        guard fix.horizontalAccuracy <= policy.maximumFixAccuracy else { return nil }
        var stop = stop
        // Never a step of a walk away. Carried somewhere else, the stop goes
        // with the hiker; carried about inside its area, as in a car at the
        // car park, it stays where it is.
        if isCarried(fix) {
            if isOutside(fix, of: stop.place) { stop.place = fix }
            stop.outbound = []
            state = .stopped(stop)
            return nil
        }
        let away = distance(from: stop.place, to: fix)
        if let last = stop.outbound.last,
           away > distance(from: stop.place, to: last),
           fix.timestamp.timeIntervalSince(last.timestamp) <= policy.departureGapSeconds {
            stop.outbound.append(fix)
            stop.outbound.removeFirst(max(0, stop.outbound.count - Self.maximumOutboundFixes))
        } else {
            stop.outbound = [fix]
        }
        guard isOutside(fix, of: stop.place) else {
            state = .stopped(stop)
            return nil
        }
        state = .walking(nil)
        // The recorder hands the fixes of the walk away back in order, as the
        // first of the next segment, and they are to be read again here.
        lastObservedAt = nil
        return .departed(since: stop.outbound[0].timestamp)
    }

    /// Whether `fix` was plainly taken outside the area around `place`: its
    /// whole circle of uncertainty is clear of it.
    private func isOutside(_ fix: Fix, of place: Fix) -> Bool {
        distance(from: place, to: fix) > policy.stopRadiusMeters + fix.horizontalAccuracy
    }

    private func hasClimbed(_ fix: Fix, from place: Fix) -> Bool {
        guard let height = fix.elevation, let placeHeight = place.elevation else { return false }
        return abs(height - placeHeight) > policy.stopHeightMeters
    }

    /// Motion says so, or the fix's own speed does while motion does not say
    /// the device is still: a single fix's speed can be a reflection off a
    /// wall as well as a bus.
    private func isCarried(_ fix: Fix) -> Bool {
        fix.motion == .carried
            || (fix.motion != .stationary && (fix.speed ?? 0) > policy.maximumOnFootSpeed)
    }

    private func distance(from start: Fix, to end: Fix) -> Double {
        WatchGeodesy.distanceMeters(
            fromLatitude: start.latitude,
            longitude: start.longitude,
            toLatitude: end.latitude,
            longitude: end.longitude
        )
    }
}
