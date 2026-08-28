//
//  OpenHikesModel+Weather.swift
//  OpenHikes
//
//  Keeping ``WeatherManager`` current for wherever the walker is.
//
//  Its own file rather than a method on the model because it is a loop with a
//  policy, not a piece of coordination: what it costs is decided by
//  ``WeatherPollState`` and ``WeatherPollingPolicy``, both of which are pure
//  and asserted directly, and this is only what drives them.
//

import AsyncAlgorithms
import CoreLocation
import Foundation

extension OpenHikesModel {
    /// Keeps ``WeatherManager`` current for wherever the walker is, waking on
    /// two things and nothing else: a new position, and the moment
    /// ``WeatherPollState`` would next allow a request for the position it
    /// already holds.
    ///
    /// The second wake-up is one sleep to an exact deadline, re-armed after
    /// each pass — not a tick. Standing still with a fresh reading, this loop
    /// wakes twice in a quarter of an hour; the 1 Hz timer it replaces woke
    /// nine hundred times over the same stretch to conclude it had nothing to
    /// do, and `WeatherPollState` threw all but one of those away. Keeping the
    /// deadline is what stops the other extreme: purely fix-driven polling
    /// would leave an expired reading, or a failure's backoff, waiting on the
    /// walker to move again.
    func pollWeather(policy: WeatherPollingPolicy = .standard) async {
        var state = WeatherPollState()
        let (dueDates, dueDatesContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        var dueTask: Task<Void, Never>?
        defer {
            dueTask?.cancel()
            dueDatesContinuation.finish()
        }

        for await _ in merge(locationManager.fixes.map { _ in () }, dueDates) {
            guard let coordinate = locationManager.coordinate else { continue }
            let key = Self.weatherKey(for: coordinate)
            if state.shouldRequest(key: key, at: .now, policy: policy) {
                if await weatherManager.update(for: coordinate) {
                    state.recordSuccess(key: key, at: .now)
                } else {
                    state.recordFailure(key: key, at: .now, policy: policy)
                }
            }
            dueTask?.cancel()
            guard let due = state.nextEligibleDate(key: key, policy: policy) else { continue }
            dueTask = Task {
                try? await Task.sleep(until: .now + .seconds(max(0, due.timeIntervalSinceNow)))
                guard !Task.isCancelled else { return }
                dueDatesContinuation.yield(())
            }
        }
    }

    private static func weatherKey(
        for coordinate: CLLocationCoordinate2D
    ) -> String {
        "\(Int(coordinate.latitude * 100)),\(Int(coordinate.longitude * 100))"
    }
}
