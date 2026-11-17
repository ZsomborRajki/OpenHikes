//
//  AutoPauseWatchTests.swift
//  OpenHikesSharedTests
//
//  When a recording has stopped at a place and when it has walked away, one
//  scripted stream of fixes for each row of #1470's table: a shop walked
//  around in, a bench no fix arrives at, a traffic light, switchbacks, a
//  tunnel, a drive after a stop, and all of it again with no motion answer.
//

import Foundation
@testable import OpenHikesShared
import Testing

// swiftlint:disable no_magic_numbers

@Suite("Auto-pause watch")
struct AutoPauseWatchTests {
    private static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let latitude = 47.63
    private static let longitude = 12.86
    private static let metersPerDegree = WatchGeodesy.earthRadiusMeters * .pi / 180

    /// A fix `north` metres up the path from the trailhead, `seconds` into
    /// the walk.
    private static func fix(
        north: Double,
        at seconds: TimeInterval,
        accuracy: Double = 8,
        elevation: Double? = nil,
        speed: Double? = nil,
        motion: AutoPauseWatch.Motion = .unknown
    ) -> AutoPauseWatch.Fix {
        AutoPauseWatch.Fix(
            latitude: latitude + north / metersPerDegree,
            longitude: longitude,
            timestamp: start.addingTimeInterval(seconds),
            horizontalAccuracy: accuracy,
            elevation: elevation,
            speed: speed,
            motion: motion
        )
    }

    private static func time(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    /// Shows the watch each fix, and gives back what it said, with nothing
    /// for the fixes it said nothing about.
    private static func events(
        _ watch: inout AutoPauseWatch,
        observing fixes: [AutoPauseWatch.Fix]
    ) -> [AutoPauseWatch.Event] {
        fixes.compactMap { watch.observe($0) }
    }

    /// A walk up the path at a metre a second, a fix every ten metres, from
    /// `north` metres at `seconds`.
    private static func walk(
        from north: Double,
        at seconds: TimeInterval,
        fixes count: Int,
        motion: AutoPauseWatch.Motion = .unknown
    ) -> [AutoPauseWatch.Fix] {
        (0..<count).map { step in
            fix(north: north + Double(step) * 10, at: seconds + Double(step) * 10, speed: 1, motion: motion)
        }
    }

    // MARK: - The issue's table

    /// Twenty minutes in a shop, walking around: the fixes inside are too
    /// loose to say anything, and the first good one, back at the door, is
    /// what makes the whole of it a stop.
    @Test("a shop walked around in is one pause, door to door")
    func supermarket() {
        var watch = AutoPauseWatch()
        let approach = Self.walk(from: 0, at: 0, fixes: 10, motion: .onFoot)
        let inside = stride(from: 120.0, to: 1260, by: 60).map { seconds in
            let wandering = seconds.truncatingRemainder(dividingBy: 45)
            return Self.fix(north: 110 + wandering, at: seconds, accuracy: 80, motion: .onFoot)
        }
        let atTheDoor = Self.fix(north: 95, at: 1290, motion: .onFoot)
        let away = Self.walk(from: 105, at: 1300, fixes: 4, motion: .onFoot)

        #expect(Self.events(&watch, observing: approach + inside).isEmpty)
        #expect(watch.tick(at: Self.time(700), motion: .onFoot) == nil, "walking around inside is not stillness")
        #expect(watch.observe(atTheDoor) == .stopped(since: Self.time(80)))
        #expect(Self.events(&watch, observing: away) == [.departed(since: Self.time(1300))])
    }

    /// The recorder's filter widens once it calls the hiker stationary, and
    /// then no fix arrives: the clock decides, because the area was seen held
    /// before the silence.
    @Test("a bench no fix arrives at is paused by the clock, from sitting down")
    func benchSeenHeldBeforeTheSilence() {
        var watch = AutoPauseWatch()
        let approach = Self.walk(from: 0, at: 0, fixes: 5)
        let settling = [Self.fix(north: 43, at: 55), Self.fix(north: 41, at: 75)]

        #expect(Self.events(&watch, observing: approach + settling).isEmpty)
        #expect(watch.decisionDate == Self.time(340))
        #expect(watch.tick(at: Self.time(339), motion: .unknown) == nil)
        #expect(watch.tick(at: Self.time(340), motion: .unknown) == .stopped(since: Self.time(40)))
        #expect(watch.isStopped)
        #expect(watch.decisionDate == nil)
    }

    @Test("a bench reached with no fix after it is paused once motion says the device is still")
    func benchWithMotion() {
        var watch = AutoPauseWatch()
        #expect(Self.events(&watch, observing: Self.walk(from: 0, at: 0, fixes: 5)).isEmpty)

        #expect(watch.tick(at: Self.time(400), motion: .onFoot) == nil)
        #expect(watch.tick(at: Self.time(400), motion: .stationary) == .stopped(since: Self.time(40)))
    }

    @Test("the first steps away from a stop resume it, from the first of them")
    func walkingAwayResumes() {
        var watch = AutoPauseWatch()
        _ = Self.events(&watch, observing: Self.walk(from: 0, at: 0, fixes: 5))
        #expect(watch.tick(at: Self.time(2400), motion: .stationary) != nil)

        let firstSteps = Self.fix(north: 62, at: 2460, speed: 1)
        let clear = Self.fix(north: 87, at: 2485, speed: 1)
        #expect(watch.observe(firstSteps) == nil, "22 m from the bench could still be the bench")
        #expect(watch.observe(clear) == .departed(since: Self.time(2460)))
        #expect(!watch.isStopped)
    }

    @Test("a traffic light, a photograph or a look at the map is not a stop")
    func shortStops() {
        var watch = AutoPauseWatch()
        let approach = Self.walk(from: 0, at: 0, fixes: 5)
        let waiting = stride(from: 50.0, through: 280, by: 10).map { Self.fix(north: 42, at: $0) }
        let onward = Self.walk(from: 50, at: 290, fixes: 12)

        #expect(Self.events(&watch, observing: approach + waiting + onward).isEmpty)
        #expect(watch.tick(at: Self.time(400), motion: .unknown) == nil)
    }

    /// Never more than 30 m from where it began, and 60 m higher by the end.
    @Test("a slow scramble is not a stop while height is gained")
    func scramble() {
        var watch = AutoPauseWatch()
        let scramble = (0..<60).map { step in
            Self.fix(north: Double(step % 3) * 8, at: Double(step) * 10, elevation: 600 + Double(step), motion: .onFoot)
        }

        #expect(Self.events(&watch, observing: scramble).isEmpty)
        #expect(!watch.isStopped)
    }

    @Test("tight switchbacks are not a stop while ground is gained")
    func switchbacks() {
        var watch = AutoPauseWatch()
        // Back and forth across a slope 80 m wide, for ten minutes.
        let legs = (0..<60).map { step in
            let along = Double(step % 16)
            return Self.fix(north: (along < 8 ? along : 16 - along) * 10, at: Double(step) * 10)
        }

        #expect(Self.events(&watch, observing: legs).isEmpty)
    }

    /// Six silent minutes that end 400 m on: only the fix that ends the
    /// silence can tell, and it says the signal was lost.
    @Test("an underpass walked through with no signal is not a stop")
    func lostSignal() {
        var watch = AutoPauseWatch()
        #expect(Self.events(&watch, observing: Self.walk(from: 0, at: 0, fixes: 5, motion: .onFoot)).isEmpty)

        #expect(watch.tick(at: Self.time(340), motion: .onFoot) == nil)
        #expect(watch.observe(Self.fix(north: 440, at: 400, motion: .onFoot)) == nil)
        #expect(!watch.isStopped)
        #expect(watch.decisionDate == Self.time(700), "the far end is where the next stop may begin")
    }

    @Test("silence that ends where it began is a stop, from when it began")
    func silenceEndingWhereItBegan() {
        var watch = AutoPauseWatch()
        #expect(Self.events(&watch, observing: Self.walk(from: 0, at: 0, fixes: 5)).isEmpty)

        #expect(watch.observe(Self.fix(north: 55, at: 1240)) == .stopped(since: Self.time(40)))
    }

    /// The case #472 described: the recording forgotten, and the drive home.
    @Test("a drive after a stop stays paused until the hiker walks again")
    func driveAfterAStop() {
        var watch = AutoPauseWatch()
        _ = Self.events(&watch, observing: Self.walk(from: 0, at: 0, fixes: 5))
        #expect(watch.tick(at: Self.time(900), motion: .stationary) != nil)

        let drive = (1...20).map { step in
            Self.fix(north: 40 + Double(step) * 150, at: 900 + Double(step) * 10, speed: 15, motion: .carried)
        }
        #expect(Self.events(&watch, observing: drive).isEmpty)
        #expect(watch.isStopped)

        let setDown = Self.fix(north: 3045, at: 1160, speed: 0.4, motion: .onFoot)
        let walkingOn = Self.fix(north: 3090, at: 1200, speed: 1.2, motion: .onFoot)
        #expect(watch.observe(setDown) == nil)
        #expect(watch.observe(walkingOn) == .departed(since: Self.time(1160)))
    }

    /// With no motion answer a fix's own speed is what says it was carried.
    @Test("a fix faster than anyone walks is carried, whatever motion says")
    func carriedBySpeedAlone() {
        var watch = AutoPauseWatch()
        _ = Self.events(&watch, observing: Self.walk(from: 0, at: 0, fixes: 5))
        #expect(watch.observe(Self.fix(north: 45, at: 400)) != nil)

        #expect(watch.observe(Self.fix(north: 400, at: 430, speed: 12)) == nil)
        #expect(watch.isStopped)
    }

    /// Fixes keep arriving, because the receiver wanders under trees, and no
    /// motion answer is ever given.
    @Test("with motion refused, positions alone find the stop and the walk away")
    func positionAlone() {
        var watch = AutoPauseWatch()
        let approach = Self.walk(from: 0, at: 0, fixes: 5)
        let wandering = stride(from: 60.0, through: 360, by: 30).map { seconds in
            Self.fix(north: 40 + seconds.truncatingRemainder(dividingBy: 17), at: seconds, accuracy: 15)
        }
        let events = Self.events(&watch, observing: approach + wandering)

        #expect(events == [.stopped(since: Self.time(40))])
        #expect(Self.events(&watch, observing: Self.walk(from: 60, at: 2000, fixes: 4)) == [
            .departed(since: Self.time(2000)),
        ])
    }

    // MARK: - The rule's edges

    @Test("a fix too loose to join the track cannot begin a stop")
    func looseFixIsNoAnchor() {
        var watch = AutoPauseWatch()
        let loose = stride(from: 0.0, through: 600, by: 30).map { Self.fix(north: 0, at: $0, accuracy: 65) }

        #expect(Self.events(&watch, observing: loose).isEmpty)
        #expect(watch.decisionDate == nil)
    }

    @Test("a loose fix plainly somewhere else ends the watch on a place")
    func looseFixElsewhere() {
        var watch = AutoPauseWatch()
        _ = watch.observe(Self.fix(north: 0, at: 0))
        #expect(watch.decisionDate != nil)

        _ = watch.observe(Self.fix(north: 500, at: 200, accuracy: 100))
        #expect(watch.decisionDate == nil)
    }

    @Test("a fix older than one already seen is dropped")
    func outOfOrderFix() {
        var watch = AutoPauseWatch()
        _ = watch.observe(Self.fix(north: 0, at: 100))

        #expect(watch.observe(Self.fix(north: 0, at: 50)) == nil)
        #expect(watch.decisionDate == Self.time(400), "the place is still watched from the fix that named it")
    }

    /// The hiker moved to another table, 25 m off, and sat there a quarter of
    /// an hour before leaving: the next segment starts when they left, not
    /// when they changed tables.
    @Test("a fix taken at the stop long before the walk away is not its first step")
    func oldFixIsNotAFirstStep() {
        var watch = AutoPauseWatch()
        _ = Self.events(&watch, observing: Self.walk(from: 0, at: 0, fixes: 5))
        #expect(watch.tick(at: Self.time(600), motion: .stationary) != nil)

        #expect(watch.observe(Self.fix(north: 65, at: 700)) == nil)
        #expect(watch.observe(Self.fix(north: 90, at: 1600)) == .departed(since: Self.time(1600)))
    }

    @Test("a fix back toward the stop starts the walk away again")
    func steppingBackRestartsTheWalkAway() {
        var watch = AutoPauseWatch()
        _ = Self.events(&watch, observing: Self.walk(from: 0, at: 0, fixes: 5))
        #expect(watch.tick(at: Self.time(600), motion: .stationary) != nil)

        #expect(watch.observe(Self.fix(north: 62, at: 700)) == nil)
        #expect(watch.observe(Self.fix(north: 52, at: 720)) == nil)
        #expect(watch.observe(Self.fix(north: 85, at: 745)) == .departed(since: Self.time(720)))
    }

    @Test("a reset forgets the stop and the place")
    func reset() {
        var watch = AutoPauseWatch()
        _ = Self.events(&watch, observing: Self.walk(from: 0, at: 0, fixes: 5))
        #expect(watch.tick(at: Self.time(600), motion: .stationary) != nil)

        watch.reset()

        #expect(!watch.isStopped)
        #expect(watch.decisionDate == nil)
        #expect(watch.observe(Self.fix(north: 40, at: 10)) == nil, "an earlier fix is read again after a reset")
        #expect(watch.decisionDate == Self.time(310))
    }

    @Test("a shorter policy calls a shorter stop")
    func shorterPolicy() {
        var policy = AutoPausePolicy.standard
        policy.minimumStopSeconds = 5
        var watch = AutoPauseWatch(policy: policy)

        #expect(watch.observe(Self.fix(north: 0, at: 0)) == nil)
        #expect(watch.observe(Self.fix(north: 2, at: 6)) == .stopped(since: Self.time(0)))
    }
}

// swiftlint:enable no_magic_numbers
