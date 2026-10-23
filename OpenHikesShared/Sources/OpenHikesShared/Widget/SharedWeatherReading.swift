//
//  SharedWeatherReading.swift
//  OpenHikesShared
//
//  The one temperature the iOS widget draws, written by the app.
//
//  Weather lives entirely in the app target — WeatherKit, the polling policy,
//  the badge and its staleness rule are all there, and none of it can be
//  reached from an extension that is handed a rendered snapshot and a few
//  hundred bytes of App Group state. So the app publishes the number it is
//  already showing and the widget draws that, which is the same arrangement
//  ``SharedTrailSnapshot`` has with route matching: one process computes, the
//  other renders.
//
//  **A file of its own, not a field on the trail snapshot.** The two change on
//  unrelated clocks and for unrelated reasons. A trail snapshot is rewritten
//  whenever a live fix lands — as often as every 45 seconds — and is scoped to
//  one hike; a reading changes a few times an hour and belongs to wherever the
//  hiker last pointed the badge, which is frequently not the selected trail at
//  all. Folding one into the other would mean either a temperature that goes
//  missing the moment the trail is deselected, or a reading rewritten eighty
//  times an hour to say the same thing.
//
//  **It says what it is about**, because a file of its own does not make it
//  every widget's to draw. Two widgets pinned to two trails both read this one
//  file, and a number from wherever the badge last pointed, drawn without a
//  name beside a trail it is not about, is a forecast for the wrong mountain.
//  The widget has no room for a place name in its corner, so it draws the
//  number only beside what the number describes — see ``Subject`` — and
//  nothing anywhere else.
//
//  **Celsius on the wire**, for the reason `WeatherReadingStore` gives for its
//  own blob: what is written here is read back by a later build of the widget,
//  and the bytes must not depend on which unit the provider used that day. The
//  reader converts on the way to the screen.
//

import Foundation

/// The temperature the app's weather badge is currently showing, handed to the
/// widget.
///
/// Carries when the reading was *taken* rather than when it was written,
/// because the widget's own question is how old the number is — see
/// ``maximumAge``.
public struct SharedWeatherReading: SharedPayload, Equatable {
    public static let currentSchemaVersion = 1

    /// The Apple Weather trademark in text, " Weather", drawn beside the
    /// temperature wherever Apple's published mark cannot be.
    ///
    /// WeatherKit's terms require the mark wherever its data is displayed,
    /// and this number is its data. The widget cannot fetch the image Apple
    /// publishes — it renders a snapshot and waits on nothing — and the app
    /// shows this while that image loads, so both read it from here rather
    /// than spelling it twice. U+F8FF is the Apple glyph in Apple's system
    /// fonts, which are the only ones either target draws it in.
    public static let attributionMark = "\u{F8FF} Weather"

    /// How old a reading may get before the widget stops drawing it.
    ///
    /// Deliberately far looser than the half-hour the badge dims at. The badge
    /// is on a screen the hiker is looking at, beside an app that is polling;
    /// the widget is a picture WidgetKit re-renders on its own schedule, which
    /// for a trail nobody is walking is once every
    /// ``TrailWidgetProvider/safetyNetHours``. Dimming at the badge's
    /// threshold would mean a widget with no temperature on it almost all of
    /// the time, which is not a more honest widget — it is an emptier one.
    ///
    /// Three hours is the point where the number stops being roughly true.
    /// Air temperature moves a few degrees across an afternoon and a good deal
    /// more across a dawn or a dusk, and on a hike a temperature is safety
    /// information, so past this the widget says nothing rather than
    /// something stale. The widget does not wait for a reload to find out:
    /// ``expiresAt`` is folded into the timeline's refresh date, so the entry
    /// that drops the reading is scheduled at the moment it goes off rather
    /// than whenever the next redraw happens to land.
    public static let maximumAge: TimeInterval = 3 * 60 * 60

    public let schemaVersion: Int

    /// The reading, in Celsius. See this file's header for why the unit is
    /// fixed rather than carried.
    public var temperatureCelsius: Double

    /// When the provider took the reading — `WeatherSnapshot.capturedAt` in
    /// the app, not the moment this was written to the App Group.
    public var capturedAt: Date

    /// What the badge was pointed at when it showed this reading.
    public var subject: Subject

    /// The place a reading is about, reduced to what the widget can match
    /// against what it draws: the app's `WeatherSubject` without its
    /// coordinate or its name.
    ///
    /// **Identity, not position.** A trail's subject follows the hiker along
    /// it and the hiker's own moves with every significant change, so a
    /// coordinate here would make every step a different subject — and a
    /// redraw — while saying nothing the widget could use: it draws a trail
    /// by its ID and a recording by its existence, and matches nothing by
    /// distance. That is the app's job, and it stays there.
    public enum Subject: Codable, Sendable, Equatable {
        /// Wherever the hiker is — the subject a recording owns.
        case hiker
        /// A selected hike's route.
        case trail(hikeID: UUID)
        /// A searched place, which is never a trail and never the hiker,
        /// however near either it is: the hiker asked about that place.
        case place
    }

    /// Fails rather than storing a non-finite temperature.
    ///
    /// `JSONEncoder` refuses a non-finite `Double` by default, so a reading
    /// built from one would never reach disk and the failure would be a silent
    /// no-op at the write site instead of a value refused at its source. The
    /// same argument ``UnitMercatorRect/isFinite`` makes, in a much smaller
    /// type.
    public init?(temperatureCelsius: Double, capturedAt: Date, subject: Subject) {
        guard temperatureCelsius.isFinite else { return nil }
        self.temperatureCelsius = temperatureCelsius
        self.capturedAt = capturedAt
        self.subject = subject
        schemaVersion = Self.currentSchemaVersion
    }

    /// How long ago this reading was taken. Clamped at zero for the reason
    /// `WeatherSnapshot.age(asOf:)` clamps: a provider clock a second ahead of
    /// the device's would otherwise describe a reading from the future.
    public func age(asOf now: Date = .now) -> TimeInterval {
        max(0, now.timeIntervalSince(capturedAt))
    }

    /// When this reading stops being drawn — see ``maximumAge``.
    public var expiresAt: Date {
        capturedAt.addingTimeInterval(Self.maximumAge)
    }

    public func isExpired(asOf now: Date = .now) -> Bool {
        age(asOf: now) >= Self.maximumAge
    }

    /// Whether a widget drawing the trail `hikeID` may draw this reading
    /// beside it: only when the reading was taken for that trail.
    ///
    /// Not a reading about the hiker, even one taken on that trail's
    /// hillside. Whether the hiker is near a trail is a question about where
    /// they are, the app is the one that knows, and it already answers it:
    /// a selected trail's subject follows the hiker once they are out on it,
    /// and keeps the trail's ID while it does.
    public func isAbout(trail hikeID: UUID) -> Bool {
        subject == .trail(hikeID: hikeID)
    }

    /// Whether a widget that a recording has taken over may draw this
    /// reading: only when it is about the hiker, the subject a recording
    /// owns for as long as it runs.
    ///
    /// Anything else in the file is a trail or a place browsed before the
    /// recording began, left there while the first reading about the hiker
    /// is on its way — the app does not empty the corner for a fetch in
    /// flight.
    public var isAboutHiker: Bool {
        subject == .hiker
    }

    /// What the widget draws: the shortest spelling the locale accepts, which
    /// is a bare `54°` where the unit is unambiguous and `12 °C` where it is
    /// not.
    ///
    /// The same call `WeatherSnapshot.formattedTemperature(locale:)` makes, so
    /// the number on the home screen and the number on the badge behind it are
    /// one rounding of one quantity rather than two that have to be kept in
    /// step by hand — which is the mistake `WeatherReadingFormat`'s header
    /// exists to describe.
    public func formatted(locale: Locale = .autoupdatingCurrent) -> String {
        WidgetFormat.temperature(celsius: temperatureCelsius, width: .narrow, locale: locale)
    }

    /// The same quantity with its unit spelled out, for the widget's single
    /// accessibility element. A bare `54°` is not spoken as a temperature.
    public func spoken(locale: Locale = .autoupdatingCurrent) -> String {
        WidgetFormat.temperature(celsius: temperatureCelsius, width: .wide, locale: locale)
    }
}
