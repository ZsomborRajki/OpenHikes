//
//  WeatherReadingTiles.swift
//  OpenHikes
//
//  The rest of the reading, a tile each, two to a row.
//
//  One request for `.current` answers with a dozen measurements, and the
//  sheet draws every one it was sent: nothing here is a second request. A
//  tile rather than a row in a list, because each is a figure a hiker looks
//  up by its place — the UV index is top right — and a grid of eight keeps a
//  place for each where a list of nine was a column to read down.
//
//  The order is not arbitrary and is worth keeping. It runs from what a
//  hiker acts on soonest to what they act on least: how cold it will feel
//  and how strong the sun is, then the two that decide whether to carry
//  water, then what can be seen, and finally the two that are context rather
//  than instruction. The wind has a panel of its own between the first pair
//  and the rest — see ``WeatherWindCard``.
//
//  Each tile is one accessibility element with a label and a value, and
//  carries no identifier: nothing looks one up, and the wind's is the one a
//  test asks for.
//

import SwiftUI

/// Two tiles side by side, as tall as the taller of them, or one above the
/// other at an accessibility text size, where half a phone's width is not
/// room for a figure.
struct WeatherTilePair<Leading: View, Trailing: View>: View {
    private let leading: Leading
    private let trailing: Trailing

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            leading
            trailing
        } else {
            HStack(spacing: WeatherCardMetrics.spacing) {
                leading
                trailing
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A tile's measurements. Outside the tile, which is generic and so can
/// hold no stored constants of its own.
private enum WeatherTileMetrics {
    static let spacing: CGFloat = 6
    static let smallestScale: CGFloat = 0.6
    static let minimumHeight: CGFloat = 92
}

/// One measurement: what it is in small capitals, and its figure.
struct WeatherTile<Detail: View>: View {
    private let title: LocalizedStringKey
    private let systemImage: String
    private let value: String
    private let spokenValue: String
    private let detail: Detail

    /// - Parameters:
    ///   - spokenValue: What the tile is read out as, where its figure
    ///     alone is not the whole of what it draws.
    ///   - detail: What stands under the figure: a band, a scale, a sentence.
    init(
        _ title: LocalizedStringKey,
        systemImage: String,
        value: String,
        spokenValue: String? = nil,
        @ViewBuilder detail: () -> Detail = { EmptyView() }
    ) {
        self.title = title
        self.systemImage = systemImage
        self.value = value
        self.spokenValue = spokenValue ?? value
        self.detail = detail()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WeatherTileMetrics.spacing) {
            WeatherCardHeading(title: title, systemImage: systemImage)
            Text(value)
                .font(.title)
                .lineLimit(1)
                .minimumScaleFactor(WeatherTileMetrics.smallestScale)
            detail
        }
        .padding(WeatherCardMetrics.padding)
        .frame(
            maxWidth: .infinity,
            minHeight: WeatherTileMetrics.minimumHeight,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .weatherCardSurface()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(spokenValue)
    }
}

// MARK: - The tiles

/// How cold it will feel and how strong the sun is: the pair above the wind.
struct WeatherExposureTiles: View {
    let temperature: Measurement<UnitTemperature>
    let conditions: WeatherConditions

    var body: some View {
        WeatherTilePair {
            let feel = WeatherFeel(apparent: conditions.apparentTemperature, actual: temperature)
            let value = WeatherReadingFormat.temperature(conditions.apparentTemperature, width: .narrow)
            WeatherTile(
                "Feels like",
                systemImage: "thermometer.medium",
                value: value,
                spokenValue: "\(value), \(feel.caption)"
            ) {
                Text(feel.caption)
                    .font(.footnote)
                    .foregroundStyle(.weatherDim)
            }
        } trailing: {
            // The number and its band, because neither is enough on its
            // own — see ``WeatherReadingFormat/uvIndex(_:)``.
            WeatherTile(
                "UV index",
                systemImage: "sun.max.fill",
                value: conditions.uvIndex.value.formatted(),
                spokenValue: WeatherReadingFormat.uvIndex(conditions.uvIndex)
            ) {
                Text(conditions.uvIndex.category.label)
                    .font(.headline)
                WeatherUVScale(fraction: conditions.uvIndex.scaleFraction)
            }
        }
    }
}

/// Everything else the reading carries, from what a hiker acts on to what
/// is the shape of the day.
struct WeatherContextTiles: View {
    let conditions: WeatherConditions

    var body: some View {
        WeatherTilePair {
            WeatherTile(
                "Humidity",
                systemImage: "humidity.fill",
                value: WeatherReadingFormat.percentage(conditions.humidity)
            )
        } trailing: {
            WeatherTile(
                "Dew point",
                systemImage: "drop.degreesign.fill",
                value: WeatherReadingFormat.temperature(conditions.dewPoint, width: .narrow)
            )
        }
        WeatherTilePair {
            WeatherTile(
                "Visibility",
                systemImage: "eye.fill",
                value: WeatherReadingFormat.visibility(conditions.visibility)
            )
        } trailing: {
            WeatherTile(
                "Cloud cover",
                systemImage: "cloud.fill",
                value: WeatherReadingFormat.percentage(conditions.cloudCover)
            )
        }
        WeatherTilePair {
            WeatherTile(
                "Pressure",
                systemImage: "barometer",
                value: WeatherReadingFormat.pressure(conditions.pressure)
            )
        } trailing: {
            WeatherTile(
                "Precipitation",
                systemImage: "drop.fill",
                value: WeatherReadingFormat.precipitation(conditions.precipitationIntensity)
            )
        }
    }
}

/// The ultraviolet scale, low to extreme, with the index marked on it.
///
/// The five colors are the World Health Organization's for its five bands,
/// which is what makes a dot two-thirds along mean something before the
/// number is read.
private struct WeatherUVScale: View {
    private static let thickness: CGFloat = 5
    private static let markerRing: CGFloat = 2
    private static let ringOpacity = 0.45
    private static let colors: [Color] = [.green, .yellow, .orange, .red, .purple]

    /// How far along the scale the index is, 0…1.
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            let diameter = Self.thickness + Self.markerRing
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: Self.colors, startPoint: .leading, endPoint: .trailing))
                Circle()
                    .fill(.white)
                    .stroke(.black.opacity(Self.ringOpacity), lineWidth: Self.markerRing)
                    .frame(width: diameter, height: diameter)
                    .offset(x: fraction * (proxy.size.width - diameter))
            }
        }
        .frame(height: Self.thickness)
        .padding(.top, Self.thickness)
        .accessibilityHidden(true)
    }
}
