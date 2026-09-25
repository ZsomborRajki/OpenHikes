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
import OpenHikesData
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
    /// Everything else the same response carried. See ``WeatherConditions``
    /// for why it is one value rather than nine properties here.
    ///
    /// Not optional. A reading either came out of a `CurrentWeather` — which
    /// carries every one of these — or was restored from the one stored blob,
    /// and a blob written before these fields existed simply fails to decode
    /// and is re-fetched within seconds of launch. That is the reset policy
    /// rather than an oversight: see ``WeatherReadingStore``.
    let conditions: WeatherConditions
    /// The next few hours, from the same response — see
    /// ``WeatherHourSummary``.
    ///
    /// Empty rather than optional, and defaulted, because empty is a thing
    /// that genuinely happens: a reading restored from a blob written before
    /// this field existed, and a provider that answered `.current` but had no
    /// hourly data for the point. Both mean the same thing to the sheet, which
    /// is to draw no strip. Unlike ``conditions``, an absent strip does not
    /// make the reading wrong, so it does not fail the decode.
    let hourly: [WeatherHourSummary]
    /// The week ahead, from the same response — see ``WeatherDaySummary``.
    ///
    /// **Empty rather than optional, which is ``hourly``'s treatment and
    /// deliberately not ``daylight``'s.** The worry that argues for an
    /// optional is real: `.daily` was in the request before anything read more
    /// than its first day, so a blob written by one of those builds carries no
    /// week, and that is not the same fact as a provider with no daily
    /// forecast for the point. It is answered by the reset policy rather than
    /// by a third state — the stored field is non-optional, so such a blob
    /// fails to decode once and is replaced seconds after launch rather than
    /// being read as an answer about the weather. See ``WeatherReadingStore``,
    /// whose header calls that the whole cost of adding a field.
    ///
    /// An optional would buy nothing here anyway. ``daylight`` is optional
    /// because *absent* and *present with no sunset* are different things a
    /// reader can see; `nil` and `[]` are not, because the only code that
    /// reads this asks one question of it, which is whether there are rows to
    /// draw.
    let days: [WeatherDaySummary]
    /// The day's light and its temperature range — see ``WeatherDaylight``.
    ///
    /// **Optional, where ``conditions`` is not and ``hourly`` is empty-but-
    /// present.** The three are deliberately different and the difference is
    /// the reset policy. A blob written before `conditions` existed *should*
    /// fail to decode and be refetched, because a reading without them is
    /// wrong. An empty strip is a real answer. And an absent daylight is a
    /// real answer twice over: a provider with no daily data for the point,
    /// and a reading restored from a build that did not ask for `.daily` — so
    /// this one is `nil`-able rather than decode-failing, and an old blob
    /// keeps working until the next fetch fills it in.
    let daylight: WeatherDaylight?
    /// What `.alerts` said about this place — see ``WeatherAlerts``.
    ///
    /// Optional for the reason ``daylight`` is, plus one that is specific to
    /// it and sharper: the type's own ``WeatherAlerts/unavailable`` already
    /// means *nobody is watching here*, and a blob written by a build that
    /// never asked for `.alerts` must not decode as that. "This build did not
    /// ask" and "this region has no alerting partner" are different facts and
    /// only one of them is about the weather, so the absent case is the
    /// optional's `nil` and `unavailable` is kept for the answer WeatherKit
    /// actually gave.
    let alerts: WeatherAlerts?

    init(
        symbolName: String,
        temperature: Measurement<UnitTemperature>,
        conditionDescription: String,
        capturedAt: Date,
        conditions: WeatherConditions,
        hourly: [WeatherHourSummary] = [],
        days: [WeatherDaySummary] = [],
        daylight: WeatherDaylight? = nil,
        alerts: WeatherAlerts? = nil
    ) {
        self.symbolName = symbolName
        self.temperature = temperature
        self.conditionDescription = conditionDescription
        self.capturedAt = capturedAt
        self.conditions = conditions
        self.hourly = hourly
        self.days = days
        self.daylight = daylight
        self.alerts = alerts
    }

    init(
        _ weather: CurrentWeather,
        hourly: [WeatherHourSummary] = [],
        days: [WeatherDaySummary] = [],
        daylight: WeatherDaylight? = nil,
        alerts: WeatherAlerts? = nil
    ) {
        self.init(
            symbolName: weather.symbolName,
            temperature: weather.temperature,
            conditionDescription: weather.condition.description,
            capturedAt: weather.metadata.date,
            conditions: WeatherConditions(weather),
            hourly: hourly,
            days: days,
            daylight: daylight,
            alerts: alerts
        )
    }
}

extension WeatherHourSummary {
    /// The one place WeatherKit's hourly shape is read.
    ///
    /// `nonisolated` for the reason ``WeatherConditions``' own mapping is: the
    /// caller is a nonisolated initializer on a value that has to be able to
    /// cross actors.
    ///
    /// Trimmed to ``WeatherHourlyPolicy/horizon`` here rather than at the
    /// screen, because everything downstream of this stores what it is given:
    /// `.hourly` answers with days of data and all of it would otherwise be
    /// written to `UserDefaults` on every successful fetch.
    nonisolated static func summaries(
        from forecast: Forecast<HourWeather>,
        notBefore start: Date
    ) -> [Self] {
        forecast
            // WeatherKit's hourly forecast begins at the top of the current
            // hour, so the hour in progress is included and the ones already
            // gone are not. Anchored to the reading's own timestamp rather
            // than to `Date.now` for the reason ``WeatherSnapshot/capturedAt``
            // gives: a cached payload is not necessarily a reading taken now.
            .filter { $0.date.addingTimeInterval(WeatherHourlyPolicy.hourSeconds) > start }
            .prefix(WeatherHourlyPolicy.horizon)
            .map { hour in
                Self(
                    date: hour.date,
                    symbolName: hour.symbolName,
                    temperature: hour.temperature,
                    precipitationChance: hour.precipitationChance
                )
            }
    }
}

extension WeatherDaySummary {
    /// The one place WeatherKit's daily shape is read as a forecast.
    ///
    /// The other reader of `.daily` is ``WeatherDaylight``, which takes one
    /// day's sun out of the same ten. They are deliberately separate: that one
    /// answers *when does the light go today*, which is a fact about the
    /// reading, and this one answers *which day should I walk*, which is a
    /// fact about the week. Folding them together would make the daylight
    /// section depend on how many days the strip happens to keep.
    ///
    /// `nonisolated` for the reason ``WeatherHourSummary``'s own mapping is:
    /// the caller is a nonisolated initializer on a value that has to cross
    /// actors.
    ///
    /// **Trimmed to ``WeatherDailyPolicy/horizon`` here rather than at the
    /// screen**, because everything downstream stores what it is given, and
    /// `.daily` answers with ten days that would otherwise be written to
    /// `UserDefaults` on every successful fetch.
    ///
    /// **The day in progress is kept, and the days already gone are not** —
    /// ``WeatherDaySummary/upcoming(in:asOf:calendar:)`` is the rule, and the
    /// sheet applies it a second time on the way to the screen because
    /// nothing here expires: what this trims is the response, and a reading
    /// is drawn for as long as no later one replaces it.
    ///
    /// Anchored to `start`, the reading's own timestamp, rather than to
    /// `Date.now`, for the reason ``WeatherSnapshot/capturedAt`` gives:
    /// WeatherKit serves cached payloads, and a response that arrives at
    /// 00:05 may be a reading taken yesterday.
    ///
    /// Mapped before it is trimmed rather than after, which costs three
    /// values nobody draws and buys the one predicate: the *same* rule has to
    /// hold here and at the sheet, and two spellings of it would agree until
    /// somebody changed one.
    nonisolated static func summaries(
        from forecast: Forecast<DayWeather>,
        notBefore start: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [Self] {
        let week = forecast.map { day in
            Self(
                date: day.date,
                symbolName: day.symbolName,
                highTemperature: day.highTemperature,
                lowTemperature: day.lowTemperature,
                precipitationChance: day.precipitationChance
            )
        }
        return Array(
            upcoming(in: week, asOf: start, calendar: calendar)
                .prefix(WeatherDailyPolicy.horizon)
        )
    }
}

extension WeatherConditions {
    /// The one place WeatherKit's own shape is read.
    ///
    /// `nonisolated` because the caller is: `SWIFT_DEFAULT_ACTOR_ISOLATION` is
    /// `MainActor` here, so an extension written without it is main-actor
    /// isolated and unreachable from ``WeatherSnapshot``'s own nonisolated
    /// initializer — which is the whole point of that type being a value that
    /// can cross actors.
    ///
    /// Here rather than beside the type for the reason ``WeatherSnapshot``
    /// gives: these values exist so that a preview, a suite or a UI automation
    /// launch can build a reading without the framework, and an import in that
    /// file would take the whole point away.
    nonisolated init(_ weather: CurrentWeather) {
        self.init(
            apparentTemperature: weather.apparentTemperature,
            dewPoint: weather.dewPoint,
            humidity: weather.humidity,
            cloudCover: weather.cloudCover,
            pressure: weather.pressure,
            uvIndex: WeatherUVIndex(
                value: weather.uvIndex.value,
                category: WeatherUVCategory(weather.uvIndex.category)
            ),
            visibility: weather.visibility,
            // Converted through the dimension rather than read off `.value`,
            // which would be trusting the provider to have handed over the
            // unit its documentation names. A depth per hour expressed as a
            // speed is a millionth of a kilometre per hour, so this is exact
            // whatever unit the measurement arrives in.
            precipitationIntensity: Measurement(
                value: weather.precipitationIntensity
                    .converted(to: .kilometersPerHour).value * Self.millimetresPerKilometre,
                unit: .millimeters
            ),
            wind: WeatherWind(
                speed: weather.wind.speed,
                direction: weather.wind.direction,
                gust: weather.wind.gust
            )
        )
    }

    nonisolated private static let millimetresPerKilometre: Double = 1_000_000
}

extension WeatherUVCategory {
    /// WeatherKit's bands, one for one.
    ///
    /// Spelled out rather than bridged through a raw value, so the two
    /// spellings are matched here on purpose rather than by whatever
    /// `init(rawValue:)` happened to find.
    ///
    /// A band this build has never heard of reads as ``extreme``, which is the
    /// conservative direction for a sun-exposure reading: the failure of
    /// over-reporting is a hiker who puts a hat on, and the failure of
    /// under-reporting is the other one.
    nonisolated init(_ category: UVIndex.ExposureCategory) {
        switch category {
        case .low: self = .low
        case .moderate: self = .moderate
        case .high: self = .high
        case .veryHigh: self = .veryHigh
        case .extreme: self = .extreme
        @unknown default: self = .extreme
        }
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
    ///
    /// Assigned only by ``publish(_:)``, which is what keeps the widget's
    /// temperature on whatever this is showing. Six places move the badge and
    /// a seventh will be added one day; routing them through one call is the
    /// difference between that being free and it being a corner of the home
    /// screen that quietly stops agreeing with the app.
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
    /// The transport a severe-weather banner goes out through, or `nil` for a
    /// launch that must not post one — which is every test launch, exactly as
    /// ``OpenHikesModel/makeMovementReminderController(defaults:)`` decides
    /// for the movement reminders.
    @ObservationIgnored private let notifier: (any MovementReminderNotifying)?
    /// One watch per subject, bounded the same way ``cache`` is and for the
    /// same reason. See ``announceAlerts(in:for:)`` for why it is per subject
    /// rather than one for the app.
    @ObservationIgnored private var alertWatches: OrderedDictionary<String, WeatherAlertWatch> = [:]
    @ObservationIgnored private let store: WeatherReadingStore?
    /// Where the badge's reading reaches the home screen widget. A suite hands
    /// this a counter, for the reason ``TrailWidgetReload`` takes one.
    @ObservationIgnored private let widgetPublisher: WeatherWidgetPublisher
    /// The tail of the publish chain — see ``publish(_:)``. Never cancelled:
    /// a publish that has started is a file the widget is about to read, and
    /// abandoning it half-written is the one outcome worse than a late one.
    @ObservationIgnored private var pendingWidgetPublish: Task<Void, Never>?
    /// `nil` for a launch that must not reach the network — see
    /// ``WeatherPlaceNaming``. The sheet is then headed exactly as it was
    /// before that file existed.
    @ObservationIgnored private let placeNames: (any WeatherPlaceNaming)?

    /// The city a subject's forecast turned out to be for, keyed by
    /// ``WeatherSubject/key``.
    ///
    /// The same key and the same limit as ``cache``, so a hiker going back to
    /// a trail gets its title back for free alongside its reading. A city is a
    /// property of the anchor rather than of the weather, so unlike a snapshot
    /// it never goes stale: nothing here expires.
    @ObservationIgnored private var cities: OrderedDictionary<String, String> = [:]

    /// The city name the detail sheet heads itself with, and which subject it
    /// belongs to.
    ///
    /// Observed, because the title is drawn before the geocode lands and has
    /// to be redrawn when it does. Carries the key rather than only the name
    /// so that an answer arriving after the hiker has moved on is discarded by
    /// ``cityName`` rather than published over a different trail — the same
    /// rule ``CommunityBrowser``'s `areaName` follows, and for the same
    /// reason.
    private var resolvedCity: (key: String, name: String)?

    /// What to call the place the current reading is for, or `nil` to fall
    /// back to whatever the subject calls itself.
    ///
    /// Computed against the live subject, so it answers `nil` the instant the
    /// badge moves on rather than leaving a stale city over a new trail.
    var cityName: String? {
        guard let resolvedCity, resolvedCity.key == state.subject?.key else { return nil }
        return resolvedCity.name
    }

    /// Whether ``restoreLastReading()`` has already run.
    ///
    /// The restore is eager and happens exactly once. Guarding on `state`
    /// alone would not be enough: a launch whose first focus lands before the
    /// restore leaves the badge non-idle, and without this flag the restore
    /// would still be sitting there waiting to fire on the next call.
    @ObservationIgnored private var hasRestored = false

    /// Builds the manager. **Reads nothing**, which is the point.
    ///
    /// This runs during app composition, before the first frame, and the
    /// restore it used to do here cost 18-27 ms of the main thread — a decode
    /// for a badge that has nothing to draw against until a location fix
    /// arrives. See ``restoreLastReading()`` for where it went and why the
    /// time is *relocated* rather than saved.
    init(
        store: WeatherReadingStore? = nil,
        placeNames: (any WeatherPlaceNaming)? = nil,
        notifier: (any MovementReminderNotifying)? = nil,
        widgetPublisher: WeatherWidgetPublisher = .system
    ) {
        self.store = store
        self.placeNames = placeNames
        self.notifier = notifier
        self.widgetPublisher = widgetPublisher
    }

    /// Looks up the city the current subject's forecast is for, if it is the
    /// kind of subject that borrows one.
    ///
    /// **Called when the detail sheet opens, not when the subject changes.**
    /// Only the sheet draws the name, and a hiker who selects six trails
    /// looking for the right one should not spend six geocodes on titles
    /// nobody asked to see — the same bargain
    /// ``CommunityNearbyScope/publishedOnly`` strikes for Overpass.
    ///
    /// Idempotent and cheap on the second call: a cached city is published
    /// without a round trip, so reopening the sheet costs nothing.
    func resolveCityName() async {
        // A trail only. ``WeatherSubject/place`` is already a place the hiker
        // named by searching for it, and replacing what they typed with its
        // administrative parent would be answering a question nobody asked;
        // ``WeatherSubject/me`` is *here*, which the sheet says by saying
        // "Weather".
        guard let subject = state.subject, case .trail = subject else { return }
        let key = subject.key
        if let known = cities[key] {
            resolvedCity = (key, known)
            return
        }
        guard let placeNames, let city = await placeNames.cityName(at: subject.coordinate) else {
            return
        }
        cities[key] = city
        cities.move(keys: CollectionOfOne(key), to: cities.count)
        if cities.count > WeatherRequestState.trackedSubjectLimit {
            cities.removeFirst()
        }
        resolvedCity = (key, city)
    }

    /// Puts the stored reading back on the badge, once, after the first frame.
    ///
    /// The restore itself is not decoration. Without it a cold launch shows
    /// nothing until a fix arrives *and* a network round trip comes back —
    /// half a minute in which the weather feature looks absent. The restored
    /// reading is almost always old enough to be drawn dimmed, which is
    /// exactly what it is: last night's weather, labelled as such by the same
    /// staleness rule a live reading is held to.
    ///
    /// What moved is *when*. It used to run inside `init`, on the composition
    /// path, where it was the only part of launch that was both this app's and
    /// deferrable — opening the SwiftData container is larger and the app
    /// cannot start without it. The payload is one small JSON object out of
    /// `UserDefaults`, so most of that time is first-touch of Foundation's
    /// decoding machinery in the process rather than the bytes: **this pushes
    /// the cost past the first frame rather than deleting it**, which is the
    /// right trade for time-to-first-frame and is not a saving to claim.
    ///
    /// Eager rather than lazy inside ``focus(on:willRequest:)``. Lazy-on-focus
    /// reads tidier and is wrong: `focus` is driven by the poll loop, which
    /// needs a subject, which needs a location fix — so it would reintroduce
    /// the exact gap the restore exists to close.
    ///
    /// The cache is seeded whatever the badge is showing, so a subject the
    /// hiker returns to is answered from the restore rather than fetched
    /// again. The *state* is only taken when nothing has claimed the badge
    /// yet: a launch that has already focused somewhere — or published the
    /// UI-test fixture — must not have last night's reading put over it.
    func restoreLastReading() {
        guard !hasRestored else { return }
        hasRestored = true
        guard let restored = store?.load() else { return }
        cache[restored.subject.key] = restored.snapshot
        guard state == .idle else { return }
        publish(.reading(restored.snapshot, subject: restored.subject))
    }

    /// Points the badge at `subject`, before anything is fetched for it.
    ///
    /// `willRequest` is the poll loop's own decision, passed in rather than
    /// re-derived: it is the difference between a subject whose forecast is on
    /// its way and one the backoff has ruled out, and the badge should not
    /// spin for the second.
    func focus(on subject: WeatherSubject?, willRequest: Bool) {
        guard let subject else {
            publish(.idle)
            return
        }
        if let cached = cache[subject.key] {
            remember(cached, for: subject)
            publish(.reading(cached, subject: subject))
        } else if willRequest {
            publish(.loading(subject))
        } else {
            publish(.unavailable(subject))
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
        do {
            // One round trip, four datasets. `weather(for:including:)` is
            // variadic and answers all of them from the same request, so the
            // strip, the week, the daylight row and the alerts cost what the
            // badge was already spending — see ``WeatherHourSummary``,
            // ``WeatherDaySummary``, ``WeatherDaylight`` and
            // ``WeatherAlerts``.
            let (reading, forecast, daily, alerts) = try await service.weather(
                for: location,
                including: .current,
                .hourly,
                .daily,
                .alerts
            )
            let snapshot = WeatherSnapshot(
                reading,
                hourly: WeatherHourSummary.summaries(
                    from: forecast,
                    notBefore: reading.metadata.date
                ),
                // The next two are the same ten days read twice: the week a
                // walk is chosen from, and the one day's sun that ends the
                // walk already chosen. Both are anchored against the reading's
                // own date rather than `Date.now`, for the reason
                // ``WeatherSnapshot/capturedAt`` gives: WeatherKit serves
                // cached payloads, and a response that arrives at 00:05 may be
                // a reading taken yesterday.
                days: WeatherDaySummary.summaries(
                    from: daily,
                    notBefore: reading.metadata.date
                ),
                daylight: WeatherDaylight.forDay(
                    of: reading.metadata.date,
                    in: daily
                ),
                // The `nil` is carried rather than defaulted away: it is the
                // difference between nobody watching this place and nothing to
                // report, and it is the one this app must not get wrong.
                alerts: WeatherAlerts(alerts)
            )
            remember(snapshot, for: subject)
            publish(.reading(snapshot, subject: subject))
            store?.save(snapshot: snapshot, subject: subject)
            await announceAlerts(in: snapshot, for: subject)
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
                publish(.reading(cached, subject: subject))
            } else {
                publish(.unavailable(subject))
            }
            return false
        }
    }

    /// Interrupts the hiker for anything severe that has not been said yet.
    ///
    /// Everything about *whether* is in ``WeatherAlertWatch``, which is a
    /// value type with no clock and no framework in it; this is the call that
    /// follows, exactly the split ``MovementReminderController`` keeps with
    /// its notifier.
    ///
    /// **One banner, even when several alerts are new.** The kind's identifier
    /// is its own, so a second post would replace the first rather than stack
    /// under it — and the worst one is what `observed(_:)` returns first.
    /// Three warnings over one ridge is a sheet to open, not three banners.
    ///
    /// A watch per subject, because an alert already announced over one ridge
    /// is news again over another: it is a different place being warned about.
    private func announceAlerts(
        in snapshot: WeatherSnapshot,
        for subject: WeatherSubject
    ) async {
        guard let notifier, let alerts = snapshot.alerts else { return }
        var watch = alertWatches[subject.key] ?? WeatherAlertWatch()
        let worthSaying = watch.observed(alerts)
        alertWatches[subject.key] = watch
        alertWatches.move(keys: CollectionOfOne(subject.key), to: alertWatches.count)
        if alertWatches.count > WeatherRequestState.trackedSubjectLimit {
            alertWatches.removeFirst()
        }
        guard let worst = worthSaying.first else { return }
        // Asked rather than assumed, and asked only when there is something to
        // say: `authorize()` prompts the first time, and a prompt that arrives
        // because a storm warning just came in is a question about something
        // the hiker is in the middle of. One at launch is a question about
        // something that may never happen.
        guard await notifier.authorize() else { return }
        await notifier.post(
            MovementReminderWording.severeWeather(
                worst,
                placeName: cities[subject.key] ?? subject.placeName ?? ""
            )
        )
    }

    /// Moves the badge, and tells the widget what the badge now says.
    ///
    /// The only writer of ``state``. The widget draws a temperature it cannot
    /// fetch, so every move of the badge that has something new to say is also
    /// a publish — see ``WeatherWidgetPublisher``, which decides on its own
    /// whether the new state is worth a redraw and does both off the main
    /// thread.
    ///
    /// **Chained rather than fired**, for the reason
    /// `HikeLiveActivityController.enqueue(_:)` chains: the badge moves in
    /// bursts — a focus, then the fetch that answers it, sometimes a second
    /// subject on top — and each publish is a read of the App Group file
    /// followed by a write of it. Unstructured tasks racing into that file
    /// would settle in whatever order the global executor happened to run
    /// them, which for the commonest burst means a widget left holding the
    /// *older* reading until the next badge move, up to
    /// ``SharedWeatherReading/maximumAge`` later.
    private func publish(_ newState: WeatherBadgeState) {
        guard state != newState else { return }
        state = newState
        guard newState.publishesToWidget else { return }
        let reading = newState.sharedReading
        let previous = pendingWidgetPublish
        pendingWidgetPublish = Task { [widgetPublisher] in
            await previous?.value
            await widgetPublisher.publish(reading)
        }
    }

    /// Waits for everything queued for the widget so far.
    ///
    /// A test seam, and the reason the suites can assert on a stub without
    /// sleeping: the publish is `async` and deliberately off the main thread,
    /// so "the reading landed" is only answerable by draining. See
    /// `HikeLiveActivityController.settle()`.
    func settleWidgetPublishing() async {
        await pendingWidgetPublish?.value
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
        publish(.reading(snapshot, subject: subject))
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
            capturedAt: .now,
            conditions: .preview,
            hourly: WeatherHourSummary.previewStrip,
            days: WeatherDaySummary.previewWeek,
            daylight: .uiTestFixture
        )
    }
}

extension WeatherDaylight {
    /// The daylight `--ui-test-weather` publishes.
    ///
    /// Relative to the launch rather than at fixed clock times, for the reason
    /// ``WeatherSnapshot/uiTestFixture`` is computed: a run at nine in the
    /// evening would otherwise find a dusk that had already passed and no
    /// *Light remaining* row to assert on. Two hours of light left is enough
    /// to be unambiguous in either direction.
    static var uiTestFixture: Self {
        let now = Date.now
        return Self(
            sunrise: now.addingTimeInterval(-Preview.sunriseSecondsAgo),
            sunset: now.addingTimeInterval(Preview.sunsetSecondsAhead),
            civilDusk: now.addingTimeInterval(Preview.civilDuskSecondsAhead),
            highTemperature: Measurement(
                value: Preview.highCelsius,
                unit: UnitTemperature.celsius
            ),
            lowTemperature: Measurement(
                value: Preview.lowCelsius,
                unit: UnitTemperature.celsius
            )
        )
    }

    /// Named so the linter can tell a reading from an arithmetic constant, the
    /// way ``WeatherConditions``' own preview values are.
    private enum Preview {
        /// Nine hours ago, so the fixture reads as an afternoon.
        static let sunriseSecondsAgo: TimeInterval = 9 * 3600
        static let sunsetSecondsAhead: TimeInterval = 90 * 60
        /// Half an hour after sunset, which is about what civil dusk is at
        /// temperate latitudes — and far enough from it that a row wired to
        /// the wrong one shows.
        static let civilDuskSecondsAhead: TimeInterval = 120 * 60
        static let highCelsius: Double = 16
        static let lowCelsius: Double = 4
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
