//
//  WeatherConditions.swift
//  OpenHikes
//
//  The rest of the reading — everything WeatherKit already sent that the badge
//  has no room for.
//
//  This is not a second request. `WeatherService.weather(for:including:.current)`
//  answers with a `CurrentWeather` carrying a dozen measurements, and until now
//  the app read three of them and dropped the rest on the floor. The detail
//  sheet is where somebody goes to ask about the number over the map, and it
//  had nothing more to say than the badge did; these are the fields that were
//  already paid for.
//
//  ## Why these are their own types
//
//  ``WeatherSnapshot`` exists so that nothing — a preview, a test, a UI
//  automation launch — needs WeatherKit to stand a reading up, because
//  `CurrentWeather` has no public initializer. Folding nine more WeatherKit
//  values into it would have given that away, so each one is re-expressed here
//  in Foundation's own `Measurement` types and the mapping lives in the one
//  file that already speaks WeatherKit. ``WeatherUVCategory`` is the same
//  argument in the small: `UVIndex.ExposureCategory` is a WeatherKit type, and
//  a five-case enum is a cheaper thing to own than an import.
//
//  ## Units are the caller's, not the provider's
//
//  Every field here is held in whatever unit WeatherKit handed over and
//  converted on the way to the screen, which is the rule ``WeatherReadingFormat``
//  already kept for the temperature. The one that needs saying is
//  ``WeatherConditions/precipitationIntensity``: WeatherKit reports it as a
//  *speed* in millimetres per hour, which `usage: .general` would happily
//  render as "0.0 mph". It is a depth per hour rather than a velocity, so it
//  is carried as a `UnitLength` and spelled with the hour at the call site.
//

import Foundation

/// Where the wind is coming from and how hard.
nonisolated struct WeatherWind: Equatable, Sendable {
    var speed: Measurement<UnitSpeed>
    /// The direction the wind blows *from*, which is the convention every
    /// forecast uses and the one a hiker reading "NW" expects.
    var direction: Measurement<UnitAngle>
    /// `nil` when the provider reports no gust above the sustained speed.
    ///
    /// Optional because the fact is, rather than for anybody's convenience: a
    /// still day has a wind speed and no gust, and a row reading "gusting to
    /// 0 km/h" would be inventing weather.
    var gust: Measurement<UnitSpeed>?
}

/// How much ultraviolet there is, in the World Health Organization's bands.
///
/// Carried alongside the number rather than derived from it. The bands are
/// stable and deriving them would be easy, but the provider is the authority
/// on its own index and a local re-derivation is a second opinion that can
/// only ever disagree.
///
/// The cases are alphabetical rather than in order of severity, which
/// `sorted_enum_cases` requires and nothing here minds: no code compares two
/// of these, and the number beside the band carries the ordering a reader
/// needs.
///
/// The raw values are written out rather than left to the case names, and
/// that is a storage contract rather than a lint: one of these is spelled into
/// the reading ``WeatherReadingStore`` keeps, so renaming a case has to be a
/// decision about a stored blob rather than a rename.
nonisolated enum WeatherUVCategory: String, Codable, Equatable, Sendable, CaseIterable {
    case extreme = "extreme"
    case high = "high"
    case low = "low"
    case moderate = "moderate"
    case veryHigh = "veryHigh"

    /// What the row says beside the number.
    var label: String {
        switch self {
        case .low: String(localized: "Low")
        case .moderate: String(localized: "Moderate")
        case .high: String(localized: "High")
        case .veryHigh: String(localized: "Very High")
        case .extreme: String(localized: "Extreme")
        }
    }
}

nonisolated struct WeatherUVIndex: Equatable, Sendable {
    var value: Int
    var category: WeatherUVCategory
}

/// Everything in the reading that is not the symbol, the temperature or the
/// sentence.
///
/// One struct rather than nine properties on ``WeatherSnapshot`` for a reason
/// that is not tidiness: `function_parameter_count` is an error-severity lint
/// at nine, and a snapshot holding all of these inline would need a
/// thirteen-parameter initializer. Declaring `init(_ weather:)` on the
/// snapshot suppresses the memberwise one, so that initializer has to be
/// written out. Grouping is what keeps both of them inside the limit — and it
/// also gives the sheet one value to be handed rather than nine.
nonisolated struct WeatherConditions: Equatable, Sendable {
    /// What it feels like, which is the number a hiker dresses for when it
    /// disagrees with the temperature.
    var apparentTemperature: Measurement<UnitTemperature>
    var dewPoint: Measurement<UnitTemperature>
    /// Relative humidity, 0...1.
    var humidity: Double
    /// 0...1.
    var cloudCover: Double
    var pressure: Measurement<UnitPressure>
    var uvIndex: WeatherUVIndex
    var visibility: Measurement<UnitLength>
    /// Depth per hour — see this file's header for why it is a length and not
    /// the speed WeatherKit calls it.
    var precipitationIntensity: Measurement<UnitLength>
    var wind: WeatherWind
}

#if DEBUG
extension WeatherConditions {
    /// One filled-in reading, for previews, the `--ui-test-weather` fixture
    /// and any suite that needs a snapshot without caring what is in it.
    ///
    /// `#if DEBUG` rather than a default on the initializer. A default would
    /// be a shipping value that exists for the convenience of callers who do
    /// not have one, and every shipping caller does: a reading comes from a
    /// `CurrentWeather` or from the stored blob, both of which carry all nine.
    ///
    /// Every field differs from every other in a way that is recognisable on
    /// screen, so a row wired to the wrong measurement shows it rather than
    /// rendering a plausible number.
    /// The fixture's numbers, named so the linter can tell a reading from an
    /// arithmetic constant. A mild ceremony for a preview, and it does buy one
    /// thing: the names say which row each number is meant to land in.
    private enum Preview {
        static let apparentCelsius: Double = 10
        static let dewPointCelsius: Double = 7
        static let humidity = 0.72
        static let cloudCover = 0.45
        static let pressureHectopascals: Double = 1013
        static let uvIndex = 3
        static let visibilityKilometres: Double = 10
        static let precipitationMillimetres: Double = 0
        static let windKilometresPerHour: Double = 14
        /// North-west: the one compass point whose abbreviation cannot be
        /// confused with a mis-indexed neighbour on either side.
        static let windFromDegrees: Double = 315
        static let gustKilometresPerHour: Double = 22
    }

    static let preview = Self(
        apparentTemperature: Measurement(value: Preview.apparentCelsius, unit: .celsius),
        dewPoint: Measurement(value: Preview.dewPointCelsius, unit: .celsius),
        humidity: Preview.humidity,
        cloudCover: Preview.cloudCover,
        pressure: Measurement(value: Preview.pressureHectopascals, unit: .hectopascals),
        uvIndex: WeatherUVIndex(value: Preview.uvIndex, category: .moderate),
        visibility: Measurement(value: Preview.visibilityKilometres, unit: .kilometers),
        precipitationIntensity: Measurement(
            value: Preview.precipitationMillimetres,
            unit: .millimeters
        ),
        wind: WeatherWind(
            speed: Measurement(value: Preview.windKilometresPerHour, unit: .kilometersPerHour),
            direction: Measurement(value: Preview.windFromDegrees, unit: .degrees),
            gust: Measurement(value: Preview.gustKilometresPerHour, unit: .kilometersPerHour)
        )
    )
}
#endif
