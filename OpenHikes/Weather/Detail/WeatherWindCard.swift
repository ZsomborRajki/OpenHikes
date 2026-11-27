//
//  WeatherWindCard.swift
//  OpenHikes
//
//  The wind, as rows and as a compass.
//
//  A panel of its own, the full width of the sheet, because wind is the
//  reading a hiker on a ridge acts on and the one a figure says least about:
//  "14 km/h NW" has to be turned round in the head to find which side of the
//  hill is the sheltered one. The compass does that turning. Its arrow flies
//  the way the wind blows, from the bearing it comes from across to the one
//  it is going to, as the arrow on Apple Weather's does.
//
//  One accessibility element, called what the old row was: speed, direction
//  and gust are one fact, and a gust on a line of its own reads as a second
//  wind. The compass says nothing aloud that the sentence has not.
//

import SwiftUI

struct WeatherWindCard: View {
    private static let compassSize: CGFloat = 116

    let wind: WeatherWind

    var body: some View {
        WeatherCard("Wind", systemImage: "wind") {
            WeatherBeside {
                WeatherRows(rows: rows)
            } trailing: {
                WeatherCompass(wind: wind)
                    .frame(width: Self.compassSize, height: Self.compassSize)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Wind")
        .accessibilityValue(WeatherReadingFormat.wind(wind))
        .accessibilityIdentifier("weather-detail-wind")
    }

    /// The gust is left out entirely when the provider reports none — a
    /// still day has a wind speed and no gust — and the direction when the
    /// bearing is not a number.
    private var rows: [WeatherRowItem] {
        var items = [
            WeatherRowItem(
                id: "weather-detail-wind-speed",
                label: "Wind",
                value: WeatherReadingFormat.windSpeed(wind.speed)
            ),
        ]
        if let gust = wind.gust {
            items.append(
                WeatherRowItem(
                    id: "weather-detail-wind-gusts",
                    label: "Gusts",
                    value: WeatherReadingFormat.windSpeed(gust)
                )
            )
        }
        if let bearing = WeatherReadingFormat.windBearing(wind.direction) {
            items.append(WeatherRowItem(id: "weather-detail-wind-direction", label: "Direction", value: bearing))
        }
        return items
    }
}

/// A compass rose with the wind drawn across it and its speed in the middle.
///
/// A drawing in a frame of one size, so its lettering is of one size too
/// and does not follow the reader's text size: the rows beside it say the
/// same figures in type that does.
private struct WeatherCompass: View {
    /// The rose's measurements, as fractions of its radius where they scale
    /// with it.
    private enum Rose {
        static let tickCount = 72
        /// Every sixth tick is a long one: thirty degrees apart.
        static let majorEvery = 6
        static let tickLength: CGFloat = 7
        static let minorOpacity = 0.3
        static let majorOpacity = 0.75
        static let majorWidth: CGFloat = 1.5
        /// Where the four letters stand, inside the ticks.
        static let letterRadius: CGFloat = 0.68
        /// The middle is the figure's: the arrow stops short of it on both
        /// sides.
        static let hubRadius: CGFloat = 0.46
        static let arrowWidth: CGFloat = 2.5
        static let headLength: CGFloat = 9
        static let headHalfWidth: CGFloat = 5
        static let tailRadius: CGFloat = 3.5
        static let cardinalStep = 90.0
        static let figureSize: CGFloat = 22
        static let unitSize: CGFloat = 11
        static let letterSize: CGFloat = 11
    }

    let wind: WeatherWind

    var body: some View {
        let speed = WeatherReadingFormat.windSpeedParts(wind.speed)
        Canvas { context, size in
            let radius = min(size.width, size.height) / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            Self.drawTicks(in: &context, center: center, radius: radius)
            Self.drawLetters(in: &context, center: center, radius: radius)
            let degrees = wind.direction.converted(to: .degrees).value
            if degrees.isFinite {
                Self.drawArrow(in: &context, center: center, radius: radius, fromDegrees: degrees)
            }
        }
        .overlay {
            VStack(spacing: 0) {
                Text(verbatim: speed.figure)
                    .font(.system(size: Rose.figureSize, weight: .bold))
                    .monospacedDigit()
                Text(verbatim: speed.unit)
                    .font(.system(size: Rose.unitSize, weight: .semibold))
                    .foregroundStyle(.weatherDim)
            }
            .lineLimit(1)
            .fixedSize()
        }
        .accessibilityHidden(true)
    }

    /// A point on the rose: `degrees` clockwise from north, `distance` out
    /// from the middle.
    private static func point(_ center: CGPoint, degrees: Double, distance: CGFloat) -> CGPoint {
        let radians = Measurement(value: degrees, unit: UnitAngle.degrees).converted(to: .radians).value
        return CGPoint(x: center.x + sin(radians) * distance, y: center.y - cos(radians) * distance)
    }

    private static func drawTicks(in context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        for index in 0..<Rose.tickCount {
            let degrees = Double(index) * (Double(Rose.cardinalStep) * 4 / Double(Rose.tickCount))
            let isMajor = index.isMultiple(of: Rose.majorEvery)
            var tick = Path()
            tick.move(to: point(center, degrees: degrees, distance: radius - Rose.tickLength))
            tick.addLine(to: point(center, degrees: degrees, distance: radius))
            context.stroke(
                tick,
                with: .color(.white.opacity(isMajor ? Rose.majorOpacity : Rose.minorOpacity)),
                lineWidth: isMajor ? Rose.majorWidth : 1
            )
        }
    }

    /// North, east, south and west, in the reader's own abbreviations: the
    /// words ``WeatherReadingFormat/windDirection(_:)`` already spells.
    private static func drawLetters(in context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        for quarter in 0..<4 {
            let degrees = Double(quarter) * Rose.cardinalStep
            let bearing = Measurement(value: degrees, unit: UnitAngle.degrees)
            guard let letter = WeatherReadingFormat.windDirection(bearing) else { continue }
            context.draw(
                Text(verbatim: letter)
                    .font(.system(size: Rose.letterSize, weight: .bold))
                    .foregroundStyle(.white.opacity(Rose.majorOpacity)),
                at: point(center, degrees: degrees, distance: radius * Rose.letterRadius)
            )
        }
    }

    /// The wind's way across the rose: a ring where it comes from, a head
    /// where it is going, and a gap in the middle for the figure.
    private static func drawArrow(
        in context: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        fromDegrees: Double
    ) {
        let toDegrees = fromDegrees + Rose.cardinalStep * 2
        let hub = radius * Rose.hubRadius
        let tail = point(center, degrees: fromDegrees, distance: radius - Rose.tailRadius)
        let tip = point(center, degrees: toDegrees, distance: radius)
        let neck = point(center, degrees: toDegrees, distance: radius - Rose.headLength)

        var shaft = Path()
        shaft.move(to: point(center, degrees: fromDegrees, distance: radius - Rose.tailRadius * 2))
        shaft.addLine(to: point(center, degrees: fromDegrees, distance: hub))
        shaft.move(to: point(center, degrees: toDegrees, distance: hub))
        shaft.addLine(to: neck)
        context.stroke(shaft, with: .color(.white), style: StrokeStyle(lineWidth: Rose.arrowWidth, lineCap: .round))

        let ring = CGRect(
            x: tail.x - Rose.tailRadius,
            y: tail.y - Rose.tailRadius,
            width: Rose.tailRadius * 2,
            height: Rose.tailRadius * 2
        )
        context.stroke(Path(ellipseIn: ring), with: .color(.white), lineWidth: Rose.arrowWidth)

        // The head's two corners stand a quarter turn either side of the
        // wind's way, at the neck.
        let across = toDegrees + Rose.cardinalStep
        var head = Path()
        head.move(to: tip)
        head.addLine(to: point(neck, degrees: across, distance: Rose.headHalfWidth))
        head.addLine(to: point(neck, degrees: across, distance: -Rose.headHalfWidth))
        head.closeSubpath()
        context.fill(head, with: .color(.white))
    }
}
