//
//  JunctionGuide.swift
//  OpenHikes
//
//  Junction warnings: a voice, before each fork on the trail being followed,
//  saying which way the trail goes — "Keep left at the fork in 150 meters".
//
//  The off-trail question asks a hiker who has already taken the wrong turn.
//  This is for the turn itself, said while there is still time to take the
//  right one, as navigation apps say it. The trail graph knows where every
//  trail meets another (``TrailJunctionFinder``); the walk knows which line
//  is being followed and which way (``TrailWalkSession``); the announcer
//  decides when each junction is said (``JunctionAnnouncer``), as it does on
//  the watch, which taps instead.
//
//  ## When it runs
//
//  Only while the switch is on and a walk is *following*: not for a trail on
//  screen that nobody is walking, not through a pause, and not beside a
//  recording, which ends any walk. Then it takes fixes of its own, because a
//  warning has to come before the fork whether or not the phone is in a
//  pocket — see ``JunctionLocationFeed`` for what that costs and why. Off,
//  paused or ended, the feed stops and nothing is said.
//
//  ## The switch
//
//  Off until a hiker turns it on, from a button on the map's leading edge
//  that is there while a walk is under way (`MapCoordinator+JunctionButton.swift`).
//  A voice, and the location indicator that comes with the feed, are not
//  things to start for a hiker who has not asked. The answer is kept, so a
//  hiker who wants the warnings has them on every walk after, and the watch
//  is told it with the library (``WatchLibraryDigest/junctionWarningsEnabled``).
//
//  ## One observable, read by one leaf
//
//  ``isOn`` and ``isOffered`` change on a tap or a walk starting or ending,
//  and only the map button reads them. Everything that changes per fix is
//  `@ObservationIgnored`: nothing is drawn from it.
//

import CoreLocation
import Foundation
import Observation
import OpenHikesData
import OpenHikesShared
import os

@MainActor
@Observable
final class JunctionGuide {
    private static let logger = Logger(subsystem: "OpenHikes", category: "JunctionGuide")

    /// Whether the hiker wants junction warnings.
    private(set) var isOn: Bool
    /// Whether there is a walk for the switch to apply to, which is when the
    /// map offers it.
    private(set) var isOffered = false

    @ObservationIgnored private let walk: TrailWalkSession
    @ObservationIgnored private let graph: (any TrailGraphProviding)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let feed: any JunctionLocationFeeding
    @ObservationIgnored private let voice: any JunctionSpeaking
    /// The walk being guided, while one is.
    @ObservationIgnored private var guided: Guided?

    /// What guiding one walk has found out so far.
    private struct Guided {
        let hikeID: UUID
        /// The walked line, once it has been read and its junctions found.
        var profile: RouteProfile?
        var announcer: JunctionAnnouncer?
        /// Where the last fix on the trail matched, which the next is looked
        /// for near: a hiker walks a few metres between fixes.
        var lastDistance: Double?
        var preparation: Task<Void, Never>?
    }

    /// - Parameters:
    ///   - graph: the trail graph the junctions are read from. `nil` finds
    ///     none, and the guide says nothing.
    ///   - feed: where fixes come from — see ``JunctionLocationFeed``.
    ///   - voice: what they are said through — see ``JunctionVoice``.
    init(
        walk: TrailWalkSession,
        graph: (any TrailGraphProviding)?,
        defaults: UserDefaults,
        feed: any JunctionLocationFeeding,
        voice: any JunctionSpeaking
    ) {
        self.walk = walk
        self.graph = graph
        self.defaults = defaults
        self.feed = feed
        self.voice = voice
        isOn = defaults.object(forKey: SettingsKey.junctionWarningsEnabled) as? Bool
            ?? SettingsDefault.junctionWarningsEnabled
        watchWalk()
    }

    /// The guide this launch gets: the real feed and voice, or, for a launch
    /// that must not reach Core Location or the audio session — a hosted
    /// suite, or a UI test, where a background session would outlive the
    /// test — a guide that keeps its switch, takes no fix and says nothing.
    static func forThisLaunch(
        walk: TrailWalkSession,
        graph: (any TrailGraphProviding)?,
        defaults: UserDefaults
    ) -> JunctionGuide {
        #if os(iOS)
        if !AppLaunchEnvironment.isRunningTests {
            return JunctionGuide(
                walk: walk,
                graph: graph,
                defaults: defaults,
                feed: SystemJunctionLocationFeed(),
                voice: SystemJunctionVoice()
            )
        }
        #endif
        return JunctionGuide(
            walk: walk,
            graph: graph,
            defaults: defaults,
            feed: DormantJunctionLocationFeed(),
            voice: SilentJunctionVoice()
        )
    }

    /// The map button.
    ///
    /// Turning the warnings on says so aloud, which is also the hiker's check
    /// that the volume is up before the first fork.
    func toggle() {
        isOn.toggle()
        defaults.set(isOn, forKey: SettingsKey.junctionWarningsEnabled)
        if isOn { voice.speak(String(localized: "Junction warnings on")) }
        sync()
    }

    /// Whether a walk's junctions have been found and the guide is listening
    /// for the fixes that reach them — for a suite to wait on.
    var isGuiding: Bool { guided?.announcer != nil }

    /// The junctions of the walk being guided, once found.
    var junctions: [TrailJunction] { guided?.announcer?.junctions ?? [] }

    private func watchWalk() {
        sync()
        reobserving(self, walk) {
            _ = walk.phase
            _ = walk.walkedHikeID
        } onChange: { guide, _ in
            guide.watchWalk()
        }
    }

    /// Starts guiding the walk under way, stops guiding one that is no
    /// longer following, and moves the button's two flags.
    private func sync() {
        let walkedHikeID = walk.walkedHikeID
        let offered = walkedHikeID != nil
        if isOffered != offered { isOffered = offered }
        guard isOn, walk.phase == .following, let walkedHikeID else {
            stop()
            return
        }
        guard guided?.hikeID != walkedHikeID else { return }
        stop()
        start(hikeID: walkedHikeID)
    }

    private func start(hikeID: UUID) {
        guided = Guided(hikeID: hikeID)
        feed.start { [weak self] fix in self?.receive(fix) }
        guided?.preparation = Task { [weak self, walk, graph] in
            guard let line = await walk.lineForJunctions() else { return }
            let found = await TrailJunctionFinder.junctions(along: line, from: graph)
            guard !Task.isCancelled, let self, guided?.hikeID == hikeID else { return }
            prepared(line, junctions: found)
        }
    }

    /// The walk's line and junctions, found: from here on its fixes are
    /// matched and its junctions announced.
    private func prepared(_ line: RouteProfile, junctions found: [TrailJunction]) {
        guided?.profile = line
        guided?.announcer = JunctionAnnouncer(junctions: found, direction: walk.travelDirection)
        Self.logger.info("Guiding a walk past \(found.count, privacy: .public) junctions")
    }

    private func stop() {
        guard let current = guided else { return }
        current.preparation?.cancel()
        guided = nil
        feed.stop()
        voice.stopSpeaking()
    }

    private func receive(_ fix: JunctionFix) {
        guard var current = guided, let profile = current.profile, var announcer = current.announcer else { return }
        // Continuity alone once there is a match. On the way back down an
        // out-and-back it may put the hiker on the outbound leg, walking it
        // backwards, and the advice for that is the same advice: a junction
        // carries what to do walking either way.
        guard let match = profile.nearestPoint(to: fix.coordinate, near: current.lastDistance, heading: fix.course)
        else { return }
        let onTrail = match.offRouteMeters <= RouteProfile.followMatchThresholdMeters
        if onTrail { current.lastDistance = match.distanceAlongRoute }
        let cue = announcer.advance(to: match.distanceAlongRoute, isOnTrail: onTrail)
        current.announcer = announcer
        guided = current
        if let cue { voice.speak(cue.sentence) }
    }
}
