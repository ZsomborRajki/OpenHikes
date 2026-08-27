//
//  WeatherBadge.swift
//  OpenHikes
//
//  The forecast over the map: a symbol, a temperature, and a way into where
//  the number came from.
//
//  In the Weather domain rather than in `OpenHikesView.swift` for the reason
//  every other domain folder exists — the badge draws a ``WeatherSnapshot``,
//  formats it through ``WeatherReadingFormat`` and dims on
//  ``WeatherSnapshot/isStale(asOf:policy:)``, none of which is navigation.
//
//  Two things worth knowing before changing it.
//
//  The tap does not present anything from here. The app keeps ``MapSheet``
//  presented permanently, and a view can only have one modal up at a time, so
//  a `.sheet` attached anywhere in the root hierarchy — including this
//  overlay — is never presented at all. The badge raises the request and
//  ``WeatherDetailPresentation`` carries it to a modifier attached inside the
//  sheet's own content.
//
//  The dimming is driven by a clock, and the clock lives in this view. It
//  cannot come from the snapshot alone, because the whole point of a stale
//  reading is that nothing new arrives to redraw it; and it must not come from
//  a ticking timer above, because this badge sits in the root view's overlay
//  closure, which is inlined into the root body — a tick read up there would
//  re-evaluate the map screen forever. What is here instead is one sleep to
//  one deadline, the shape ``OpenHikesModel/pollWeather(policy:)`` already
//  uses, restarted only when a new reading replaces the old one.
//

import SwiftUI

struct WeatherBadge: View {
    /// How far the reading fades once it is too old to present as current.
    ///
    /// The glass keeps its own contrast, so only the contents fade; dimming
    /// the capsule as well would leave a shape floating over the map with
    /// nothing legible in it.
    private static let staleOpacity: Double = 0.45
    private static let contentSpacing: CGFloat = 8
    private static let horizontalPadding: CGFloat = 14
    private static let verticalPadding: CGFloat = 8

    let weather: WeatherSnapshot
    let onTap: () -> Void

    /// Whether the reading has passed ``WeatherPollingPolicy/stalenessInterval``.
    ///
    /// `@State` invalidates the view that declares it whether or not its body
    /// reads it — which is exactly why it is declared *here* and not on the
    /// root view. This is a leaf, so the invalidation buys a capsule redraw
    /// rather than a map screen.
    @State private var isStale = false

    var body: some View {
        RenderSignpost.mark("WeatherBadgeBody")
        return Button(action: onTap) {
            HStack(spacing: Self.contentSpacing) {
                Image(systemName: weather.symbolName)
                    .symbolRenderingMode(.multicolor)
                    .font(.title3)
                    .accessibilityHidden(true)
                // One formatter, two widths: this and the spoken value below
                // are the same rounded quantity in the reader's own units.
                // See ``WeatherReadingFormat``.
                Text(weather.formattedTemperature())
                    .font(.headline)
            }
            .opacity(isStale ? Self.staleOpacity : 1)
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.vertical, Self.verticalPadding)
            // Liquid Glass rather than `.ultraThinMaterial`: this hovers over
            // live map imagery, which is exactly what the material could not
            // adapt to — it took on whatever the tiles under it happened to
            // be, so a temperature over a snowfield and one over forest were
            // two different badges. Glass keeps its own legibility over both.
            //
            // `interactive()` now that it is a control: the press response is
            // the only thing telling a sighted user the capsule answers a tap.
            //
            // Inside the button's label rather than around it, the way every
            // other glass control here is built.
            .glassSurface(.regular.interactive(), in: .capsule)
            .minimumTapTarget()
        }
        .buttonStyle(.plain)
        .task(id: weather.capturedAt) { await trackStaleness() }
        // A symbol and a number that only mean anything together, and the
        // number needs its unit spelled out to be spoken as a temperature.
        //
        // No `.accessibilityElement(children: .ignore)` and no explicit
        // `.isButton`: a `Button` is already one element carrying that trait,
        // and overriding its label is enough to replace what its contents
        // would otherwise spell out. Wrapping it in an ignoring container
        // instead — which is what those two modifiers amount to here — leaves
        // the button itself in the tree underneath, labelled with the bare
        // temperature.
        .accessibilityLabel("Current weather")
        .accessibilityValue(spokenValue)
        .accessibilityHint("Shows the conditions and where this forecast comes from")
        .accessibilityIdentifier("weather-badge")
    }

    /// What VoiceOver reads out.
    ///
    /// The age is spoken whenever the reading is stale, because the visual cue
    /// is a dimming and nothing else — colour alone is not a signal a reader
    /// who cannot see it can act on, and "how old" is the part that decides
    /// whether to trust the number.
    private var spokenValue: String {
        let reading = "\(weather.spokenTemperature()), \(weather.conditionDescription)"
        guard isStale else { return reading }
        return "\(reading), last updated \(weather.formattedAge()) ago"
    }

    /// Marks the reading stale, now or at the moment it becomes so.
    ///
    /// The immediate check is not redundant with the sleep: a launch that
    /// restores nothing and a return from hours in the background both arrive
    /// here with a reading that is already past its deadline, and waiting out
    /// a negative interval would leave it undimmed.
    private func trackStaleness() async {
        isStale = weather.isStale()
        guard !isStale else { return }
        let remaining = weather.stalenessDate().timeIntervalSinceNow
        try? await Task.sleep(for: .seconds(max(0, remaining)))
        guard !Task.isCancelled else { return }
        isStale = true
    }
}

#Preview("Fresh") {
    WeatherBadge(
        weather: WeatherSnapshot(
            symbolName: "cloud.sun.fill",
            temperature: Measurement(value: 12, unit: UnitTemperature.celsius),
            conditionDescription: "Partly Cloudy",
            capturedAt: .now
        ),
        onTap: { /* preview */ }
    )
}

#Preview("Stale") {
    WeatherBadge(
        weather: WeatherSnapshot(
            symbolName: "cloud.rain.fill",
            temperature: Measurement(value: 4, unit: UnitTemperature.celsius),
            conditionDescription: "Rain",
            capturedAt: .now.addingTimeInterval(-WeatherPollingPolicy.standard.stalenessInterval)
        ),
        onTap: { /* preview */ }
    )
}
