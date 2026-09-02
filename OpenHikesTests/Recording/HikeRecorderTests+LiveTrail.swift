//
//  HikeRecorderTests+LiveTrail.swift
//  OpenHikesTests
//
//  How a finished live match is allowed to change what the screen says about
//  the trail underfoot.
//
//  These drive ``HikeRecorder/applyCurrentTrail(_:isCurrent:)`` directly
//  rather than through a recording, and deliberately. The rule is about a
//  *race* — whether fixes arrived while the matcher was working — and
//  provoking that race through delivered fixes would assert a timing rather
//  than the decision the timing feeds. `slowLiveMatchDoesNotStarve` already
//  covers the plumbing that produces the race; this covers what is done with
//  it.
//

import Foundation
@testable import OpenHikes
import Testing

extension HikeRecorderTests {
    private static func trail(_ name: String) -> RecordingTrailContext {
        RecordingTrailContext(name: name, surface: .gravel, difficulty: .hiking)
    }

    @Test("a current match publishes what it found")
    func currentMatchPublishesItsTrail() {
        let recorder = makeRecorder()

        recorder.applyCurrentTrail(Self.trail("Ridge Path"), isCurrent: true)

        #expect(recorder.stats.currentTrail?.name == "Ridge Path")
        #expect(!recorder.stats.isCurrentTrailStale)
    }

    /// The flicker. A live match runs against a snapshot of the window and
    /// fixes keep arriving while it runs, so on any densely-sampled walk the
    /// "is this still current" answer is routinely no — and blanking the
    /// trail on it made the name switch off and on for the length of the
    /// hike. The verdict is kept and marked instead.
    @Test("a match overtaken by newer fixes keeps the trail and marks it")
    func overtakenMatchKeepsTheTrail() {
        let recorder = makeRecorder()
        recorder.applyCurrentTrail(Self.trail("Ridge Path"), isCurrent: true)

        recorder.applyCurrentTrail(nil, isCurrent: false)

        #expect(recorder.stats.currentTrail?.name == "Ridge Path")
        #expect(recorder.stats.isCurrentTrailStale)
    }

    /// Stepping off the path still has to be sayable, which is the reason the
    /// rule is about currency rather than about the verdict being non-nil: a
    /// match that *is* current may clear the trail.
    @Test("a current match that found nothing clears the trail")
    func currentMatchWithNoTrailClearsIt() {
        let recorder = makeRecorder()
        recorder.applyCurrentTrail(Self.trail("Ridge Path"), isCurrent: true)

        recorder.applyCurrentTrail(nil, isCurrent: true)

        #expect(recorder.stats.currentTrail == nil)
        #expect(!recorder.stats.isCurrentTrailStale)
    }

    /// A stale answer beats an older one, and beats none at all — which is
    /// what the first match of a walk that started with fixes already
    /// arriving would otherwise get.
    @Test("a stale match still adopts a trail it found")
    func staleMatchAdoptsWhatItFound() {
        let recorder = makeRecorder()

        recorder.applyCurrentTrail(Self.trail("Ridge Path"), isCurrent: false)

        #expect(recorder.stats.currentTrail?.name == "Ridge Path")
        #expect(recorder.stats.isCurrentTrailStale)
    }

    /// Staleness is a property of the trail on screen, so it cannot outlive
    /// it: a `nil` trail marked stale would dim a card that is not drawn, and
    /// then survive into the next match.
    @Test("an overtaken match with nothing to keep is not marked stale")
    func overtakenMatchWithNothingToKeepIsNotStale() {
        let recorder = makeRecorder()

        recorder.applyCurrentTrail(nil, isCurrent: false)

        #expect(recorder.stats.currentTrail == nil)
        #expect(!recorder.stats.isCurrentTrailStale)
    }

    /// The seam between the accumulator and the screen. Both figures are
    /// measured and tested one layer down; what this pins is that a running
    /// recording actually publishes them, since ``RecordingStats/update(from:)``
    /// is the only thing carrying either one out of the accumulator.
    @Test("a running recording publishes its moving time and live speed")
    func liveRecordingPublishesPaceAndMovingTime() async {
        let recorder = makeRecorder()
        await recorder.start()

        // Six minutes north at a walking pace, which is past both the
        // stationary window and the minimum span a live speed needs.
        for step in 0...36 {
            source.deliver(
                fix(latitude: 47.63 + Double(step) * 14 / 111_000)
            )
            clock.advance(by: 10)
        }

        #expect(recorder.stats.movingSeconds > 300)
        #expect(!recorder.stats.isStationary)
        let speed = recorder.stats.recentSpeedMetersPerSecond
        #expect(speed != nil)
        #expect(abs((speed ?? 0) - 1.4) < 0.1)
        await recorder.discard()
    }

    /// The live trail and the trail a finished walk is named after were one
    /// property holding two facts, which is why the screen said "Following:"
    /// for a walk that had already stopped. Clearing one must not touch the
    /// other — and the stop path does exactly this, in this order.
    @Test("clearing the live trail leaves the finished walk's name alone")
    func clearingTheLiveTrailKeepsTheDominantName() {
        let recorder = makeRecorder()
        recorder.applyCurrentTrail(Self.trail("Ridge Path"), isCurrent: true)
        recorder.stats.dominantTrailName = "Ridge Path"

        recorder.stats.clearCurrentTrail()

        #expect(recorder.stats.currentTrail == nil)
        #expect(recorder.stats.dominantTrailName == "Ridge Path")
    }
}
