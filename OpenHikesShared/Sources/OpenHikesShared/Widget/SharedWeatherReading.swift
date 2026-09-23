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

    /// Fails rather than storing a non-finite temperature.
    ///
    /// `JSONEncoder` refuses a non-finite `Double` by default, so a reading
    /// built from one would never reach disk and the failure would be a silent
    /// no-op at the write site instead of a value refused at its source. The
    /// same argument ``UnitMercatorRect/isFinite`` makes, in a much smaller
    /// type.
    public init?(temperatureCelsius: Double, capturedAt: Date) {
        guard temperatureCelsius.isFinite else { return nil }
        self.temperatureCelsius = temperatureCelsius
        self.capturedAt = capturedAt
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
