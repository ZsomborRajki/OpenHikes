//
//  WeatherForecastCards.swift
//  OpenHikes
//
//  The two forecasts on the weather sheet: the next hours as a strip that
//  scrolls sideways, and the next days as rows.
//
//  A strip for the hours and rows for the days, and the difference is the
//  question each answers. The hours are a timeline, read along. The days are
//  a comparison — which day this week to walk — and a row has room for what
//  compares them: each day's low and high as a bar on one scale, so the warm
//  day and the wet day are found without reading fourteen figures. See
//  ``WeatherTemperatureSpan``.
//

import SwiftUI

// MARK: - The next hours

/// The next few hours, which is the half of the reading a hiker at a
/// trailhead is actually deciding on — see ``WeatherHourSummary``.
///
/// One accessibility element per hour rather than per glyph: a time, a sky
/// and a temperature are one fact about one hour.
struct WeatherHourlyCard: View {
    /// Between two hours, and it is the whole of the gap at a large text
    /// size, where a temperature is wider than ``columnWidth``.
    private static let columnSpacing: CGFloat = 14
    private static let columnWidth: CGFloat = 46
    private static let rowSpacing: CGFloat = 8

    let hours: [WeatherHourSummary]
    let now: Date
    let clock: WeatherForecastClock

    var body: some View {
        WeatherCard("Next hours", systemImage: "clock", bleeds: true) {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Self.columnSpacing) {
                    ForEach(hours) { hour in
                        column(hour)
                    }
                }
                .padding(.vertical, Self.rowSpacing / 2)
            }
            .contentMargins(.horizontal, WeatherCardMetrics.padding, for: .scrollContent)
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("weather-detail-hourly")
        }
    }

    private func column(_ hour: WeatherHourSummary) -> some View {
        let label = label(for: hour)
        return VStack(spacing: Self.rowSpacing) {
            Text(verbatim: label)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
            WeatherGlyph(symbolName: hour.symbolName, precipitationChance: hour.precipitationChance)
            Text(WeatherReadingFormat.temperature(hour.temperature, width: .narrow))
                .font(.body.weight(.medium))
                .lineLimit(1)
                .fixedSize()
        }
        .frame(minWidth: Self.columnWidth)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityValue(Self.spoken(hour))
    }

    /// The hour's own time, or "Now" for the hour the strip opens on while
    /// that hour is still running: "21" at twenty to ten is a time to work
    /// out, and the first column is the one nobody should have to.
    private func label(for hour: WeatherHourSummary) -> String {
        let isNow = hour.id == hours.first?.id
            && hour.date <= now
            && now < hour.date.addingTimeInterval(WeatherHourlyPolicy.hourSeconds)
        return isNow
            ? String(localized: "Now", comment: "The first column of the hourly forecast, in place of the hour")
            : clock.hour(hour.date)
    }

    /// What one hour says out loud. The chance of rain is spoken whenever the
    /// strip draws it, and left out entirely when it does not — a reader
    /// hearing "zero percent" for every dry hour learns nothing twelve times.
    private static func spoken(_ hour: WeatherHourSummary) -> String {
        let temperature = WeatherReadingFormat.temperature(hour.temperature, width: .wide)
        guard let chance = WeatherReadingFormat.precipitationChance(hour.precipitationChance) else {
            return temperature
        }
        return String(localized: "\(temperature), \(chance) chance of precipitation")
    }
}

// MARK: - The next days

/// The week ahead — see ``WeatherDaySummary``.
///
/// Handed the days still to come: the caller trims the ones that have gone,
/// because only it knows the moment the sheet is drawn at.
struct WeatherDailyCard: View {
    let days: [WeatherDaySummary]
    let now: Date
    let timeZone: TimeZone
    /// The temperature now, marked on today's bar.
    let current: Measurement<UnitTemperature>

    var body: some View {
        if let span = WeatherTemperatureSpan(days: days) {
            let gradient = Gradient(stops: WeatherTemperatureColor.stops(across: span).map { stop in
                Gradient.Stop(color: Color(stop.tint), location: stop.location)
            })
            WeatherCard("Next days", systemImage: "calendar") {
                VStack(spacing: 0) {
                    ForEach(days) { day in
                        if day.id != days.first?.id {
                            WeatherRule()
                        }
                        WeatherDayRow(
                            day: day,
                            isToday: day.isInProgress(asOf: now),
                            timeZone: timeZone,
                            span: span,
                            gradient: gradient,
                            current: current
                        )
                    }
                }
            }
        }
    }
}

private struct WeatherDayRow: View {
    private static let spacing: CGFloat = 10
    /// Wide enough for the longest abbreviated weekday a locale is likely to
    /// hand back, so the glyphs beside them line up down the card rather
    /// than stepping in and out with the day's name.
    ///
    /// A *minimum* rather than a width, because it does not scale with the
    /// reader's text size: at an accessibility size "Today" is half again
    /// as wide as this, and a fixed frame would truncate the one row the
    /// card names in words.
    private static let dayWidth: CGFloat = 58
    private static let glyphWidth: CGFloat = 40
    /// Wide enough for a two-figure temperature with its unit, a minimum
    /// for the reason ``dayWidth`` is.
    private static let figureWidth: CGFloat = 44

    let day: WeatherDaySummary
    let isToday: Bool
    let timeZone: TimeZone
    let span: WeatherTemperatureSpan
    let gradient: Gradient
    let current: Measurement<UnitTemperature>

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // Two lines at an accessibility text size: on one, the
                // day's name and both figures were cut to their first
                // letters to make room for each other.
                VStack(spacing: Self.spacing / 2) {
                    HStack(spacing: Self.spacing) {
                        name
                        Spacer(minLength: 0)
                        glyph
                    }
                    HStack(spacing: Self.spacing) {
                        range
                    }
                }
                .padding(.vertical, WeatherCardMetrics.rowPadding)
            } else {
                HStack(spacing: Self.spacing) {
                    name
                        .frame(minWidth: Self.dayWidth, alignment: .leading)
                    glyph
                        .frame(minWidth: Self.glyphWidth)
                    range
                }
            }
        }
        .frame(minHeight: AccessibilityMetrics.minimumTapTarget)
        // A day, a sky and a range are one fact about one day — the shape
        // the hour columns and ``WeatherCardRow`` both take.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WeatherForecastClock.spokenWeekday(day.date, isToday: isToday, in: timeZone))
        .accessibilityValue(Self.spoken(day))
        // The same identifier on every row, so a test can count them: the
        // horizon is the decision this card was filed about, and a forecast
        // quietly drawing ten days again is the regression worth catching.
        .accessibilityIdentifier("weather-detail-day")
    }

    private var name: some View {
        Text(WeatherForecastClock.weekday(day.date, isToday: isToday, in: timeZone))
            .font(.body.weight(.medium))
            .lineLimit(1)
    }

    private var glyph: some View {
        WeatherGlyph(symbolName: day.symbolName, precipitationChance: day.precipitationChance)
    }

    /// The low, the bar from it to the high, and the high.
    @ViewBuilder private var range: some View {
        Text(WeatherReadingFormat.temperature(day.lowTemperature, width: .narrow))
            .font(.body.weight(.medium))
            .foregroundStyle(.weatherDim)
            .lineLimit(1)
            .frame(minWidth: Self.figureWidth, alignment: .trailing)
        WeatherRangeBar(
            extent: span.extent(from: day.lowTemperature, to: day.highTemperature),
            marker: isToday ? span.fraction(of: current) : nil,
            gradient: gradient
        )
        Text(WeatherReadingFormat.temperature(day.highTemperature, width: .narrow))
            .font(.body.weight(.medium))
            .lineLimit(1)
            .frame(minWidth: Self.figureWidth, alignment: .trailing)
    }

    /// What one day says out loud.
    ///
    /// The weekday is already the row's label, so this is the forecast
    /// itself: the range, and the chance of rain only where the row draws it
    /// — a reader hearing "zero percent" on every dry day learns nothing
    /// seven times.
    private static func spoken(_ day: WeatherDaySummary) -> String {
        let high = WeatherReadingFormat.temperature(day.highTemperature, width: .wide)
        let low = WeatherReadingFormat.temperature(day.lowTemperature, width: .wide)
        let reach = String(
            localized: "High \(high), low \(low)",
            comment: "A day's forecast range, spoken"
        )
        guard let chance = WeatherReadingFormat.precipitationChance(day.precipitationChance) else {
            return reach
        }
        return String(localized: "\(reach), \(chance) chance of precipitation")
    }
}

/// One day's low to its high, as a stretch of the week's scale.
///
/// The gradient is laid across the whole track and the day's stretch is a
/// window onto it, so a color means the same temperature on every row.
private struct WeatherRangeBar: View {
    private static let thickness: CGFloat = 5
    private static let markerRing: CGFloat = 2
    private static let trackOpacity = 0.22

    /// The stretch of the scale this day covers, 0…1.
    let extent: ClosedRange<Double>
    /// Where the temperature now stands on the scale, on today's row.
    let marker: Double?
    let gradient: Gradient

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            // Never shorter than it is thick: a day whose low is its high
            // is still a day on the scale, drawn as a dot.
            let length = max((extent.upperBound - extent.lowerBound) * width, Self.thickness)
            let start = min(extent.lowerBound * width, width - length)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.black.opacity(Self.trackOpacity))
                LinearGradient(gradient: gradient, startPoint: .leading, endPoint: .trailing)
                    .mask(alignment: .leading) {
                        Capsule()
                            .frame(width: length)
                            .offset(x: start)
                    }
                if let marker {
                    // Held inside the day's own stretch: the forecast's range
                    // and the reading can disagree by a degree, and a dot off
                    // the end of its bar reads as a second, unexplained mark.
                    let inset = Self.thickness / 2
                    let center = min(max(marker * width, start + inset), start + length - inset)
                    let diameter = Self.thickness + Self.markerRing
                    Circle()
                        .fill(.white)
                        .stroke(.black.opacity(Self.trackOpacity * 2), lineWidth: Self.markerRing)
                        .frame(width: diameter, height: diameter)
                        .offset(x: center - diameter / 2)
                }
            }
        }
        .frame(height: Self.thickness)
        .frame(minWidth: Self.thickness * 2)
        .accessibilityHidden(true)
    }
}

extension Color {
    /// A weather tint as a color to draw with.
    init(_ tint: WeatherTint) {
        self.init(.sRGB, red: tint.red, green: tint.green, blue: tint.blue, opacity: 1)
    }
}
