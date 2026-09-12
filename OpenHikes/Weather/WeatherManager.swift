//
//  WeatherManager.swift
//  OpenHikes
//
//  Fetches current conditions for a ``WeatherSubject`` via WeatherKit, and
//  holds what the badge draws.
//
//  Two things here are deliberate and were not true before.
//
//  The published value is a *state*, not an optional snapshot. It used to be
//  `WeatherSnapshot?`, set only on success, which made every way of having no
//  forecast look identical from the outside — and identical, on screen, to a
//  launch that had simply not asked yet. A missing WeatherKit entitlement, a
//  token fetch that failed, a rate limit and a hiker out of signal all
//  produced one log line and a badge that was never drawn at all, which is
//  indistinguishable from a feature that does not exist. ``WeatherBadgeState``
//  makes the difference visible: once there is a subject there is a badge,
//  spinning, reading, or plainly unavailable.
//
//  And readings are cached per subject. A hiker who looks at a trail, then
//  searches a city, then goes back to the trail should see the trail's
//  forecast again immediately rather than watch it be fetched twice — and
//  ``WeatherRequestState`` is already deciding that the second fetch is
//  unnecessary, so without a cache here the two would disagree and the badge
//  would sit empty on a subject the poll considered fresh.
//

import CoreLocation
import Foundation
import Observation
import OrderedCollections
import os
import WeatherKit

/// What the badge over the map actually draws: a symbol, a temperature and a
/// sentence.
///
/// A value type rather than WeatherKit's `CurrentWeather` for two reasons.
/// `CurrentWeather` has no public initializer, so nothing — a preview, a test,
/// a UI automation launch — could ever stand one up, which left the badge the
/// only piece of the interface reachable solely by a live network call against
/// an entitlement. And the badge reads three fields out of a type with
/// dozens, so the narrower value says what it depends on.
nonisolated struct WeatherSnapshot: Equatable, Sendable {
    let symbolName: String
    let temperature: Measurement<UnitTemperature>
    let conditionDescription: String
    /// When the reading itself was produced — not when this app asked for it.
    ///
    /// ``WeatherManager/update(for:)`` deliberately keeps the last successful
    /// reading when WeatherKit is unavailable, which is right (a temperature
    /// from twenty minutes ago beats an empty badge) and was previously
    /// indistinguishable from a current one, because nothing recorded how old
    /// it was. This is what ``isStale(asOf:policy:)`` answers from.
    ///
    /// Taken from WeatherKit's own `metadata.date` rather than from `Date.now`
    /// at the call site: WeatherKit serves cached payloads, so a response that
    /// arrives instantly is not necessarily a reading taken just now, and
    /// stamping the arrival would reset the age of data that never changed.
    let capturedAt: Date

    init(
        symbolName: String,
        temperature: Measurement<UnitTemperature>,
        conditionDescription: String,
        capturedAt: Date
    ) {
        self.symbolName = symbolName
        self.temperature = temperature
        self.conditionDescription = conditionDescription
        self.capturedAt = capturedAt
    }

    init(_ weather: CurrentWeather) {
        self.init(
            symbolName: weather.symbolName,
            temperature: weather.temperature,
            conditionDescription: weather.condition.description,
            capturedAt: weather.metadata.date
        )
    }
}

/// Everything the badge can be, once there is something to be about.
///
/// ``idle`` is the only state that draws nothing, and it means exactly one
/// thing: nobody has focused a subject yet. Every other state puts a badge on
/// screen, which is the point — see this file's header.
nonisolated enum WeatherBadgeState: Equatable, Sendable {
    case idle
    case loading(WeatherSubject)
    case reading(WeatherSnapshot, subject: WeatherSubject)
    /// A subject the app has, and a forecast it could not get for it.
    case unavailable(WeatherSubject)

    var subject: WeatherSubject? {
        switch self {
        case .idle: nil
        case .loading(let subject): subject
        case .reading(_, let subject): subject
        case .unavailable(let subject): subject
        }
    }

    var snapshot: WeatherSnapshot? {
        guard case .reading(let snapshot, _) = self else { return nil }
        return snapshot
    }
}

@Observable
final class WeatherManager {
    @ObservationIgnored private static let logger = Logger(
        subsystem: "OpenHikes",
        category: "Weather"
    )

    /// What the badge draws.
    private(set) var state: WeatherBadgeState = .idle

    /// The reading currently on screen, if there is one.
    ///
    /// Kept as a name of its own because the detail sheet asks this question
    /// and only this question — it has no use for the subject or for why there
    /// is nothing.
    var current: WeatherSnapshot? { state.snapshot }

    /// Readings by ``WeatherSubject/key``, least- to most-recently used.
    ///
    /// Uses the same limit and focus recency as ``WeatherRequestState``, so
    /// revisiting a fresh subject keeps both its reading and request history.
    @ObservationIgnored private var cache: OrderedDictionary<String, WeatherSnapshot> = [:]

    @ObservationIgnored private let service = WeatherService.shared
    @ObservationIgnored private let store: WeatherReadingStore?

    init(store: WeatherReadingStore? = nil) {
        self.store = store
        // A cold launch used to show nothing until a fix arrived and a network
        // round trip came back — half a minute of a feature that looks absent.
        // The restored reading is almost always old enough to be drawn dimmed,
        // which is exactly what it is: last night's weather, labelled as such
        // by the same staleness rule a live reading is held to.
        if let restored = store?.load() {
            cache[restored.subject.key] = restored.snapshot
            state = .reading(restored.snapshot, subject: restored.subject)
        }
    }

    /// Points the badge at `subject`, before anything is fetched for it.
    ///
    /// `willRequest` is the poll loop's own decision, passed in rather than
    /// re-derived: it is the difference between a subject whose forecast is on
    /// its way and one the backoff has ruled out, and the badge should not
    /// spin for the second.
    func focus(on subject: WeatherSubject?, willRequest: Bool) {
        guard let subject else {
            state = .idle
            return
        }
        if let cached = cache[subject.key] {
            remember(cached, for: subject)
            state = .reading(cached, subject: subject)
        } else if willRequest {
            state = .loading(subject)
        } else {
            state = .unavailable(subject)
        }
    }

    /// Fetches current weather for `subject`, keeping the last reading for it
    /// when WeatherKit is temporarily unavailable.
    ///
    /// Returns whether the request succeeded, which is what the poll loop
    /// records against the subject's backoff.
    func update(for subject: WeatherSubject) async -> Bool {
        let coordinate = subject.coordinate
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        // Instrumented because WeatherKit is a network call this app makes on
        // a hiker's behalf without being asked, and the freshness window that
        // keeps it rare is a constant nobody would notice regressing. The
        // count per hike is the check.
        let interval = RenderSignpost.beginInterval("WeatherFetch")
        defer { RenderSignpost.endInterval("WeatherFetch", interval) }
        do {
            let snapshot = WeatherSnapshot(
                try await service.weather(for: location, including: .current)
            )
            remember(snapshot, for: subject)
            state = .reading(snapshot, subject: subject)
            store?.save(snapshot: snapshot, subject: subject)
            return true
        } catch {
            // WeatherKit's failure modes are the opaque ones — a missing
            // entitlement, a token fetch that failed, a rate limit, an
            // unsupported region — and they are indistinguishable from a
            // hiker simply being out of signal, which is the one the backoff
            // is designed for. The log is still the only place the difference
            // can be read, but the *fact* of it now reaches the screen.
            Self.logger.error(
                """
                Weather update failed for \(subject.key, privacy: .private): \
                \(error.localizedDescription, privacy: .public)
                """
            )
            if let cached = cache[subject.key] {
                state = .reading(cached, subject: subject)
            } else {
                state = .unavailable(subject)
            }
            return false
        }
    }

    private func remember(_ snapshot: WeatherSnapshot, for subject: WeatherSubject) {
        // The reading is stored where the subject already sits and the entry
        // is *then* moved to the end of the recency order, which is what makes
        // `removeFirst` drop the least recently read subject. A subject not
        // cached before is appended by the subscript, so the move finds it
        // already last and does nothing.
        cache[subject.key] = snapshot
        cache.move(keys: CollectionOfOne(subject.key), to: cache.count)
        if cache.count > WeatherRequestState.trackedSubjectLimit {
            cache.removeFirst()
        }
    }

    /// Publishes a fixed reading instead of asking WeatherKit.
    ///
    /// Only reachable from a `--ui-test-weather` launch: the badge is the one
    /// control on the first screen whose presence depends on an entitlement, a
    /// token and a network round trip, so without this it was either absent
    /// from every automated run or a source of flakes in all of them.
    #if DEBUG
    func applyUITestSnapshot(
        _ snapshot: WeatherSnapshot = .uiTestFixture,
        subject: WeatherSubject = .uiTestFixtureSubject
    ) {
        remember(snapshot, for: subject)
        state = .reading(snapshot, subject: subject)
    }
    #endif
}

#if DEBUG
extension WeatherSnapshot {
    /// The reading `--ui-test-weather` publishes.
    ///
    /// Deliberately unmistakable: a temperature no simulator's real location
    /// is likely to report, so a test that finds this value knows the badge is
    /// drawing the fixture rather than something that arrived by accident.
    ///
    /// Computed rather than stored, so every launch gets a reading captured at
    /// that launch. A `static let` is initialized once and would hand a long
    /// simulator session a fixture that ages past the staleness window, which
    /// would dim the badge in a test that never asked about staleness.
    static var uiTestFixture: Self {
        Self(
            symbolName: "cloud.sun.fill",
            temperature: Measurement(value: 12, unit: UnitTemperature.celsius),
            conditionDescription: "Partly Cloudy",
            capturedAt: .now
        )
    }
}

extension WeatherSubject {
    private static let uiTestFixtureLatitude = 47.4979
    private static let uiTestFixtureLongitude = 19.0402

    /// The subject `--ui-test-weather` publishes against. `me`, so the badge
    /// draws its "here" form and no assertion has to know a place name.
    static let uiTestFixtureSubject = Self.me(
        CLLocationCoordinate2D(
            latitude: uiTestFixtureLatitude,
            longitude: uiTestFixtureLongitude
        )
    )
}
#endif
