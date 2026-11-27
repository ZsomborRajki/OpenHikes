//
//  WeatherHero.swift
//  OpenHikes
//
//  The head of the weather sheet: where the reading is for, the temperature,
//  the sky in a phrase and the range the day will reach. Set straight on the
//  sky with no panel behind it, the way Apple Weather opens.
//
//  The temperature is the one figure on the sheet a hiker reads from arm's
//  length, so it is the one figure set at this size. Its size still follows
//  the reader's text size, as every other font here does.
//
//  One accessibility element. A place, a number, a phrase and a range are one
//  fact about now — the shape ``DetailRow`` takes.
//

import SwiftUI

struct WeatherHero: View {
    private static let spacing: CGFloat = 2
    private static let titleLines = 2
    /// How far the temperature may shrink to stay on its one line: a
    /// three-figure frost with its unit spelled is wider than a phone at a
    /// large text size.
    private static let smallestScale = 0.5

    let snapshot: WeatherSnapshot
    /// Which place the reading is for, or `nil` when it is simply here.
    let placeName: String?
    /// The trail or the searched place the hiker asked about, where the
    /// title names the town it is in instead.
    let eyebrow: String?

    @ScaledMetric(relativeTo: .largeTitle) private var temperatureSize: CGFloat = 92

    var body: some View {
        VStack(spacing: Self.spacing) {
            if let eyebrow {
                Text(verbatim: eyebrow)
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.weatherDim)
                    .lineLimit(1)
            }
            // `Text` rather than `placeName ?? "My Location"`, which types
            // the whole expression as `String` and so takes the
            // non-localized overload: the fallback would lose its
            // `LocalizedStringKey` to offer a town's name a translation it
            // was never going to be given.
            (placeName.map { Text(verbatim: $0) } ?? Text("My Location"))
                .font(.title)
                .lineLimit(Self.titleLines)
                .multilineTextAlignment(.center)
            Text(snapshot.formattedTemperature())
                .font(.system(size: temperatureSize, weight: .thin))
                .lineLimit(1)
                .minimumScaleFactor(Self.smallestScale)
            Text(snapshot.conditionDescription)
                .font(.title3.weight(.medium))
                .multilineTextAlignment(.center)
            if let range = snapshot.daylight.flatMap(Self.range) {
                Text(range)
                    .font(.title3.weight(.medium))
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            placeName.map { String(localized: "Conditions in \($0)") }
                ?? String(localized: "Current conditions")
        )
        .accessibilityValue(spoken)
        .accessibilityIdentifier("weather-detail-conditions")
    }

    private var spoken: String {
        let reading = "\(snapshot.spokenTemperature()), \(snapshot.conditionDescription)"
        guard let range = snapshot.daylight.flatMap(Self.spokenRange) else { return reading }
        return "\(reading), \(range)"
    }

    /// The day's high and low as the line under the sky, or `nil` when the
    /// forecast carried either one alone or neither: half a range under a
    /// temperature reads as a second temperature.
    private static func range(of daylight: WeatherDaylight) -> String? {
        guard let high = daylight.highTemperature, let low = daylight.lowTemperature else { return nil }
        let highest = WeatherReadingFormat.temperature(high, width: .narrow)
        let lowest = WeatherReadingFormat.temperature(low, width: .narrow)
        return String(
            localized: "H:\(highest) L:\(lowest)",
            comment: "The day's high and low temperature under the current one, abbreviated as Apple Weather does"
        )
    }

    private static func spokenRange(of daylight: WeatherDaylight) -> String? {
        guard let high = daylight.highTemperature, let low = daylight.lowTemperature else { return nil }
        let highest = WeatherReadingFormat.temperature(high, width: .wide)
        let lowest = WeatherReadingFormat.temperature(low, width: .wide)
        return String(localized: "High \(highest), low \(lowest)", comment: "A day's forecast range, spoken")
    }
}

/// What the sheet says in the hero's place when no forecast came.
///
/// The badge says only that something is off — a slashed cloud over the map
/// is as much as belongs there. This is where someone who tapped it to ask
/// gets a sentence.
struct WeatherUnavailableNotice: View {
    private static let spacing: CGFloat = 8
    private static let verticalPadding: CGFloat = 32

    let placeName: String?

    @ScaledMetric(relativeTo: .largeTitle) private var glyphSize: CGFloat = 56

    var body: some View {
        VStack(spacing: Self.spacing) {
            // The cloud with a stroke through it that SF Symbols has. A
            // plain "cloud.slash" is not one of its names, and a name it
            // does not have compiles and draws nothing.
            Image(systemName: "icloud.slash")
                .font(.system(size: glyphSize, weight: .light))
                .accessibilityHidden(true)
            Text(
                placeName.map { String(localized: "No forecast for \($0)") }
                    ?? String(localized: "No forecast available")
            )
            .font(.title2.weight(.semibold))
            .accessibilityIdentifier("weather-detail-unavailable")
            Text("OpenHikes couldn\u{2019}t reach Apple Weather. It will try again automatically.")
                .font(.subheadline)
                .foregroundStyle(.weatherDim)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Self.verticalPadding)
    }
}
