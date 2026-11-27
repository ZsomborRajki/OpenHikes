//
//  WeatherDaylightCard.swift
//  OpenHikes
//
//  The day's light: how much of it is left, the sun's way across the sky,
//  and the three times a walk is planned around.
//
//  *Light remaining* leads and is set large, because it is the only figure
//  here that is an answer rather than a fact: everything else is a time the
//  hiker has to subtract from themselves. The curve beside it is the same
//  answer for the eye — see ``WeatherSunPath``.
//
//  **Drawn only when there is a time to draw.** North of the Arctic Circle
//  in June there is no sunrise, no sunset and no dusk, and a heading over
//  nothing would be a worse answer than no heading — the caller asks
//  ``WeatherDaylight/hasDaylightTimes`` first.
//

import SwiftUI

struct WeatherDaylightCard: View {
    private static let arcWidth: CGFloat = 132
    private static let arcHeight: CGFloat = 64
    private static let smallestScale = 0.7

    let daylight: WeatherDaylight
    let now: Date
    let clock: WeatherForecastClock

    var body: some View {
        let path = WeatherSunPath(daylight)
        WeatherCard("Daylight", systemImage: "sun.horizon.fill") {
            VStack(spacing: 0) {
                if let remaining = daylight.remainingLight(asOf: now) {
                    WeatherBeside {
                        lightRemaining(remaining)
                    } trailing: {
                        if let path {
                            WeatherSunArc(path: path, now: now)
                                .frame(width: Self.arcWidth, height: Self.arcHeight)
                        }
                    }
                    .padding(.bottom, WeatherCardMetrics.rowPadding)
                    WeatherRule()
                } else if let path {
                    // After dark there is no light to count, and the curve
                    // has the panel's width to itself.
                    WeatherSunArc(path: path, now: now)
                        .frame(height: Self.arcHeight)
                        .padding(.bottom, WeatherCardMetrics.rowPadding)
                    WeatherRule()
                }
                WeatherRows(rows: rows)
            }
        }
    }

    private func lightRemaining(_ remaining: TimeInterval) -> some View {
        let value = WeatherReadingFormat.remainingLight(remaining)
        return VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title)
                .lineLimit(1)
                .minimumScaleFactor(Self.smallestScale)
            Text("Light remaining")
                .font(.subheadline)
                .foregroundStyle(.weatherDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Light remaining")
        .accessibilityValue(value)
        .accessibilityIdentifier("weather-detail-light-remaining")
    }

    /// The three times, each only where the reading has it.
    private var rows: [WeatherRowItem] {
        var items: [WeatherRowItem] = []
        if let sunrise = daylight.sunrise {
            items.append(WeatherRowItem(id: "weather-detail-sunrise", label: "Sunrise", value: clock.time(sunrise)))
        }
        if let sunset = daylight.sunset {
            items.append(WeatherRowItem(id: "weather-detail-sunset", label: "Sunset", value: clock.time(sunset)))
        }
        if let civilDusk = daylight.civilDusk {
            // Not sunset again: this is the light that outlasts the sun,
            // which is the light a hiker walks out by.
            items.append(
                WeatherRowItem(id: "weather-detail-light-until", label: "Light until", value: clock.time(civilDusk))
            )
        }
        return items
    }
}

/// The sun's day as a curve over a horizon, with the sun on it.
private struct WeatherSunArc: View {
    private static let sunRadius: CGFloat = 5
    private static let glowRadius: CGFloat = 9
    private static let glowOpacity = 0.35
    private static let lineWidth: CGFloat = 2.5
    private static let litOpacity = 0.95
    private static let unlitOpacity = 0.3
    private static let horizonOpacity = 0.45
    /// One point of the curve for every other point of width: a cosine has
    /// no corner a finer step would find.
    private static let step: CGFloat = 2

    let path: WeatherSunPath
    let now: Date

    var body: some View {
        Canvas { context, size in
            let amplitude = size.height / 2 - Self.glowRadius
            let middle = size.height / 2
            let horizon = middle - path.horizon * amplitude
            let curve = Self.curve(in: size, middle: middle, amplitude: amplitude)

            // The same curve twice, each through its own half of the card:
            // bright where the sun is up, faint where it is under the line.
            var lit = context
            lit.clip(to: Path(CGRect(x: 0, y: 0, width: size.width, height: horizon)))
            lit.stroke(
                curve,
                with: .color(.white.opacity(Self.litOpacity)),
                style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round)
            )
            var unlit = context
            unlit.clip(to: Path(CGRect(x: 0, y: horizon, width: size.width, height: size.height - horizon)))
            unlit.stroke(curve, with: .color(.white.opacity(Self.unlitOpacity)), lineWidth: Self.lineWidth)

            var line = Path()
            line.move(to: CGPoint(x: 0, y: horizon))
            line.addLine(to: CGPoint(x: size.width, y: horizon))
            context.stroke(line, with: .color(.white.opacity(Self.horizonOpacity)), lineWidth: 1)

            let phase = path.phase(at: now)
            let sun = CGPoint(
                x: (phase + .pi) / (2 * .pi) * size.width,
                y: middle - cos(phase) * amplitude
            )
            Self.drawSun(in: &context, at: sun, isUp: path.isUp(at: now))
        }
        .accessibilityHidden(true)
    }

    /// One turn of the cosine across the card, highest in the middle.
    private static func curve(in size: CGSize, middle: CGFloat, amplitude: CGFloat) -> Path {
        var curve = Path()
        for x in stride(from: CGFloat.zero, through: size.width, by: step) {
            let phase = x / size.width * 2 * .pi - .pi
            let point = CGPoint(x: x, y: middle - cos(phase) * amplitude)
            if x == 0 {
                curve.move(to: point)
            } else {
                curve.addLine(to: point)
            }
        }
        return curve
    }

    private static func drawSun(in context: inout GraphicsContext, at center: CGPoint, isUp: Bool) {
        let disc = { (radius: CGFloat) in
            Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
        guard isUp else {
            context.fill(disc(sunRadius), with: .color(.white.opacity(horizonOpacity)))
            return
        }
        context.fill(disc(glowRadius), with: .color(.white.opacity(glowOpacity)))
        context.fill(disc(sunRadius), with: .color(.white))
    }
}
