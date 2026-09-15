//
//  WeatherDetailSheet.swift
//  OpenHikes
//
//  What the weather badge opens: the conditions in full, how old the reading
//  is, and Apple Weather's credits.
//
//  "In full" is meant literally and was not true before. One request for
//  `.current` answers with a dozen measurements, and this screen drew three of
//  them — the same three the badge draws — so a hiker who tapped the badge to
//  ask a question was shown the thing they had just tapped, larger. Everything
//  in ``WeatherConditions`` was already fetched, already paid for and already
//  in memory; the rows below are that, and no second request.
//
//  Where this is attached matters more than what it draws. `OpenHikesView`
//  keeps ``MapSheet`` presented permanently and puts it back if it is ever
//  dismissed, and a view can only have one modal presented at a time — so a
//  `.sheet` attached to the badge, or to the map, or anywhere else in the root
//  hierarchy, is never presented at all. No error, no sheet, just a control
//  that does nothing. ``weatherDetailSheet(_:weather:)`` is attached to the
//  sheet's *content* instead, beside `.photoCapturePickers`, and layers above
//  it the same way the Settings sheet does.
//
//  That splits the tap from the presentation, which is what
//  ``WeatherDetailPresentation`` is for: the badge is over the map and the
//  sheet is inside the bottom sheet, so the flag has to be reachable from both
//  without either becoming an input of the root view's body.
//

import SwiftUI

/// Whether the weather detail sheet is up.
///
/// A reference type held in `@State` rather than a `@State` `Bool`, for the
/// reason ``SheetPresentation`` is one: `@State` invalidates the view that
/// declares it whether or not its body reads it, and the view that would have
/// declared it is the one drawing the map. The reference never changes, so
/// opening the sheet costs the root view nothing.
@Observable
final class WeatherDetailPresentation {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    private(set) var isPresented = false

    /// Drives `.sheet(isPresented:)`. A binding rather than the property
    /// itself because building one reads nothing: the presentation calls the
    /// getter during its own update, which registers the dependency there and
    /// not on whichever body happened to construct it.
    var isPresentedBinding: Binding<Bool> {
        Binding(get: { self.isPresented }, set: { self.isPresented = $0 })
    }

    func present() {
        isPresented = true
    }
}

extension View {
    /// Attaches the weather detail sheet to the view it can actually be
    /// presented from — the sheet's content, not the view that presents the
    /// sheet.
    func weatherDetailSheet(
        _ presentation: WeatherDetailPresentation,
        weather: WeatherManager
    ) -> some View {
        modifier(WeatherDetailSheetModifier(presentation: presentation, weather: weather))
    }
}

private struct WeatherDetailSheetModifier: ViewModifier {
    let presentation: WeatherDetailPresentation
    let weather: WeatherManager

    func body(content: Content) -> some View {
        content.sheet(isPresented: presentation.isPresentedBinding) {
            WeatherDetailView(weather: weather)
                // Small, but not fixed: at an accessibility text size the
                // credits and the legal link stop fitting a half sheet, and a
                // legal notice that cannot be read has not been given.
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

struct WeatherDetailView: View {
    private static let markHeight: CGFloat = 18
    private static let headerSpacing: CGFloat = 12

    let weather: WeatherManager

    @Environment(\.colorScheme)
    private var colorScheme

    /// `nil` until WeatherKit answers, and for good if it never does. The
    /// wording and the fallback link below do not wait on it — see
    /// ``AppleWeatherAttribution/marks(from:)``.
    @State private var marks: WeatherAttributionMarks?

    var body: some View {
        NavigationStack {
            List {
                if let snapshot = weather.current {
                    conditionsSection(snapshot)
                    readingsSection(snapshot.conditions)
                    freshnessSection(snapshot)
                } else if case .unavailable = weather.state {
                    unavailableSection
                }
                attributionSection
            }
            // The place the reading is about when there is one, and the
            // generic word only when it is simply here. `Text` rather than
            // `placeName ?? "Weather"`, which types the whole expression as
            // `String` and so takes the non-localized overload — quietly
            // costing the fallback its `LocalizedStringKey` in order to offer
            // a city name a translation it was never going to be given.
            .navigationTitle(placeName.map { Text(verbatim: $0) } ?? Text("Weather"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    DismissButton()
                        .accessibilityIdentifier("weather-detail-done")
                }
            }
        }
        .task { marks = await AppleWeatherAttribution.marks() }
    }

    /// Which place the reading is for, or `nil` when it is simply here.
    ///
    /// The badge can now be pointed at a searched city or a selected trail, so
    /// "Current conditions" on its own is no longer always true — see
    /// ``WeatherSubject``.
    private var placeName: String? {
        weather.state.subject?.placeName
    }

    private func conditionsSection(_ snapshot: WeatherSnapshot) -> some View {
        Section {
            HStack(spacing: Self.headerSpacing) {
                Image(systemName: snapshot.symbolName)
                    .symbolRenderingMode(.multicolor)
                    .font(.largeTitle)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.formattedTemperature())
                        .font(.title.weight(.semibold))
                    Text(snapshot.conditionDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            // A glyph, a number and a phrase that are one fact — the same
            // shape ``StatTile`` and ``DetailRow`` take.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(placeName.map { "Conditions in \($0)" } ?? "Current conditions")
            .accessibilityValue("\(snapshot.spokenTemperature()), \(snapshot.conditionDescription)")
            .accessibilityIdentifier("weather-detail-conditions")
        }
    }

    /// The rest of the reading, one row each.
    ///
    /// ``DetailRow`` rather than a grid or a set of tiles, because that is what
    /// this app already uses for a label and a value in a `List` — and what a
    /// reader hears as one element rather than two.
    ///
    /// No identifier on the `Section`, deliberately. SwiftUI pushes a
    /// container's identifier down onto every descendant, so one here would
    /// both smother the rows underneath it and make nine rows answer to one
    /// name — the reason the surface and difficulty sections carry theirs on
    /// the bar alone.
    ///
    /// The order is not arbitrary and is worth keeping. It runs from what a
    /// hiker acts on soonest to what they act on least: how cold it will feel,
    /// what the wind will do to that, then the two that decide whether to
    /// carry water and a hat, then what can be seen, and finally the three
    /// that are context rather than instruction.
    private func readingsSection(_ conditions: WeatherConditions) -> some View {
        Section {
            DetailRow(
                label: "Feels like",
                value: WeatherReadingFormat.temperature(
                    conditions.apparentTemperature,
                    width: .narrow
                )
            )
            DetailRow(label: "Wind", value: Self.wind(conditions.wind))
                .accessibilityIdentifier("weather-detail-wind")
            DetailRow(
                label: "Humidity",
                value: WeatherReadingFormat.percentage(conditions.humidity)
            )
            DetailRow(
                label: "UV index",
                value: WeatherReadingFormat.uvIndex(conditions.uvIndex)
            )
            DetailRow(
                label: "Visibility",
                value: WeatherReadingFormat.visibility(conditions.visibility)
            )
            DetailRow(
                label: "Pressure",
                value: WeatherReadingFormat.pressure(conditions.pressure)
            )
            DetailRow(
                label: "Dew point",
                value: WeatherReadingFormat.temperature(conditions.dewPoint, width: .narrow)
            )
            DetailRow(
                label: "Cloud cover",
                value: WeatherReadingFormat.percentage(conditions.cloudCover)
            )
            DetailRow(
                label: "Precipitation",
                value: WeatherReadingFormat.precipitation(conditions.precipitationIntensity)
            )
        } header: {
            Text("Conditions")
        }
    }

    /// Speed, the way it came from, and the gust when there is one.
    ///
    /// One row rather than three, because wind is one fact: a speed with no
    /// direction is half an answer, and a gust on a line of its own reads as a
    /// separate wind. The gust is left out entirely when the provider reports
    /// none — see ``WeatherWind/gust``.
    private static func wind(_ wind: WeatherWind) -> String {
        let speed = WeatherReadingFormat.windSpeed(wind.speed)
        let described = WeatherReadingFormat.windDirection(wind.direction).map { direction in
            String(localized: "\(speed) \(direction)", comment: "A wind speed and its compass direction")
        } ?? speed
        guard let gust = wind.gust else { return described }
        return String(
            localized: "\(described), gusting \(WeatherReadingFormat.windSpeed(gust))",
            comment: "A wind speed and direction, followed by the gust speed"
        )
    }

    /// Why there is no reading.
    ///
    /// The badge says only that something is off — a slashed cloud over the
    /// map is as much as belongs there. This is where someone who tapped it to
    /// ask gets a sentence, and it exists because the alternative, which is
    /// what shipped before, was a badge that never appeared and no way at all
    /// to find out why.
    private var unavailableSection: some View {
        Section {
            Label(
                placeName.map { "No forecast for \($0)" } ?? "No forecast available",
                systemImage: "cloud.slash"
            )
                .accessibilityIdentifier("weather-detail-unavailable")
        } footer: {
            Text(
                "OpenHikes couldn\u{2019}t reach Apple Weather. It will try again automatically."
            )
        }
    }

    /// How old the reading is, exactly.
    ///
    /// This is the other half of the badge's dimming: the map shows only that
    /// something is off, deliberately, because a timestamp over the map is
    /// chrome a hiker did not ask for. The number belongs here, where they
    /// came to ask.
    private func freshnessSection(_ snapshot: WeatherSnapshot) -> some View {
        Section {
            DetailRow(
                label: "Updated",
                value: snapshot.capturedAt.formatted(date: .omitted, time: .shortened)
            )
            DetailRow(label: "Age", value: snapshot.formattedAge())
                .accessibilityIdentifier("weather-detail-age")
        } footer: {
            if snapshot.isStale() {
                Text(
                    "OpenHikes hasn\u{2019}t been able to refresh this reading, "
                        + "so it\u{2019}s shown dimmed on the map."
                )
            }
        }
    }

    /// Apple Weather's credits, which the WeatherKit terms require on the
    /// screen presenting its data.
    ///
    /// Every branch here still shows the words "Apple Weather" and still
    /// offers the legal link. The mark is an improvement on that floor, not a
    /// precondition for it: it arrives over the network from a service that
    /// has just failed to deliver a forecast often enough that treating it as
    /// reliable would mean shipping a sheet that is sometimes blank.
    private var attributionSection: some View {
        Section {
            if let marks {
                AsyncImage(url: marks.markURL(inDarkMode: colorScheme == .dark)) { image in
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: Self.markHeight)
                } placeholder: {
                    // Deliberately nothing: the wording below already carries
                    // the attribution, so a spinner here would only advertise
                    // that something is missing.
                    EmptyView()
                }
                // The mark says "Apple Weather" and so does the line beneath
                // it; announcing both would read the credit out twice.
                .accessibilityHidden(true)
            }

            Text("Weather data provided by \(AppleWeatherAttribution.serviceName)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("weather-attribution")

            Link(
                marks?.linkTitle ?? WeatherAttributionMarks.defaultLinkTitle,
                destination: marks?.legalPageURL ?? AppleWeatherAttribution.fallbackLegalPageURL
            )
                .font(.footnote)
                .accessibilityIdentifier("weather-legal-link")
        } header: {
            Text("Data Source")
        }
    }
}

#Preview("Weather detail") {
    let manager = WeatherManager()
    return WeatherDetailView(weather: manager)
}
