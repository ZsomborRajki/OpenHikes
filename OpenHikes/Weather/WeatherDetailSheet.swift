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

import OpenHikesData
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
    // periphery:ignore - read only as `$detent`, the binding
    // `.presentationDetents(_:selection:)` takes.
    /// Which detent the sheet opens at, rather than which ones it offers.
    ///
    /// SwiftUI opens at the smallest detent in the set unless it is given a
    /// selection, and the smallest one stopped being enough when the hourly
    /// strip arrived: a half sheet then held the conditions the badge already
    /// showed, the next twelve hours, and none of the rows underneath — which
    /// is the screen this file's header says was the problem in the first
    /// place. So it opens whole and can still be dragged down; `.medium` stays
    /// in the set because the sheet is dismissible by drag from it and because
    /// a hiker who only wanted the hours can have the map back.
    @State private var detent: PresentationDetent = .large

    func body(content: Content) -> some View {
        content.sheet(isPresented: presentation.isPresentedBinding) {
            WeatherDetailView(weather: weather)
                // Both, not one: at an accessibility text size the credits and
                // the legal link stop fitting a half sheet, and a legal notice
                // that cannot be read has not been given.
                .presentationDetents([.medium, .large], selection: $detent)
                .presentationDragIndicator(.visible)
        }
    }
}

struct WeatherDetailView: View {
    private static let markHeight: CGFloat = 18
    private static let headerSpacing: CGFloat = 12
    /// Between an alert's headline and the authority that issued it.
    private static let alertRowSpacing: CGFloat = 2
    /// The hourly strip's own measurements, named rather than spelled inline
    /// for the reason every other constant in this file is.
    private enum HourStrip {
        static let columnSpacing: CGFloat = 18
        static let columnWidth: CGFloat = 44
        static let rowSpacing: CGFloat = 6
    }

    /// Below this the chance of rain is not worth drawing: it rounds to
    /// nothing, and a "0%" against every dry hour and every dry day is noise
    /// where the point of both strips is to make the wet one visible.
    ///
    /// One threshold rather than two, because it is one editorial decision —
    /// and two would be a pair of numbers that agree until somebody changes
    /// the wrong one.
    private static let precipitationFloor = 0.05

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
                    // First of all, above even an alert: the credits Apple
                    // requires beside its data, where a hiker — and App
                    // Review — sees them the moment the sheet opens. See
                    // ``WeatherAttributionBanner``.
                    WeatherAttributionBanner(marks: marks)
                    // **Above the reading, which is the one section that
                    // earns it.** Everything below this is what the weather
                    // is doing; this is a meteorological agency telling the
                    // hiker to reconsider the walk, and a storm warning under
                    // the humidity row would be the sheet ranking it by how
                    // easy it was to lay out. It costs nothing in the ordinary
                    // case: it draws only for an alert that actually stands,
                    // so the fold that #425 and the daylight section were
                    // fought over is unmoved on every reading that has none.
                    alertsSection(snapshot.alerts)
                    conditionsSection(snapshot)
                    hourlySection(snapshot.hourly)
                    readingsSection(snapshot.conditions)
                    // After the readings rather than above them, and that is
                    // not a preference. Above, it pushed the wind row past the
                    // fold of a sheet at its middle detent — and `List` builds
                    // rows lazily, so past the fold is absent from the element
                    // tree, which is what `testTheWeatherBadgeOpensTheWhole`
                    // `Reading` caught. Wind is the row #425 was filed about;
                    // moving a section in above it is not a free change.
                    //
                    // It also reads better here. Everything above is a
                    // statement about *now*, which is what a reading is; this
                    // is a statement about the day, and so is the freshness
                    // section below it.
                    daylightSection(snapshot.daylight)
                    daysSection(snapshot.days)
                    // The *absence* of an alert, which is a footnote rather
                    // than news and so sits here rather than at the top.
                    alertStatusSection(snapshot.alerts)
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
        // Separate from the credits' task rather than sequenced behind it:
        // the two are independent round trips, and a title should not wait on
        // Apple Weather's legal marks to appear. See
        // ``WeatherManager/resolveCityName()`` for why the lookup happens on
        // the sheet opening rather than when the subject changes.
        .task { await weather.resolveCityName() }
    }

    /// Which place the reading is for, or `nil` when it is simply here.
    ///
    /// The badge can now be pointed at a searched city or a selected trail, so
    /// "Current conditions" on its own is no longer always true — see
    /// ``WeatherSubject``.
    ///
    /// **The geocoded city first, and the subject's own name only as a
    /// fallback.** For a selected route the subject's name is the *hike's*
    /// title, which names the thing the hiker tapped rather than the place the
    /// forecast describes — see ``WeatherPlaceNaming``. The fallback is what
    /// stands when there is no city to be had: no network, no namer on this
    /// launch, or an anchor out on open hillside that belongs to no
    /// settlement. Falling back to the hike's name rather than to *Weather* is
    /// deliberate; it is the behaviour this screen already had, and losing the
    /// title altogether would be a worse answer than an imprecise one.
    private var placeName: String? {
        weather.cityName ?? weather.state.subject?.placeName
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
            // shape ``StatRow`` and ``DetailRow`` take.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(placeName.map { "Conditions in \($0)" } ?? "Current conditions")
            .accessibilityValue("\(snapshot.spokenTemperature()), \(snapshot.conditionDescription)")
            .accessibilityIdentifier("weather-detail-conditions")
        }
    }

    /// The next few hours, which is the half of the reading a hiker at a
    /// trailhead is actually deciding on — see ``WeatherHourSummary``.
    ///
    /// Drawn above the readings because it answers the sooner question, and
    /// `@ViewBuilder` rather than `some View` so an empty strip costs a
    /// section rather than an empty one: a reading restored from a blob
    /// written before this existed, and a provider with no hourly data for the
    /// point, both arrive here as `[]`.
    ///
    /// One accessibility element per hour rather than per glyph, the same
    /// shape ``conditionsSection(_:)`` takes: a time, a sky and a temperature
    /// are one fact about one hour.
    @ViewBuilder
    private func hourlySection(_ hours: [WeatherHourSummary]) -> some View {
        if !hours.isEmpty {
            Section("Next hours") {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: Self.HourStrip.columnSpacing) {
                        ForEach(hours) { hour in
                            hourColumn(hour)
                        }
                    }
                    .padding(.vertical, Self.HourStrip.rowSpacing)
                }
                .scrollIndicators(.hidden)
                .accessibilityIdentifier("weather-detail-hourly")
            }
        }
    }

    private func hourColumn(_ hour: WeatherHourSummary) -> some View {
        VStack(spacing: Self.HourStrip.rowSpacing) {
            Text(hour.date, format: .dateTime.hour())
                .font(.caption)
                .foregroundStyle(.secondary)
            Image(systemName: hour.symbolName)
                .symbolRenderingMode(.multicolor)
                .font(.title3)
            Text(
                WeatherReadingFormat.temperature(hour.temperature, width: .narrow)
            )
            .font(.subheadline.weight(.medium))
            // Drawn only where there is something to say, and reserved
            // either way so the glyphs above stay on one line across the
            // strip — see ``precipitationFloor``.
            Text(
                hour.precipitationChance >= Self.precipitationFloor
                    ? WeatherReadingFormat.percentage(hour.precipitationChance)
                    : " "
            )
            .font(.caption2)
            .foregroundStyle(.tint)
        }
        .frame(width: Self.HourStrip.columnWidth)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(hour.date, format: .dateTime.hour()))
        .accessibilityValue(Self.spokenHour(hour))
    }

    /// What one hour says out loud. The chance of rain is spoken whenever the
    /// strip draws it, and left out entirely when it does not — a reader
    /// hearing "zero percent" for every dry hour learns nothing twelve times.
    private static func spokenHour(_ hour: WeatherHourSummary) -> String {
        let temperature = WeatherReadingFormat.temperature(hour.temperature, width: .wide)
        guard hour.precipitationChance >= precipitationFloor else { return temperature }
        let chance = WeatherReadingFormat.percentage(hour.precipitationChance)
        return String(localized: "\(temperature), \(chance) chance of precipitation")
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

    /// The day's light, and the range the day will reach.
    ///
    /// `@ViewBuilder` rather than `some View` so an absent daylight costs no
    /// section at all — the shape ``hourlySection(_:)`` takes, and for the
    /// two reasons that one takes it: a reading restored from a blob written
    /// before this existed, and a provider with no daily data for the point.
    ///
    /// **Drawn only when there is a time to draw.** North of the Arctic
    /// Circle in June there is no sunrise, no sunset and no dusk, and three
    /// empty rows under a heading would be a worse answer than no heading —
    /// see ``WeatherDaylight/hasDaylightTimes``. The high and low go with the
    /// section rather than into the readings above, because they are a
    /// statement about the *day* and everything in that section is a statement
    /// about now.
    @ViewBuilder
    private func daylightSection(_ daylight: WeatherDaylight?) -> some View {
        if let daylight, daylight.hasDaylightTimes {
            Section {
                if let remaining = daylight.remainingLight(asOf: .now) {
                    // First, because it is the only row here that is an
                    // answer rather than a fact: everything else is a time the
                    // hiker has to subtract from themselves.
                    DetailRow(
                        label: "Light remaining",
                        value: WeatherReadingFormat.remainingLight(remaining),
                        systemImage: "hourglass"
                    )
                        .accessibilityIdentifier("weather-detail-light-remaining")
                }
                if let sunrise = daylight.sunrise {
                    DetailRow(
                        label: "Sunrise",
                        value: Self.time(sunrise),
                        systemImage: "sunrise"
                    )
                }
                if let sunset = daylight.sunset {
                    DetailRow(
                        label: "Sunset",
                        value: Self.time(sunset),
                        systemImage: "sunset"
                    )
                        .accessibilityIdentifier("weather-detail-sunset")
                }
                if let civilDusk = daylight.civilDusk {
                    // Not `sunset` again: this is the light that outlasts the
                    // sun, and the same glyph twice would read as the same
                    // fact twice.
                    DetailRow(
                        label: "Light until",
                        value: Self.time(civilDusk),
                        systemImage: "sun.horizon"
                    )
                }
                if let range = Self.range(of: daylight) {
                    DetailRow(
                        label: "Today",
                        value: range,
                        systemImage: "thermometer.variable"
                    )
                }
            } header: {
                Text("Daylight")
            }
            .accessibilityIdentifier("weather-detail-daylight")
        }
    }

    /// A clock time, in the reader's own format.
    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// The day's high and low as one row, or `nil` when the forecast carried
    /// neither.
    ///
    /// One row rather than two because they are one fact — the range — and a
    /// grid that spent two rows on it would push the times that matter off the
    /// first screenful. A forecast with only one of the pair is drawn as the
    /// one it has rather than skipped.
    private static func range(of daylight: WeatherDaylight) -> String? {
        let high = daylight.highTemperature.map { temperature in
            WeatherReadingFormat.temperature(temperature, width: .narrow)
        }
        let low = daylight.lowTemperature.map { temperature in
            WeatherReadingFormat.temperature(temperature, width: .narrow)
        }
        switch (high, low) {
        case let (high?, low?): return "\(high) / \(low)"
        case let (high?, nil): return high
        case let (nil, low?): return low
        case (nil, nil): return nil
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
                value: snapshot.capturedAt.formatted(date: .omitted, time: .shortened),
                systemImage: "clock"
            )
            DetailRow(
                label: "Age",
                value: snapshot.formattedAge(),
                systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90"
            )
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

// MARK: - Severe-weather alerts

/// The alert sections, in a same-file extension.
///
/// `WeatherDetailView` sits at SwiftLint's `type_body_length` limit and these
/// three members put it over. The extension is the way out — `.swiftlint.yml`
/// sets `excluded_types: [extension, protocol]` — and it is **in this file**
/// rather than a neighbouring one because `private` in Swift is file-scoped:
/// a cross-file extension could not reach `DetailRow` or the view's own state
/// and would not compile. Same move `OpenHikesView` makes, for the same
/// reason; see the note on that file.
private extension WeatherDetailView {
    /// The alerts that stand over this place, worst first.
    ///
    /// **Every alert is drawn, including the ones below the interruption
    /// threshold.** ``WeatherAlertPolicy/interruptionThreshold`` rations the
    /// *banner*, not the information: a hiker who opened this sheet is asking,
    /// and a minor advisory they asked for is worth an answer even though it
    /// was not worth a notification.
    ///
    /// The link is not a convenience. WeatherKit's terms require an alert to
    /// be presented with a link to the issuing authority's own page, because
    /// the summary is a headline and the page is the advice — see
    /// ``WeatherAlerts``. It is the row rather than an accessory on it, so
    /// the tap target is the whole width and a hiker in weather is not asked
    /// to hit a chevron.
    @ViewBuilder
    private func alertsSection(_ alerts: WeatherAlerts?) -> some View {
        if let alerts, case .active(let summaries) = alerts {
            Section {
                ForEach(Self.worstFirst(summaries)) { alert in
                    Link(destination: alert.detailsURL) {
                        Label {
                            VStack(alignment: .leading, spacing: Self.alertRowSpacing) {
                                Text(alert.summary)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text("Issued by \(alert.source)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: alert.severity.symbolName)
                                .foregroundStyle(.orange)
                        }
                    }
                    .accessibilityIdentifier("weather-detail-alert")
                    // The link's own label is the summary and the source; what
                    // a screen reader cannot see is that it goes somewhere.
                    .accessibilityHint("Opens the full warning from \(alert.source)")
                }
            } header: {
                Text("Weather Warnings")
            }
            .accessibilityIdentifier("weather-detail-alerts")
        }
    }

    /// What it means when there is nothing to warn about, which is two
    /// different things.
    ///
    /// **The distinction is the whole reason this row exists.** WeatherKit
    /// returns `nil` rather than an empty list where it has no alerting
    /// partner, and drawing both as "No warnings" would tell a hiker in a
    /// country nobody reports from that the ridge is clear — on the authority
    /// of an app that has no idea. See ``WeatherAlerts``.
    ///
    /// Nothing at all is drawn for a reading restored from a build that never
    /// asked for `.alerts`: that is a fact about this app rather than about
    /// the weather, and it is gone on the next fetch.
    @ViewBuilder
    private func alertStatusSection(_ alerts: WeatherAlerts?) -> some View {
        switch alerts {
        case .clear:
            Section {
                DetailRow(
                    label: "Warnings",
                    value: "None",
                    systemImage: "checkmark.shield"
                )
                    .accessibilityIdentifier("weather-detail-alerts-clear")
            }
        case .unavailable:
            Section {
                // A question mark rather than a shield of any kind: nothing
                // here is known to be clear, and a shield would say it is.
                DetailRow(
                    label: "Warnings",
                    value: "Not reported here",
                    systemImage: "questionmark.circle"
                )
                    .accessibilityIdentifier("weather-detail-alerts-unavailable")
            } footer: {
                Text("Apple Weather has no severe-weather source for this area.")
            }
        case .active, .none:
            EmptyView()
        }
    }

    /// Worst first, so the one that matters is the one read first.
    ///
    /// A stable sort on severity alone: alerts of equal grade keep the order
    /// the authority sent them in, which is the only ordering this app has any
    /// standing to claim is meaningful.
    private static func worstFirst(
        _ summaries: [WeatherAlertSummary]
    ) -> [WeatherAlertSummary] {
        summaries.enumerated()
            .sorted { lhs, rhs in
                lhs.element.severity == rhs.element.severity
                    ? lhs.offset < rhs.offset
                    : lhs.element.severity > rhs.element.severity
            }
            .map(\.element)
    }
}

// MARK: - The reading, row by row

/// The conditions section, in a same-file extension for the reason the alert
/// sections are in one: `WeatherDetailView` is at SwiftLint's
/// `type_body_length` limit and these three members put it over. See the note
/// on the extension above for why the extension is in *this* file.
private extension WeatherDetailView {
    /// The rest of the reading, one row each.
    ///
    /// ``DetailRow`` rather than a grid or a set of tiles, because that is what
    /// this app already uses for a label and a value in a `List` — and what a
    /// reader hears as one element rather than two. Each row carries the SF
    /// Symbol that says what its label says, where one exists that does; see
    /// ``DetailRow/systemImage`` for why some rows elsewhere carry none.
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
    /// carry water and a hat, then what can be seen, and finally the ones
    /// that are context rather than instruction. The split into two builders
    /// below is that same break, and is drawn as one section either way.
    private func readingsSection(_ conditions: WeatherConditions) -> some View {
        Section {
            instructionRows(conditions)
            contextRows(conditions)
        } header: {
            Text("Conditions")
        }
    }

    /// The half of the reading a hiker does something about.
    @ViewBuilder
    private func instructionRows(_ conditions: WeatherConditions) -> some View {
        DetailRow(
            label: "Feels like",
            value: WeatherReadingFormat.temperature(
                conditions.apparentTemperature,
                width: .narrow
            ),
            systemImage: "thermometer.medium"
        )
        DetailRow(
            label: "Wind",
            value: Self.wind(conditions.wind),
            systemImage: "wind"
        )
            .accessibilityIdentifier("weather-detail-wind")
        DetailRow(
            label: "Humidity",
            value: WeatherReadingFormat.percentage(conditions.humidity),
            systemImage: "humidity"
        )
        DetailRow(
            label: "UV index",
            value: WeatherReadingFormat.uvIndex(conditions.uvIndex),
            systemImage: "sun.max"
        )
        DetailRow(
            label: "Visibility",
            value: WeatherReadingFormat.visibility(conditions.visibility),
            systemImage: "eye"
        )
    }

    /// The half that is the shape of the day rather than a decision in it.
    @ViewBuilder
    private func contextRows(_ conditions: WeatherConditions) -> some View {
        DetailRow(
            label: "Pressure",
            value: WeatherReadingFormat.pressure(conditions.pressure),
            systemImage: "barometer"
        )
        DetailRow(
            label: "Dew point",
            value: WeatherReadingFormat.temperature(conditions.dewPoint, width: .narrow),
            systemImage: "drop.degreesign"
        )
        DetailRow(
            label: "Cloud cover",
            value: WeatherReadingFormat.percentage(conditions.cloudCover),
            systemImage: "cloud"
        )
        DetailRow(
            label: "Precipitation",
            value: WeatherReadingFormat.precipitation(conditions.precipitationIntensity),
            systemImage: "cloud.rain"
        )
    }
}

// MARK: - The week ahead

/// The day strip, in a same-file extension rather than in the type above.
///
/// `WeatherDetailView` sits at `type_body_length`'s 300 lines, and an
/// extension is the way out that keeps the code where a reader looks for it —
/// the rule excludes extensions deliberately, and this one is four members
/// about one section. See the *Lint* section of the instructions file.
extension WeatherDetailView {
    /// The day strip's own measurements, named for the reason
    /// ``HourStrip``'s are.
    private enum DayStrip {
        /// Wide enough for the longest abbreviated weekday a locale is likely
        /// to hand back, so the glyphs beside them line up down the section
        /// rather than stepping in and out with the day's name.
        ///
        /// A *minimum* rather than a width, because neither figure scales
        /// with the reader's text size: at an accessibility size "Today" is
        /// half again as wide as this, and a fixed frame would truncate the
        /// one row the strip names in words. The column still lines up at
        /// every size that fits, which is every size the alignment was for.
        static let dayWidth: CGFloat = 52
        /// Wide enough for "100%", a minimum for the reason ``dayWidth`` is.
        static let chanceWidth: CGFloat = 38
        static let spacing: CGFloat = 10
    }

    /// The week ahead — see ``WeatherDaySummary``.
    ///
    /// **Not under the hourly strip, which is where it was asked for.** The
    /// comment on ``daylightSection(_:)``'s placement is the reason: `List`
    /// builds rows lazily, past the fold is absent from the element tree, and
    /// a section inserted above the readings pushes the wind row off the first
    /// screenful of a sheet at its middle detent. Here the sections read in
    /// order of how far ahead they look — the next hours, now, today, the week
    /// — which is the order the questions are asked in anyway.
    ///
    /// Rows rather than a horizontal strip, unlike the hours. Seven fit down a
    /// sheet without scrolling, the comparison being made is between days
    /// rather than along a timeline, and a row has somewhere to put a high and
    /// a low without stacking four figures in a column.
    ///
    /// `@ViewBuilder` for the reason ``hourlySection(_:)`` is one, and empty
    /// for the same two: a reading restored from a blob written before this
    /// existed, and a provider with no daily data for the point.
    @ViewBuilder
    private func daysSection(_ days: [WeatherDaySummary]) -> some View {
        // Trimmed again here, and not because the mapping forgot to. That one
        // trims the *response*; ``WeatherManager`` then expires nothing, so
        // the reading restored from last night's blob — or the one the cache
        // carried across midnight with the app in a rucksack — still begins
        // on a day that has gone. Drawn as-is it opens on yesterday's
        // weekday, with no row saying *Today* under it.
        let upcoming = WeatherDaySummary.upcoming(in: days, asOf: .now)
        if !upcoming.isEmpty {
            // No identifier on the `Section` itself, which is what the
            // daylight section above does and is a trap here: an
            // `accessibilityIdentifier` on a container propagates down and
            // takes the rows' own identifiers with it, so every day answered
            // to the section's name and none to its own. The rows are what a
            // test looks for, so the rows are what is named.
            Section("Next days") {
                ForEach(upcoming) { day in
                    dayRow(day)
                }
            }
        }
    }

    private func dayRow(_ day: WeatherDaySummary) -> some View {
        HStack(spacing: Self.DayStrip.spacing) {
            Text(Self.weekday(day.date))
                .font(.subheadline.weight(.medium))
                .frame(minWidth: Self.DayStrip.dayWidth, alignment: .leading)
            Image(systemName: day.symbolName)
                .symbolRenderingMode(.multicolor)
                .font(.body)
            // Drawn only where there is something to say, and reserved either
            // way so the temperatures stay in one column down the section —
            // see ``precipitationFloor``.
            Text(
                day.precipitationChance >= Self.precipitationFloor
                    ? WeatherReadingFormat.percentage(day.precipitationChance)
                    : " "
            )
            .font(.caption)
            .foregroundStyle(.tint)
            .frame(minWidth: Self.DayStrip.chanceWidth, alignment: .leading)
            Spacer(minLength: 0)
            Text(WeatherReadingFormat.temperature(day.highTemperature, width: .narrow))
                .font(.subheadline.weight(.medium))
            Text(WeatherReadingFormat.temperature(day.lowTemperature, width: .narrow))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        // A day, a sky and a range are one fact about one day — the shape
        // ``hourColumn(_:)`` and ``DetailRow`` both take.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenWeekday(day.date))
        .accessibilityValue(Self.spokenDay(day))
        // The same identifier on every row, so a test can count them: the
        // horizon is the decision this section was filed about, and a strip
        // quietly drawing ten days again is the regression worth catching.
        .accessibilityIdentifier("weather-detail-day")
    }

    /// The day's name as the row draws it, or "Today" for the day in progress.
    ///
    /// The word rather than the weekday for today, because the strip keeps the
    /// day in progress and "Sat" in the first row of a forecast read on
    /// Saturday afternoon is a question rather than an answer.
    ///
    /// Abbreviated below that: seven full weekday names down a sheet is a
    /// column of text where the point is the numbers beside it.
    private static func weekday(_ date: Date) -> String {
        Self.today(date) ?? date.formatted(.dateTime.weekday(.abbreviated))
    }

    /// The same day, spelled out, which is what the row is called aloud.
    ///
    /// The abbreviation is a layout decision and nothing else: VoiceOver
    /// reading "Sat" is the screen's shorthand read back rather than the day
    /// it stands for, and a reader stepping down seven rows is the one person
    /// here with no column of numbers to line it up against.
    private static func spokenWeekday(_ date: Date) -> String {
        Self.today(date) ?? date.formatted(.dateTime.weekday(.wide))
    }

    /// "Today" when `date` falls on it, and `nil` otherwise — the one word
    /// both spellings of a weekday share.
    private static func today(_ date: Date) -> String? {
        guard Calendar.autoupdatingCurrent.isDateInToday(date) else { return nil }
        return String(localized: "Today", comment: "The first row of the daily forecast")
    }

    /// What one day says out loud.
    ///
    /// The weekday is already the row's label, so this is the forecast
    /// itself: the range, and the chance of rain only where the strip draws it
    /// — a reader hearing "zero percent" on every dry day learns nothing seven
    /// times, which is the rule ``spokenHour(_:)`` keeps.
    private static func spokenDay(_ day: WeatherDaySummary) -> String {
        let high = WeatherReadingFormat.temperature(day.highTemperature, width: .wide)
        let low = WeatherReadingFormat.temperature(day.lowTemperature, width: .wide)
        let range = String(
            localized: "High \(high), low \(low)",
            comment: "A day's forecast range, spoken"
        )
        guard day.precipitationChance >= precipitationFloor else { return range }
        let chance = WeatherReadingFormat.percentage(day.precipitationChance)
        return String(localized: "\(range), \(chance) chance of precipitation")
    }
}

#Preview("Weather detail") {
    // Inert: a preview runs on the developer's own machine, against the real
    // App Group, and has no business rewriting the temperature on their home
    // screen or spending the widget's reloads.
    let manager = WeatherManager(widgetPublisher: .inert)
    return WeatherDetailView(weather: manager)
}
