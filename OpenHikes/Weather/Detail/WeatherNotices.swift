//
//  WeatherNotices.swift
//  OpenHikes
//
//  What the weather sheet says about the reading rather than in it: the
//  warnings that stand over the place, at the head of the sheet, and at its
//  foot whether anybody is watching for them and how old the reading is.
//

import SwiftUI

// MARK: - Severe-weather alerts

/// The alerts that stand over this place, worst first.
///
/// **Every alert is drawn, including the ones below the interruption
/// threshold.** ``WeatherAlertPolicy/interruptionThreshold`` rations the
/// *banner*, not the information: a hiker who opened this sheet is asking,
/// and a minor advisory they asked for is worth an answer even though it was
/// not worth a notification.
///
/// The link is not a convenience. WeatherKit's terms require an alert to be
/// presented with a link to the issuing authority's own page, because the
/// summary is a headline and the page is the advice — see ``WeatherAlerts``.
/// It is the row rather than an accessory on it, so the tap target is the
/// whole width and a hiker in weather is not asked to hit an arrow.
struct WeatherAlertsCard: View {
    private static let spacing: CGFloat = 12
    /// Between an alert's headline and the authority that issued it.
    private static let lineSpacing: CGFloat = 2

    /// Worst first — see ``WeatherAlertSummary/worstFirst(_:)``.
    let alerts: [WeatherAlertSummary]

    var body: some View {
        WeatherCard("Weather Warnings", systemImage: "exclamationmark.triangle.fill") {
            VStack(spacing: 0) {
                ForEach(alerts) { alert in
                    if alert.id != alerts.first?.id {
                        WeatherRule()
                    }
                    Link(destination: alert.detailsURL) {
                        row(alert)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("weather-detail-alert")
                    // The link's own label is the summary and the source;
                    // what a screen reader cannot see is that it goes
                    // somewhere.
                    .accessibilityHint("Opens the full warning from \(alert.source)")
                }
            }
        }
    }

    private func row(_ alert: WeatherAlertSummary) -> some View {
        HStack(spacing: Self.spacing) {
            Image(systemName: alert.severity.symbolName)
                .font(.title3)
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Self.lineSpacing) {
                Text(alert.summary)
                    .font(.headline)
                Text("Issued by \(alert.source)")
                    .font(.footnote)
                    .foregroundStyle(.weatherDim)
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.weatherDim)
                .accessibilityHidden(true)
        }
        .padding(.vertical, WeatherCardMetrics.rowPadding)
        .frame(minHeight: AccessibilityMetrics.minimumTapTarget)
        .contentShape(.rect)
    }
}

// MARK: - The reading's standing

/// Whether anybody is watching for warnings here, and how old the reading
/// is, at the foot of the sheet.
///
/// **The absence of an alert is two different things**, which is the whole
/// reason its row exists. WeatherKit returns `nil` rather than an empty list
/// where it has no alerting partner, and drawing both as "None" would tell a
/// hiker in a country nobody reports from that the ridge is clear — on the
/// authority of an app that has no idea. See ``WeatherAlerts``. Nothing at
/// all is drawn for a reading restored from a build that never asked for
/// `.alerts`, nor while an alert stands: that one is at the head of the
/// sheet.
///
/// The age is the other half of the badge's dimming: the map shows only that
/// something is off, deliberately, because a timestamp over the map is
/// chrome a hiker did not ask for. The number belongs here, where they came
/// to ask.
struct WeatherStandingCard: View {
    private static let noteSpacing: CGFloat = 8

    let snapshot: WeatherSnapshot
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: Self.noteSpacing) {
            WeatherRows(rows: rows)
                .padding(.horizontal, WeatherCardMetrics.padding)
                .weatherCardSurface()

            if case .unavailable = snapshot.alerts {
                note("Apple Weather has no severe-weather source for this area.")
            }
            if snapshot.isStale(asOf: now) {
                note(
                    "OpenHikes hasn\u{2019}t been able to refresh this reading, so it\u{2019}s shown dimmed on the map."
                )
            }
        }
    }

    private var rows: [WeatherRowItem] {
        var items: [WeatherRowItem] = []
        switch snapshot.alerts {
        case .clear:
            items.append(
                WeatherRowItem(id: "weather-detail-alerts-clear", label: "Warnings", value: String(localized: "None"))
            )
        case .unavailable:
            items.append(
                WeatherRowItem(
                    id: "weather-detail-alerts-unavailable",
                    label: "Warnings",
                    value: String(localized: "Not reported here")
                )
            )
        case .active, .none:
            break
        }
        items.append(
            WeatherRowItem(
                id: "weather-detail-updated",
                label: "Updated",
                value: snapshot.capturedAt.formatted(date: .omitted, time: .shortened)
            )
        )
        items.append(WeatherRowItem(id: "weather-detail-age", label: "Age", value: snapshot.formattedAge(asOf: now)))
        return items
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.weatherDim)
            .padding(.horizontal, WeatherCardMetrics.padding)
    }
}
