//
//  WeatherSky.swift
//  OpenHikes
//
//  The sky the weather sheet is drawn on.
//
//  The sheet's symbols are Apple's multicolor weather glyphs, and those are
//  drawn for a sky: their clouds are white. On the system's light background
//  a "partly cloudy" glyph was a sun beside nothing at all. So the sheet has a
//  backdrop of its own, as Apple's Weather has, and everything on it is drawn
//  light on dark at every hour and in both appearances.
//
//  ## Read off the symbol, not stored
//
//  A reading keeps its condition as the SF Symbol WeatherKit names for it and
//  a sentence, and nothing else: ``WeatherSnapshot`` has no condition code.
//  Adding one would be a new field in the blob ``WeatherReadingStore`` keeps,
//  for a backdrop. The symbol already says what the backdrop needs. Its name
//  is dot-separated words from a small vocabulary (`cloud.sun.rain.fill`),
//  and the words are what is read here, so a variant this file has never seen
//  (`.circle`, a new modifier) still lands on the sky its words describe.
//
//  A name with none of the words is drawn as a clear sky. That is a color,
//  not a claim: the glyph and the sentence beside it still say what the
//  weather is.
//
//  ## Day or night
//
//  WeatherKit names the sun or the moon in the symbol wherever either can be
//  seen, and that word wins. Under cloud the symbol says neither, so the
//  reading's own sunrise and sunset decide, and with no daylight at all it is
//  day. The instants are compared as instants, so no time zone is asked.
//

import Foundation

nonisolated struct WeatherSky: Equatable, Hashable, Sendable {
    /// What is overhead, as far as a backdrop tells one sky from another.
    enum Cover: CaseIterable, Sendable {
        case clear
        case fog
        case overcast
        case partlyCloudy
        case rain
        case snow
        case storm
    }

    var cover: Cover
    var isDaylight: Bool
}

nonisolated extension WeatherSky {
    /// The backdrop of a sheet with no reading on it: no forecast came, so
    /// no sky is claimed.
    static let unknown = Self(cover: .overcast, isDaylight: true)

    /// The sky over a reading.
    init(_ snapshot: WeatherSnapshot, asOf date: Date = .now) {
        self.init(symbolName: snapshot.symbolName, daylight: snapshot.daylight, asOf: date)
    }

    init(symbolName: String, daylight: WeatherDaylight?, asOf date: Date) {
        let words = Set(symbolName.split(separator: ".").map(String.init))
        self.init(
            cover: Self.cover(saidBy: words),
            isDaylight: Self.sunIsUp(saidBy: words, daylight: daylight, asOf: date)
        )
    }

    /// Worst first: a thunderstorm's symbol names its rain and its cloud too.
    private static func cover(saidBy words: Set<String>) -> Cover {
        if !words.isDisjoint(with: Words.storm) { return .storm }
        if !words.isDisjoint(with: Words.snow) { return .snow }
        if !words.isDisjoint(with: Words.rain) { return .rain }
        if !words.isDisjoint(with: Words.fog) { return .fog }
        if words.contains(Words.cloud) {
            return words.isDisjoint(with: Words.sunOrMoon) ? .overcast : .partlyCloudy
        }
        return words.contains(Words.wind) ? .overcast : .clear
    }

    private static func sunIsUp(
        saidBy words: Set<String>,
        daylight: WeatherDaylight?,
        asOf date: Date
    ) -> Bool {
        if words.contains(Words.moon) { return false }
        if words.contains(Words.sun) { return true }
        guard let sunrise = daylight?.sunrise, let sunset = daylight?.sunset else { return true }
        return sunrise <= date && date < sunset
    }

    /// The words of WeatherKit's symbol names that say something about the
    /// sky. Apple's vocabulary, not ours.
    private enum Words {
        static let cloud = "cloud"
        static let moon = "moon"
        static let sun = "sun"
        static let wind = "wind"
        static let sunOrMoon: Set<String> = [sun, moon]
        static let storm: Set<String> = ["bolt", "tornado", "hurricane", "tropicalstorm"]
        static let snow: Set<String> = ["snow", "snowflake", "sleet", "hail"]
        static let rain: Set<String> = ["rain", "drizzle", "heavyrain"]
        static let fog: Set<String> = ["fog", "haze", "smoke", "dust"]
    }
}

// MARK: - Its colors

nonisolated extension WeatherSky {
    /// The backdrop's two colors, as `#RRGGBB`.
    struct Backdrop: Equatable, Sendable {
        /// At the top of the sheet, behind the temperature.
        var zenith: String
        /// At the foot of the sheet.
        var horizon: String
    }

    /// The colors of this sky, deeper overhead than at the horizon.
    ///
    /// **Every one of them is dark enough for white text**, the lightest
    /// included, and ``WeatherSkyTests`` holds each to that: the sheet draws
    /// its temperature straight on the backdrop, with no card behind it.
    /// That is why a snowy noon here is a slate blue, not the near-white a
    /// snowy noon is.
    var backdrop: Backdrop {
        switch (cover, isDaylight) {
        case (.clear, true): Backdrop(zenith: "#1E5FAE", horizon: "#4A90D6")
        case (.partlyCloudy, true): Backdrop(zenith: "#3A6EA8", horizon: "#6393C2")
        case (.overcast, true): Backdrop(zenith: "#4D6278", horizon: "#7A8DA0")
        case (.rain, true): Backdrop(zenith: "#3C4E63", horizon: "#63778C")
        case (.storm, true): Backdrop(zenith: "#3A435E", horizon: "#566078")
        case (.snow, true): Backdrop(zenith: "#5E738C", horizon: "#7C92A9")
        case (.fog, true): Backdrop(zenith: "#59636E", horizon: "#848D97")
        case (.clear, false): Backdrop(zenith: "#070B1E", horizon: "#232C55")
        case (.partlyCloudy, false): Backdrop(zenith: "#0E1428", horizon: "#2C3552")
        case (.overcast, false): Backdrop(zenith: "#161B26", horizon: "#353D4B")
        case (.rain, false): Backdrop(zenith: "#11161F", horizon: "#2D3541")
        case (.storm, false): Backdrop(zenith: "#0D0F18", horizon: "#2A2C3D")
        case (.snow, false): Backdrop(zenith: "#1B2433", horizon: "#414C5E")
        case (.fog, false): Backdrop(zenith: "#1C2026", horizon: "#40454D")
        }
    }
}

// MARK: - Its panels

nonisolated extension WeatherSky {
    /// What is laid over the backdrop to make a panel: a color, as
    /// `#RRGGBB`, and how much of it.
    struct Panel: Equatable, Sendable {
        var tint: String
        var opacity: Double
    }

    private static let dayOpacity = 0.3
    private static let nightOpacity = 0.08
    private static let dayPanel = Panel(tint: "#0D1A38", opacity: dayOpacity)
    private static let nightPanel = Panel(tint: "#FFFFFF", opacity: nightOpacity)

    /// The fill of the sheet's panels on this sky.
    ///
    /// A panel has to stand apart from the sky and still carry small white
    /// text, and the two halves of the day ask opposite things of it. A day
    /// sky is bright, so its panels are a deep blue laid over it, which
    /// darkens it. A night sky is nearly black already, and darkening it
    /// would lose the panel in it, so a night's panels are lit instead.
    /// ``WeatherSkyTests`` holds every sky to both.
    var panel: Panel {
        isDaylight ? Self.dayPanel : Self.nightPanel
    }
}
