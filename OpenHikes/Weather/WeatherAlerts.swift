//
//  WeatherAlerts.swift
//  OpenHikes
//
//  Severe-weather alerts: the one weather reading where being *told* matters
//  more than being able to look it up.
//
//  Unlike everything else the badge carries, this cannot be derived from
//  anything already on the device. Sunset can be worked out from a coordinate
//  and a date; a thunderstorm warning over a ridge exists only because a
//  meteorological agency issued it, and `.alerts` is the only way this app
//  can know.
//
//  ## Nobody watching is not the same as nothing to report
//
//  `.alerts` is answered per region, and WeatherKit returns **`nil`** where it
//  has no alerting partner rather than an empty list. Those two are opposite
//  facts and drawing them the same way would be the more dangerous of the two
//  mistakes: a hiker reading "No alerts" in a country nobody reports from has
//  been told the ridge is clear by an app that has no idea. So the state is
//  three-way — see ``WeatherAlerts`` — and the sheet words the two empties
//  differently.
//
//  ## The link is an obligation
//
//  `WeatherAlert.detailsURL` is not a convenience. WeatherKit's terms require
//  an alert to be presented with a link to the issuing authority's own page,
//  because the summary here is a headline and the authority's page is the
//  actual advice. It is non-optional on the framework's own type and it is
//  non-optional on ``WeatherAlertSummary`` for the same reason: an alert this
//  app cannot link is an alert this app must not draw.
//

import Foundation
import WeatherKit

/// How bad the issuing authority says it is.
///
/// This app's own spelling of `WeatherSeverity` rather than the framework's,
/// for the reason ``WeatherConditions`` is a value: it is written into the
/// stored blob and read back by a later build, so the bytes must not depend on
/// how WeatherKit happens to encode its own enum.
///
/// `unknown` is a real answer rather than a parse failure — an agency may
/// issue an advisory without grading it — and it deliberately sorts as the
/// *least* severe, because an ungraded notice is not evidence of danger.
nonisolated enum WeatherAlertSeverity: String, Codable, Comparable, Sendable {
    // Declared alphabetically because the linter sorts them; the ordering
    // that matters is ``rank`` below, which is what ``Comparable`` reads and
    // is deliberately not this order.
    case extreme = "extreme"
    case minor = "minor"
    case moderate = "moderate"
    case severe = "severe"
    case unknown = "unknown"

    /// Ascending, so `>` reads as "worse than".
    private var rank: Int {
        switch self {
        case .unknown: 0
        case .minor: 1
        case .moderate: 2
        case .severe: 3
        case .extreme: 4
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

    /// The SF Symbol the sheet draws beside one.
    var symbolName: String {
        switch self {
        case .extreme, .severe: "exclamationmark.triangle.fill"
        case .moderate: "exclamationmark.circle.fill"
        case .minor, .unknown: "info.circle.fill"
        }
    }
}

/// One alert, as this app holds it.
///
/// A value with no framework in it, like every other type in this folder: it
/// crosses actors, it is restored from a stored blob as readily as from a
/// response, and a suite can build one without an entitlement — which matters
/// more here than anywhere else in the feature, because `WeatherAlert` is a
/// framework type a test cannot construct at all.
nonisolated struct WeatherAlertSummary: Codable, Equatable, Identifiable, Sendable {
    /// The issuing authority's own identifier for this alert.
    ///
    /// Load-bearing rather than bookkeeping: it is what
    /// ``WeatherAlertWatch`` remembers so that a hiker is interrupted once per
    /// alert rather than once per weather poll. WeatherKit re-serves the same
    /// alert on every request for as long as it stands, which for a storm
    /// warning is hours.
    var id: String
    /// The headline, which is all the summary WeatherKit carries.
    var summary: String
    var severity: WeatherAlertSeverity
    /// The issuing authority's own page. See this file's header — an alert
    /// without one is not drawn.
    var detailsURL: URL
    /// Who issued it, for the sheet to attribute the warning to somebody.
    var source: String
    /// When it stops applying, where the authority said. `nil` for an alert
    /// left open-ended, which is ordinary for a standing advisory.
    var expires: Date?
}

/// What `.alerts` said about a place.
///
/// Three cases rather than an array, because an empty array cannot tell the
/// two empties apart — see this file's header, which is the whole reason this
/// type exists instead of `[WeatherAlertSummary]`.
nonisolated enum WeatherAlerts: Equatable, Sendable {
    /// At least one alert stands. Never empty — an empty response is
    /// ``clear`` — which ``init(_:)`` is what guarantees.
    case active([WeatherAlertSummary])
    /// Somebody is watching this place and has nothing to report.
    case clear
    /// WeatherKit has no alerting partner for this place, so nothing is being
    /// watched. Not a failure, and not good news.
    case unavailable

    /// The alerts, or none. For a caller that only wants to draw them.
    var summaries: [WeatherAlertSummary] {
        guard case .active(let summaries) = self else { return [] }
        return summaries
    }

    /// The worst thing standing, or `nil` when nothing is.
    ///
    /// What the badge would ask if it ever draws one, and what the watch asks
    /// to decide whether an interruption is warranted.
    var mostSevere: WeatherAlertSummary? {
        summaries.max { $0.severity < $1.severity }
    }
}

extension WeatherAlerts {
    /// The one place WeatherKit's alert shape is read.
    ///
    /// `nonisolated` for the reason ``WeatherConditions``' own mapping is: the
    /// caller is a nonisolated initializer on a value that has to cross
    /// actors.
    ///
    /// - Parameter alerts: exactly what `weather(for:including:.alerts)`
    ///   returned, `nil` and all. The `nil` is the fact this type exists to
    ///   carry and is not defaulted away here.
    ///
    /// The linter would rather this took an empty array than an optional one,
    /// and that is the one shape it must not take: an empty array and a `nil`
    /// are the two facts this whole file exists to keep apart, so collapsing
    /// them at the boundary would delete the distinction before anything could
    /// read it.
    nonisolated init(_ alerts: [WeatherAlert]?) { // swiftlint:disable:this discouraged_optional_collection
        guard let alerts else {
            self = .unavailable
            return
        }
        let summaries = alerts.map(WeatherAlertSummary.init)
        // An empty list from a region that *does* report is the good news, and
        // it is the only place `clear` comes from.
        self = summaries.isEmpty ? .clear : .active(summaries)
    }
}

extension WeatherAlertSummary {
    nonisolated init(_ alert: WeatherAlert) {
        self.init(
            id: alert.summary + alert.detailsURL.absoluteString,
            summary: alert.summary,
            severity: WeatherAlertSeverity(alert.severity),
            detailsURL: alert.detailsURL,
            source: alert.source,
            expires: alert.metadata.expirationDate
        )
    }
}

extension WeatherAlertSeverity {
    /// WeatherKit's grading, in this app's own spelling.
    ///
    /// The `@unknown default` is the point of writing it out: `WeatherSeverity`
    /// is a framework enum that has gained cases before, and with warnings as
    /// errors a non-exhaustive switch fails the build. A grade this build does
    /// not recognise reads as ``unknown``, which is the honest answer and the
    /// one that will not have an ungraded notice interrupting a walk.
    nonisolated init(_ severity: WeatherSeverity) {
        switch severity {
        case .extreme: self = .extreme
        case .severe: self = .severe
        case .moderate: self = .moderate
        case .minor: self = .minor
        case .unknown: self = .unknown
        @unknown default: self = .unknown
        }
    }
}
