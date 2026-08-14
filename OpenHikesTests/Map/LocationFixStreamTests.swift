//
//  LocationFixStreamTests.swift
//  OpenHikesTests
//
//  Two consumers used to poll `LocationManager.coordinate` on their own 1 Hz
//  `Task.sleep` loops — the weather poll in `OpenHikesModel` and auto-follow
//  in `HikeDetailView` — so both kept waking a phone in a pocket to decide
//  nothing had changed. `LocationManager.fixes` replaced both timers, and the
//  substitution is only sound if the sequence delivers exactly what the loops
//  used to read for themselves:
//
//  * the fix that is *already* current when iteration starts, because
//    `followLocation` matched immediately and then slept, not the other way
//    round;
//  * one element per accepted publish; and
//  * nothing at all while the walker stands still, which is the entire point
//    of the change and the one property a timer can't have.
//
//  Both consumers iterate it at once, so the fan-out is pinned here too.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Location fix stream")
struct LocationFixStreamTests {
    /// Collects what one consumer of ``LocationManager/fixes`` actually
    /// received, in order.
    @MainActor
    private final class FixLog {
        private(set) var received: [CLLocationCoordinate2D?] = []
        var count: Int { received.count }
        var latitudes: [Double?] { received.map { $0?.latitude } }

        func append(_ coordinate: CLLocationCoordinate2D?) {
            received.append(coordinate)
        }
    }

    private let clock = TestClock()
    private let manager: LocationManager

    init() {
        manager = LocationManager(clock: clock.read)
    }

    private func publish(latitude: Double, longitude: Double = 12.86) async {
        manager.locationManager(
            CLLocationManager(),
            didUpdateLocations: [
                CLLocation(latitude: latitude, longitude: longitude)
            ]
        )
        await settle()
    }

    /// The delegate callback hops to the main actor, Observation then wakes
    /// the consumer task, and the consumer appends — three scheduling steps,
    /// none of which involves a real clock.
    private func settle() async {
        await settleDelegateHop()
    }

    /// Starts a consumer and returns its log plus the task holding it, so the
    /// caller can cancel it and keep the sequence from outliving the test.
    @MainActor
    private func startConsumer() async -> (log: FixLog, task: Task<Void, Never>) {
        let log = FixLog()
        let task = Task { @MainActor in
            for await coordinate in manager.fixes {
                log.append(coordinate)
            }
        }
        await settle()
        return (log, task)
    }

    /// `followLocation` used to call `updateLiveFollow` before its first
    /// sleep, so a hike opened while standing on the trail showed the live
    /// marker straight away. Waiting for the *next* fix instead would leave
    /// the chart blank for as long as the walker stayed put.
    @Test("iterating starts from the fix that is already current")
    func currentFixArrivesFirst() async {
        await publish(latitude: 47.63)
        #expect(manager.coordinate?.latitude == 47.63, "precondition: the fix was published")

        let consumer = await startConsumer()
        defer { consumer.task.cancel() }

        #expect(consumer.log.latitudes == [47.63])
    }

    /// Before any fix has arrived there is nothing to match against, and the
    /// sequence says so rather than withholding an element — `pollWeather`
    /// relies on being woken to re-read a position it may not have yet.
    @Test("a consumer that starts before the first fix is woken by it")
    func firstFixWakesAWaitingConsumer() async {
        let consumer = await startConsumer()
        defer { consumer.task.cancel() }
        #expect(consumer.log.latitudes == [nil], "no fix yet, and the sequence says so")

        await publish(latitude: 47.63)

        #expect(consumer.log.latitudes == [nil, 47.63])
    }

    /// The property the timers couldn't have. A walker at a viewpoint keeps
    /// producing fixes, and `LocationManager.publish` drops the ones that
    /// repeat the last coordinate — so nothing downstream wakes at all.
    @Test("standing still wakes nobody")
    func repeatedFixesDoNotWake() async {
        await publish(latitude: 47.63)
        let consumer = await startConsumer()
        defer { consumer.task.cancel() }
        #expect(consumer.log.count == 1)

        clock.advance(by: 5)
        await publish(latitude: 47.63)
        clock.advance(by: 5)
        await publish(latitude: 47.63)

        #expect(consumer.log.count == 1, "three fixes at one spot, one element")
    }

    /// …and a step really does wake it, so the previous test is measuring the
    /// duplicate filter rather than a sequence that never delivers.
    @Test("moving on wakes the consumer again")
    func movementWakesConsumer() async {
        await publish(latitude: 47.63)
        let consumer = await startConsumer()
        defer { consumer.task.cancel() }

        clock.advance(by: 1.1)
        await publish(latitude: 47.64)

        #expect(consumer.log.latitudes == [47.63, 47.64])
    }

    /// The weather poll and auto-follow iterate this at the same time whenever
    /// a hike is open, so a fix has to reach both — an `AsyncStream` handed
    /// out from a single stored continuation would have given it to whichever
    /// one asked first.
    @Test("every consumer sees every fix")
    func fanOutReachesEveryConsumer() async {
        await publish(latitude: 47.63)
        let weather = await startConsumer()
        let follow = await startConsumer()
        defer {
            weather.task.cancel()
            follow.task.cancel()
        }

        clock.advance(by: 1.1)
        await publish(latitude: 47.64)

        #expect(weather.log.latitudes == [47.63, 47.64])
        #expect(follow.log.latitudes == [47.63, 47.64])
    }

    /// A fix the policy rejects — here, one dated well in the past — never
    /// reaches `coordinate`, so it must not reach the sequence either.
    @Test("a rejected fix is not published to consumers")
    func rejectedFixesAreNotDelivered() async {
        let consumer = await startConsumer()
        defer { consumer.task.cancel() }

        manager.locationManager(
            CLLocationManager(),
            didUpdateLocations: [
                CLLocation(
                    coordinate: CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86),
                    altitude: 0,
                    horizontalAccuracy: 5,
                    verticalAccuracy: 5,
                    timestamp: Date(timeIntervalSinceNow: -600)
                ),
            ]
        )
        await settle()

        #expect(consumer.log.latitudes == [nil], "too old to publish, so nothing to wake on")
    }
}
