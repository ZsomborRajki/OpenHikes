//
//  HikeRecorderTests+Delivery.swift
//  OpenHikesTests
//
//  What a `nonisolated` location callback is allowed to cost, and what it has
//  to guarantee. Both come from `onMainActor` in
//  `OpenHikes/General/MainActorDelivery.swift`.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

extension HikeRecorderTests {

    @Test("a delivered fix is accepted before the delegate call returns")
    func fixDeliveryIsSynchronous() async {
        let hikeRecorder = makeRecorder()
        await hikeRecorder.start()

        source.deliver(fix(latitude: 47.63))

        // Deliberately no `settleDelegateHop()`. Core Location delivers on the
        // main thread, so `onMainActor` runs the delegate body inline — and
        // that synchrony is not a micro-optimisation, it is the whole ordering
        // guarantee: a `Task { @MainActor in … }` per delivery would leave two
        // consecutive batches with no defined order between them, and a
        // reordered pair is dropped in silence by `RecordingFixPolicy`'s
        // `interval > 0` guard. Putting the hop back makes this fail.
        #expect(hikeRecorder.stats.pointCount == 1)
    }

    @Test("consecutive batches are accepted in the order they arrived")
    func consecutiveBatchesKeepTheirOrder() async {
        let hikeRecorder = makeRecorder()
        await hikeRecorder.start()
        let first = fix(latitude: 47.63)
        clock.advance(by: 10)
        let second = fix(latitude: 47.6302)
        clock.advance(by: 10)
        let third = fix(latitude: 47.6304)

        // Three separate deliveries rather than one batch of three: sorting
        // inside `didUpdateLocations` only orders a batch within itself.
        source.deliver([first])
        source.deliver([second])
        source.deliver([third])

        #expect(hikeRecorder.stats.pointCount == 3)
    }

    @Test("a sensor sample reaches the recorder before its callback returns")
    func sensorDeliveryIsSynchronous() async {
        let elevation = StubRecordingElevationSource()
        let motion = StubRecordingMotionSource()
        let hikeRecorder = makeRecorder(
            elevationSource: elevation,
            motionSource: motion
        )
        await hikeRecorder.start()

        source.deliver(fix(latitude: 47.63))
        elevation.deliver(12)
        motion.deliver(.nonPedestrian)
        clock.advance(by: 10)
        source.deliver(fix(latitude: 47.6302))

        // The barometer and the activity classifier really do deliver on a
        // background `OperationQueue` in the app, so `onMainActor` takes its
        // task branch there. What this pins is the other half of the contract:
        // a caller already on the main actor is answered on the spot.
        #expect(hikeRecorder.stats.pointCount == 2)
        #expect(hikeRecorder.latestMotionState == .nonPedestrian)
    }
}
