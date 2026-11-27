//
//  WeatherDetailSheet.swift
//  OpenHikes
//
//  What the weather badge opens: the conditions in full, how old the reading
//  is, and Apple Weather's credits.
//
//  "In full" is meant literally. One request answers with a dozen
//  measurements, twelve hours and a week, and the badge draws three of them.
//  Everything else was already fetched, already paid for and already in
//  memory; the panels below are that, and no second request.
//
//  ## Drawn the way Apple draws weather
//
//  A sky behind everything (``WeatherSky``), the temperature set large at the
//  head with no panel behind it, then translucent panels: the hours as a
//  strip, the days as bars on one scale, the wind on a compass, the day's
//  light as the sun's curve, and a tile for each remaining measurement. It
//  is the layout of Apple's own Weather, which is the one a hiker has already
//  learned to read, and it is what the sheet's glyphs were drawn for: they
//  are Apple's multicolor weather symbols, whose clouds are white, and on the
//  list this sheet used to be they vanished into a light background.
//
//  The sheet is therefore light on dark at every hour and in both
//  appearances: `colorScheme` is set for everything in it, and nothing below
//  asks the system which appearance it is in.
//
//  ## Where it is attached
//
//  Where this is attached matters more than what it draws. `OpenHikesView`
//  keeps ``MapSheet`` presented permanently and puts it back if it is ever
//  dismissed, and a view can only have one modal presented at a time — so a
//  `.sheet` attached to the badge, or to the map, or anywhere else in the root
//  hierarchy, is never presented at all. No error, no sheet, just a control
//  that does nothing. ``weatherDetailSheet(_:from:weather:)`` is attached to
//  the sheet's *content* instead, beside `.photoCapturePickers`, and layers
//  above it the same way the Settings sheet does — or to a place card over
//  that content, while one is up: see ``MapControlModals``.
//
//  That splits the tap from the presentation, which is what
//  ``WeatherDetailPresentation`` is for: the badge is over the map and the
//  sheet is inside the bottom sheet, so the flag has to be reachable from both
//  without either becoming an input of the root view's body.
//

import Foundation
import SwiftUI

/// Whether the weather detail sheet is up.
///
/// A reference type rather than a `@State` `Bool`, for the reason
/// ``SheetPresentation`` is one: `@State` invalidates the view that declares
/// it whether or not its body reads it, and the view that would have declared
/// it is the one drawing the map. The reference never changes, so opening the
/// sheet costs the root view nothing. ``MapControlModals`` holds it.
@Observable
final class WeatherDetailPresentation {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    private(set) var isPresented = false

    /// The flag, for ``MapControlModals/binding(_:for:)`` to drive
    /// `.sheet(isPresented:)` from. Building it reads the flag —
    /// `Binding(get:set:)` calls its getter as it is made — so the modifier
    /// below, which builds it in its body, is a reader of this flag: the one
    /// view whose business the flag is. See *Render isolation, in practice*
    /// in the repository instructions.
    var isPresentedBinding: Binding<Bool> {
        Binding(get: { self.isPresented }, set: { self.isPresented = $0 })
    }

    func present() {
        isPresented = true
    }
}

extension View {
    /// Attaches the weather detail sheet to a view it can actually be
    /// presented from — the sheet's content, not the view that presents the
    /// sheet, or a place card over that content. See ``MapControlModals``.
    func weatherDetailSheet(
        _ modals: MapControlModals,
        from presenter: MapControlModals.Presenter,
        weather: WeatherManager
    ) -> some View {
        modifier(WeatherDetailSheetModifier(modals: modals, presenter: presenter, weather: weather))
    }
}

private struct WeatherDetailSheetModifier: ViewModifier {
    let modals: MapControlModals
    let presenter: MapControlModals.Presenter
    let weather: WeatherManager
    // periphery:ignore - read only as `$detent`, the binding
    // `.presentationDetents(_:selection:)` takes.
    /// Which detent the sheet opens at, rather than which ones it offers.
    ///
    /// SwiftUI opens at the smallest detent in the set unless it is given a
    /// selection, and the smallest one is not enough: a half sheet holds the
    /// temperature the badge already showed and the next twelve hours, and
    /// none of the panels underneath. So it opens whole and can still be
    /// dragged down; `.medium` stays in the set because the sheet is
    /// dismissible by drag from it and because a hiker who only wanted the
    /// hours can have the map back.
    @State private var detent: PresentationDetent = .large

    func body(content: Content) -> some View {
        content.sheet(isPresented: modals.binding(modals.weatherDetail.isPresentedBinding, for: presenter)) {
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
    /// How far the sheet has to scroll before its title moves into the bar:
    /// about where the place's name leaves the top of the sheet.
    private static let titleFold: CGFloat = 56
    private static let titleFade = 0.2
    private static let bottomPadding: CGFloat = 24

    let weather: WeatherManager

    @Environment(\.locale) private var locale

    /// `nil` until WeatherKit answers, and for good if it never does. The
    /// wording and the fallback link do not wait on it — see
    /// ``AppleWeatherAttribution/marks(from:)``.
    @State private var marks: WeatherAttributionMarks?
    /// Whether the place's name has scrolled away under the bar, which is
    /// when the bar starts to carry it.
    @State private var titleIsInBar = false

    var body: some View {
        NavigationStack {
            ScrollView {
                column
                    .frame(maxWidth: WeatherCardMetrics.readableWidth)
                    .padding(.horizontal, WeatherCardMetrics.margin)
                    .padding(.bottom, Self.bottomPadding)
                    .frame(maxWidth: .infinity)
            }
            .background { WeatherSkyBackdrop(sky: sky) }
            .environment(\.weatherSky, sky)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > Self.titleFold
            } action: { _, isPast in
                titleIsInBar = isPast
            }
            .navigationTitle(barTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                // The place is named at the head of the sheet, above the
                // temperature, so the bar says it only once that has
                // scrolled away: one name on screen at a time.
                ToolbarItem(placement: .principal) {
                    barTitle
                        .font(.headline)
                        .lineLimit(1)
                        .opacity(titleIsInBar ? 1 : 0)
                        .animation(.easeInOut(duration: Self.titleFade), value: titleIsInBar)
                        .accessibilityHidden(!titleIsInBar)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    DismissButton()
                        .accessibilityIdentifier("weather-detail-done")
                }
            }
        }
        // Light on dark whatever the device is set to, because the sky
        // behind it is — see this file's header. On the stack, so the bar's
        // buttons take it too.
        .environment(\.colorScheme, .dark)
        .tint(.white)
        .task { marks = await AppleWeatherAttribution.marks() }
        // Separate from the credits' task rather than sequenced behind it:
        // the two are independent round trips, and a title should not wait on
        // Apple Weather's legal marks to appear. See
        // ``WeatherManager/resolvePlace()`` for why the lookup happens on
        // the sheet opening rather than when the subject changes.
        .task { await weather.resolvePlace() }
    }

    /// The sheet's one column: the reading, or why there is none, and
    /// Apple Weather's credits under either.
    ///
    /// A plain stack, not a lazy one. It is a few dozen views, and a panel
    /// below the fold of a lazy container is absent from the element tree
    /// rather than merely off screen: while this sheet was a `List`, a
    /// section put in above the wind took the wind out of the reach of the
    /// test that asks for it.
    private var column: some View {
        VStack(spacing: WeatherCardMetrics.spacing) {
            if let snapshot = weather.current {
                WeatherReading(
                    snapshot: snapshot,
                    placeName: placeName,
                    eyebrow: eyebrow,
                    clock: forecastClock(locale: locale),
                    marks: marks
                )
            } else if case .unavailable = weather.state {
                WeatherUnavailableNotice(placeName: placeName)
            }
            WeatherDataSource(marks: marks)
        }
    }

    /// Which place the reading is for, or `nil` when it is simply here.
    ///
    /// The badge can be pointed at a searched city or a selected trail, so
    /// "Current conditions" on its own is not always true — see
    /// ``WeatherSubject``.
    ///
    /// **The geocoded city first, and the subject's own name only as a
    /// fallback.** For a selected route the subject's name is the *hike's*
    /// title, which names the thing the hiker tapped rather than the place the
    /// forecast describes — see ``WeatherPlaceNaming``. The fallback is what
    /// stands when there is no city to be had: no network, no namer on this
    /// launch, or an anchor out on open hillside that belongs to no
    /// settlement. Falling back to the hike's name rather than to nothing is
    /// deliberate: losing the title altogether would be a worse answer than
    /// an imprecise one.
    private var placeName: String? {
        weather.cityName ?? weather.state.subject?.placeName
    }

    /// The trail the hiker asked about, over the town the title names: the
    /// forecast is the town's, and the question was the trail's. `nil`
    /// wherever the title is already the subject's own name.
    private var eyebrow: String? {
        guard let city = weather.cityName, let asked = weather.state.subject?.placeName, asked != city else {
            return nil
        }
        return asked
    }

    /// What the bar calls the sheet: what the head of the sheet calls the
    /// place, so the name that scrolls away is the name that arrives.
    /// `Text` rather than `placeName ?? "My Location"`, which types the
    /// whole expression as `String` and so takes the non-localized overload.
    private var barTitle: Text {
        placeName.map { Text(verbatim: $0) } ?? Text("My Location")
    }

    /// The sky the sheet is drawn on: the reading's, or none in particular
    /// while there is no reading.
    private var sky: WeatherSky {
        weather.current.map { WeatherSky($0) } ?? .unknown
    }
}

/// A reading, panel by panel.
///
/// The order is the sheet's argument. The temperature and Apple's credit
/// for it; then a warning, if one stands, **above everything the weather is
/// merely doing**: that is a meteorological agency telling the hiker to
/// reconsider the walk, and it costs nothing in the ordinary case, because
/// it draws only for an alert that actually stands. Then the panels in the
/// order of how far ahead they look and how soon a hiker acts on them: the
/// next hours, the days, how it feels and the sun's strength, the wind, the
/// light that is left, and the measurements that are context. Last, what
/// is known about the reading itself.
private struct WeatherReading: View {
    let snapshot: WeatherSnapshot
    let placeName: String?
    let eyebrow: String?
    let clock: WeatherForecastClock
    let marks: WeatherAttributionMarks?

    var body: some View {
        let now = Date.now
        WeatherHero(snapshot: snapshot, placeName: placeName, eyebrow: eyebrow)
        // Straight under the reading it credits, where a hiker — and App
        // Review — sees it the moment the sheet opens. See
        // ``WeatherAttributionBanner``.
        WeatherAttributionBanner(marks: marks)
        if case .active(let alerts) = snapshot.alerts {
            WeatherAlertsCard(alerts: WeatherAlertSummary.worstFirst(alerts))
        }
        // No card for an empty strip: a reading restored from a blob written
        // before the hours existed, and a provider with no hourly data for
        // the point, both arrive here as `[]`.
        if !snapshot.hourly.isEmpty {
            WeatherHourlyCard(hours: snapshot.hourly, now: now, clock: clock)
        }
        WeatherDailyCard(
            days: upcomingDays(asOf: now),
            now: now,
            timeZone: clock.zone,
            current: snapshot.temperature
        )
        WeatherExposureTiles(temperature: snapshot.temperature, conditions: snapshot.conditions)
        WeatherWindCard(wind: snapshot.conditions.wind)
        if let daylight = snapshot.daylight, daylight.hasDaylightTimes {
            WeatherDaylightCard(daylight: daylight, now: now, clock: clock)
        }
        WeatherContextTiles(conditions: snapshot.conditions)
        WeatherStandingCard(snapshot: snapshot, now: now)
    }

    /// The days still to come, today among them.
    ///
    /// Trimmed again here, and not because the mapping forgot to. That one
    /// trims the *response*; ``WeatherManager`` then expires nothing, so the
    /// reading restored from last night's blob — or the one the cache
    /// carried across midnight with the app in a rucksack — still begins on
    /// a day that has gone. Drawn as-is it opens on yesterday's weekday,
    /// with no row saying *Today* under it.
    ///
    /// Counted in the forecast's own zone where the geocoder has said what
    /// it is, because each day starts at midnight *there* — see
    /// ``WeatherPlaceNaming``. Which row is today needs no zone, and is
    /// right even before that answer lands.
    private func upcomingDays(asOf now: Date) -> [WeatherDaySummary] {
        WeatherDaySummary.upcoming(
            in: snapshot.days,
            asOf: now,
            calendar: WeatherForecastDay.calendar(in: clock.zone)
        )
    }
}

/// The sky, top of the sheet to its foot — see ``WeatherSky``.
private struct WeatherSkyBackdrop: View {
    private static let change = 0.6

    let sky: WeatherSky

    var body: some View {
        LinearGradient(
            colors: [sky.backdrop.zenith, sky.backdrop.horizon].map { Color(hex: $0) ?? .black },
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
        .animation(.easeInOut(duration: Self.change), value: sky)
    }
}

#Preview("Weather detail") {
    // Inert: a preview runs on the developer's own machine, against the real
    // App Group, and has no business rewriting the temperature on their home
    // screen or spending the widget's reloads.
    let manager = WeatherManager(widgetPublisher: .inert)
    return WeatherDetailView(weather: manager)
}
