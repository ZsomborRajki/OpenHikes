//
//  WeatherTemperatureSpan.swift
//  OpenHikes
//
//  Where a temperature falls in the week ahead, and what color it is.
//
//  The daily forecast draws each day as a bar from its low to its high. A bar
//  means something only against the bars beside it, so all of them share one
//  scale: the week's coldest low to its warmest high. A cold day then sits to
//  the left of a warm one, and a day with a wide swing is longer than a day
//  with none.
//
//  The color is the other half, and it is absolute where the position is
//  relative: 4° is the same blue-green in a week of frost and in a week of
//  heat, so the bars of a cold week are blue and a hot week's are orange
//  without anybody reading a figure. One gradient is laid across the whole
//  scale and each day's bar is a window onto it.
//
//  Everything here is in degrees Celsius whatever unit the reading came in:
//  the scale is ours, and the figures beside the bars are still formatted for
//  the reader by ``WeatherReadingFormat``.
//

import Foundation

/// The week's coldest low to its warmest high, in degrees Celsius.
nonisolated struct WeatherTemperatureSpan: Equatable, Sendable {
    /// A week of one temperature still needs a scale to be drawn on, so a
    /// span is never narrower than this.
    static let narrowest = 1.0

    let lower: Double
    let upper: Double

    /// `nil` for a week with no day in it, or none with a temperature that
    /// is a number.
    init?(days: [WeatherDaySummary]) {
        let figures = days
            .flatMap { [$0.lowTemperature, $0.highTemperature] }
            .map(Self.celsius)
            .filter(\.isFinite)
        guard let coldest = figures.min(), let warmest = figures.max() else { return nil }
        self.init(lower: coldest, upper: warmest)
    }

    init(lower: Double, upper: Double) {
        let spread = max(upper - lower, Self.narrowest)
        let middle = (lower + upper) / 2
        self.lower = middle - spread / 2
        self.upper = middle + spread / 2
    }

    /// How far along the scale a temperature is, 0 at the week's coldest and
    /// 1 at its warmest. Anything outside is held at the end it is beyond.
    func fraction(of temperature: Measurement<UnitTemperature>) -> Double {
        fraction(ofCelsius: Self.celsius(temperature))
    }

    func fraction(ofCelsius celsius: Double) -> Double {
        guard celsius.isFinite else { return 0 }
        return min(max((celsius - lower) / (upper - lower), 0), 1)
    }

    /// The stretch of the scale one day covers. A forecast whose low is
    /// above its high is drawn as the stretch between them all the same.
    func extent(
        from low: Measurement<UnitTemperature>,
        to high: Measurement<UnitTemperature>
    ) -> ClosedRange<Double> {
        let ends = [fraction(of: low), fraction(of: high)].sorted()
        return ends[0]...ends[1]
    }

    private static func celsius(_ temperature: Measurement<UnitTemperature>) -> Double {
        temperature.converted(to: .celsius).value
    }
}

/// A color by its sRGB parts, 0…1.
///
/// Its own small type, not SwiftUI's `Color`, so two of them can be mixed
/// and compared by a suite with no view and no trait collection to resolve
/// them in.
nonisolated struct WeatherTint: Equatable, Sendable {
    private static let channelTop = 255.0
    private static let hexDigits = 6
    private static let radix = 16
    private static let channelBits = 8
    private static let channelMask: UInt32 = 0xFF

    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `#RRGGBB`, with or without the `#`.
    init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == Self.hexDigits, let value = UInt32(digits, radix: Self.radix) else { return nil }
        let channel = { (index: Int) -> Double in
            Double((value >> UInt32(index * Self.channelBits)) & Self.channelMask) / Self.channelTop
        }
        self.init(red: channel(2), green: channel(1), blue: channel(0))
    }

    /// This color with `fraction` of the way to `other` gone.
    func mixed(with other: Self, by fraction: Double) -> Self {
        let amount = min(max(fraction, 0), 1)
        return Self(
            red: red + (other.red - red) * amount,
            green: green + (other.green - green) * amount,
            blue: blue + (other.blue - blue) * amount
        )
    }
}

/// What color a temperature is drawn in.
nonisolated enum WeatherTemperatureColor {
    /// One stop of the gradient a span is drawn with.
    struct Stop: Equatable, Sendable {
        /// 0 at the span's coldest, 1 at its warmest.
        var location: Double
        var tint: WeatherTint
    }

    /// The temperature the first color stands at, and how many degrees lie
    /// between one color and the next.
    static let coldest = -20.0
    static let step = 6.0

    /// Coldest first, ``step`` degrees apart: violet where it is bitter,
    /// through the blues to green at a mild sixteen, then yellow, orange and
    /// red. The order and the steps are Apple Weather's; the colors are
    /// picked to read on every ``WeatherSky``.
    static let anchors: [WeatherTint] = [
        "#7B6CF0", "#5C7DF2", "#4A9BF5", "#4DB8F5", "#52D0E8", "#58D8B8",
        "#93DC5F", "#F0D64B", "#F7A53C", "#F0613F", "#D93A5C",
    ].compactMap(WeatherTint.init(hex:))

    /// The color of one temperature, held at the scale's ends beyond them.
    static func tint(atCelsius celsius: Double) -> WeatherTint {
        guard let first = anchors.first, let last = anchors.last else {
            return WeatherTint(red: 1, green: 1, blue: 1)
        }
        guard celsius.isFinite else { return first }
        let position = (celsius - coldest) / step
        guard position > 0 else { return first }
        guard position < Double(anchors.count - 1) else { return last }
        let index = Int(position.rounded(.down))
        return anchors[index].mixed(with: anchors[index + 1], by: position - Double(index))
    }

    /// The gradient across a span: its two ends, and every color that
    /// stands between them, in order.
    static func stops(across span: WeatherTemperatureSpan) -> [Stop] {
        let between = anchors.indices
            .map { coldest + Double($0) * step }
            .filter { $0 > span.lower && $0 < span.upper }
        return ([span.lower] + between + [span.upper]).map { celsius in
            Stop(location: span.fraction(ofCelsius: celsius), tint: tint(atCelsius: celsius))
        }
    }
}
