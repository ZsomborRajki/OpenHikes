//
//  WeatherWidgetPublisher.swift
//  OpenHikes
//
//  Hands the badge's reading to the home screen widget, and decides whether
//  that is worth a redraw.
//
//  The widget draws a temperature in its top-left corner and has no way to
//  fetch one: WeatherKit, the polling policy and the badge all live in this
//  target. So this is the weather half of what `TrailWidgetReload` is for the
//  trail feed — one place a widget-facing write happens, with the redraw sink
//  injectable so a suite can assert on a reload that `WidgetCenter` neither
//  reports nor replays.
//
//  **The write and the redraw are separate decisions**, as they are there.
//  Every new reading is written, because the file is what the next timeline
//  reads whenever WidgetKit happens to build one. Only a reading that changes
//  what is *drawn* asks for a redraw, and at whole degrees most refreshes do
//  not: an hour of a still afternoon is several successful fetches and one
//  string. Spending a reload on each of them would be the trail feed's
//  eighty-an-hour mistake in a second place.
//
//  It is deliberately **not** gated by `requestUnlessRecording()`. That gate
//  exists because a trail redraw during a recording produces a byte-identical
//  timeline — the recording has taken the whole widget. The temperature is
//  drawn in both states, so a reading that has changed changes the picture
//  either way, and holding it back would leave a hiker mid-walk reading this
//  morning's temperature.
//

import Foundation
import OpenHikesShared
import WidgetKit

/// Publishes the current reading to the App Group and redraws the widget when
/// the number on it would change.
nonisolated struct WeatherWidgetPublisher: Sendable {
    /// What a *granted* request does. Only tests supply one.
    typealias Reload = @Sendable () -> Void

    /// The App Group half, behind a seam of its own.
    ///
    /// `TrailWidgetReload` injects only its sink because it writes nothing;
    /// this one writes, and the write is the part that leaks. The app test
    /// bundle runs in one process against the *real* container, and several
    /// suites build a `WeatherManager` for reasons that have nothing to do
    /// with the widget — a badge state machine, a restore from `UserDefaults`,
    /// a store-open alert. Without this they would each publish a reading into
    /// the file another suite is asserting on, from an unstructured task, in
    /// parallel. That is the hazard the injectable containers elsewhere in
    /// this app exist for, in a new place.
    struct Store: Sendable {
        var load: @Sendable () -> SharedWeatherReading?
        var save: @Sendable (SharedWeatherReading) -> Void
        var clear: @Sendable () -> Void

        /// The one the app uses.
        static let appGroup = Self(
            load: { SharedStore.loadWeatherReading() },
            save: { SharedStore.saveWeatherReading($0) },
            clear: { SharedStore.clearWeatherReading() }
        )
    }

    /// The one the app uses, and the default every production call site takes.
    static let system = Self()

    /// Writes nowhere and redraws nothing — what a suite takes when it needs a
    /// `WeatherManager` for something that is not the widget.
    static let inert = Self(
        reload: { /* no widget to redraw */ },
        store: Store(
            load: { nil },
            save: { _ in /* nothing to write to */ },
            clear: { /* nothing to clear */ }
        )
    )

    private let reload: Reload
    private let store: Store

    init(
        reload: @escaping Reload = {
            WidgetCenter.shared.reloadTimelines(ofKind: TrailWidgetKind.id)
        },
        store: Store = .appGroup
    ) {
        self.reload = reload
        self.store = store
    }

    /// What the widget would put on screen for `reading`, or `nil` for a
    /// widget that would draw no temperature at all.
    ///
    /// Compares the rendered *string* rather than the stored Celsius, because
    /// the string is what changes the picture: two readings a tenth of a
    /// degree apart round to one number, and a hiker in a Fahrenheit region
    /// gets a different set of boundaries from one in a Celsius region for the
    /// same pair of readings.
    ///
    /// An expired reading draws nothing, which is why the age is asked here
    /// rather than left to the renderer alone: without it, a fresh reading
    /// that happens to agree with the expired one it replaces would be written
    /// and never drawn, and the widget would keep its blank corner until the
    /// six-hourly safety net came round.
    static func drawnTemperature(
        for reading: SharedWeatherReading?,
        asOf now: Date = .now,
        locale: Locale = .autoupdatingCurrent
    ) -> String? {
        guard let reading, !reading.isExpired(asOf: now) else { return nil }
        return reading.formatted(locale: locale)
    }

    /// Writes `reading` — or clears the stored one for a `nil` — and asks for
    /// a redraw only if the widget's corner would read differently.
    ///
    /// `@concurrent` rather than a detached task, for the reason
    /// `GPXExport.writeTemporaryFile(for:)` is one: the caller is
    /// `@MainActor` and the work here is App Group file operations, so this
    /// keeps them off the main thread while leaving the call an ordinary
    /// `await` — cancellation and ordering stay the caller's to decide. The
    /// one caller that has several of these to make in a row decides both by
    /// chaining them; see ``WeatherManager/publish(_:)``.
    ///
    /// The redraw is decided against what the store *has* after the write
    /// rather than against the value passed in. A write that did not land —
    /// an App Group that cannot be resolved, a container still locked under
    /// data protection — leaves the old reading in place, and asking the
    /// store means that case spends no reload at all instead of one on every
    /// badge move for a widget whose picture cannot change.
    ///
    /// - Returns: whether the redraw was asked for, which is what a refusal is
    ///   asserted through where a silent sink would be indistinguishable from
    ///   no call at all.
    @concurrent
    @discardableResult func publish(
        _ reading: SharedWeatherReading?,
        asOf now: Date = .now,
        locale: Locale = .autoupdatingCurrent
    ) async -> Bool {
        let previous = store.load()
        if let reading {
            store.save(reading)
        } else {
            store.clear()
        }
        let before = Self.drawnTemperature(for: previous, asOf: now, locale: locale)
        let after = Self.drawnTemperature(for: store.load(), asOf: now, locale: locale)
        guard before != after else { return false }
        reload()
        return true
    }
}

extension WeatherBadgeState {
    /// Whether a move to this state is worth telling the widget about at all.
    ///
    /// `false` for ``WeatherBadgeState/loading(_:)`` alone, which is the one
    /// state that is *on its way somewhere*: a fetch is in flight and it
    /// resolves, within a WeatherKit round trip, into a reading or into
    /// ``WeatherBadgeState/unavailable(_:)`` — and both of those publish. A
    /// widget told about the state in between would empty its corner and
    /// spend a reload doing it, then fill it and spend another, for the
    /// commonest thing a hiker does: tapping a trail the app has no cached
    /// forecast for. Holding the corner as it is costs nothing and is bounded
    /// by ``SharedWeatherReading/maximumAge`` in the case where the fetch
    /// never comes back at all.
    var publishesToWidget: Bool {
        if case .loading = self { return false }
        return true
    }

    /// The reading this state hands the widget, or `nil` for a state that has
    /// none to give.
    ///
    /// `unavailable` deliberately answers `nil` rather than leaving whatever
    /// was published last in place. On the badge it still draws something — an
    /// empty capsule — because the hiker can see it means "could not". A
    /// widget has no room to say that, so the only honest drawings are the
    /// temperature or nothing, and a number that has outlived the subject it
    /// was for is the wrong one: focusing a trail three hundred kilometres
    /// away and failing to get its forecast must not leave the last valley's
    /// temperature on the home screen. `loading` is never asked — see
    /// ``publishesToWidget``.
    var sharedReading: SharedWeatherReading? {
        guard let snapshot else { return nil }
        return SharedWeatherReading(
            temperatureCelsius: snapshot.temperature
                .converted(to: .celsius)
                .value,
            capturedAt: snapshot.capturedAt
        )
    }
}
