//
//  WeatherBadge.swift
//  OpenHikes
//
//  The forecast over the map: what place it is for, a symbol, a temperature,
//  and a way into where the number came from.
//
//  In the Weather domain rather than in `OpenHikesView.swift` for the reason
//  every other domain folder exists — the badge draws a ``WeatherBadgeState``,
//  formats it through ``WeatherReadingFormat`` and dims on
//  ``WeatherSnapshot/isStale(asOf:policy:)``, none of which is navigation.
//
//  Three things worth knowing before changing it.
//
//  It draws a *state*, not an optional reading, and the only state that draws
//  nothing is ``WeatherBadgeState/idle`` — nobody has focused a subject yet.
//  Everything else puts a capsule on screen, including the one where WeatherKit
//  refused. That is the whole point of the type: a missing entitlement and a
//  hiker out of signal used to be pixel-identical to a feature that had never
//  been built, because all three drew nothing at all.
//
//  It names a searched place, but not a selected hike. A city name says where
//  a remote reading belongs; a hike title is user content rather than a place
//  label, and putting it in this compact control makes the badge compete with
//  the map. The detail sheet still names the selected hike.
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

import CoreLocation
import SwiftUI

struct WeatherBadge: View {
    /// How far the reading fades once it is too old to present as current.
    ///
    /// The glass keeps its own contrast, so only the contents fade; dimming
    /// the capsule as well would leave a shape floating over the map with
    /// nothing legible in it. Also what an unavailable forecast is drawn at,
    /// for the same reason and to the same end: present, and plainly not
    /// current.
    private static let staleOpacity: Double = 0.45
    private static let contentSpacing: CGFloat = 8
    private static let horizontalPadding: CGFloat = 14
    /// How wide a searched place name may get before it truncates. Roughly "Budapest"
    /// at the default text size; beyond that the badge starts competing with
    /// the map it floats over.
    private static let maximumNameWidth: CGFloat = 120

    /// Where the badge sits over the map, and how tall it draws.
    ///
    /// Not private, and the leading inset is spelled out rather than left as
    /// the `.padding(.leading)` default it reads like, because a second view
    /// is positioned against this one and cannot see it: the map's credit line
    /// hangs directly beneath the badge, and it is a subview of `MKMapView`
    /// while this is a SwiftUI overlay drawn over the top. There is no anchor
    /// joining the two hierarchies, so agreeing on these numbers is the only
    /// thing keeping them from drifting apart. See `MapView.addAttribution`.
    ///
    /// Measured from the map's *own* top edge, not its safe area: the map
    /// `.ignoresSafeArea()`, so this overlay is aligned to the full screen and
    /// the padding is what clears the Dynamic Island.
    static let topPadding: CGFloat = 96
    static let leadingPadding: CGFloat = 16
    static let verticalPadding: CGFloat = 8

    /// The text style that decides the capsule's height.
    ///
    /// The symbol and the temperature are both Dynamic Type and the symbol is
    /// the taller of the two, so this is the one to scale against — which is
    /// what makes the badge's height, and therefore the credit line's
    /// position, a function of the reader's text size rather than a constant.
    /// The place name shares the row rather than adding one, so naming a
    /// subject does not move the credit line.
    ///
    /// Twice, because SwiftUI and UIKit spell the same style differently and
    /// there is no conversion between the two types. Kept adjacent so the pair
    /// is read and changed together; `MapView.weatherBadgeHeight(in:)` needs
    /// the UIKit one to measure a line height, which `Font.TextStyle` cannot
    /// answer.
    static let heightDrivingTextStyle: Font.TextStyle = .title3

    #if canImport(UIKit)
    static let heightDrivingUITextStyle: UIFont.TextStyle = .title3
    #endif

    let state: WeatherBadgeState
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
                if let name = state.badgeName {
                    Text(name)
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: Self.maximumNameWidth, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityHidden(true)
                }
                contents
            }
            .opacity(isDimmed ? Self.staleOpacity : 1)
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
        .task(id: state.snapshot?.capturedAt) { await trackStaleness() }
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
        .accessibilityLabel(state.badgeAccessibilityLabel)
        .accessibilityValue(spokenValue)
        .accessibilityHint("Shows the conditions and where this forecast comes from")
        .accessibilityIdentifier("weather-badge")
    }

    @ViewBuilder private var contents: some View {
        switch state {
        case .idle:
            // Unreachable: the overlay that hosts this does not build a badge
            // without a subject. Drawn as an empty capsule rather than as a
            // `fatalError` because a view is not the place to assert.
            EmptyView()
        case .loading:
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
        case .reading(let snapshot, _):
            Image(systemName: snapshot.symbolName)
                .symbolRenderingMode(.multicolor)
                .font(.system(Self.heightDrivingTextStyle))
                .accessibilityHidden(true)
            // One formatter, two widths: this and the spoken value below are
            // the same rounded quantity in the reader's own units. See
            // ``WeatherReadingFormat``.
            Text(snapshot.formattedTemperature())
                .font(.headline)
        case .unavailable:
            Image(systemName: "cloud.slash")
                .font(.system(Self.heightDrivingTextStyle))
                .accessibilityHidden(true)
        }
    }

    /// Dimmed when the reading is too old to present as current, and whenever
    /// there is no reading to present at all.
    private var isDimmed: Bool {
        switch state {
        case .idle, .loading: false
        case .reading: isStale
        case .unavailable: true
        }
    }

    /// What VoiceOver reads out.
    ///
    /// The age is spoken whenever the reading is stale, because the visual cue
    /// is a dimming and nothing else — colour alone is not a signal a reader
    /// who cannot see it can act on, and "how old" is the part that decides
    /// whether to trust the number. The unavailable case is spoken outright
    /// for the same reason: a slashed cloud says nothing to someone who cannot
    /// see it.
    private var spokenValue: String {
        switch state {
        case .idle:
            ""
        case .loading:
            "Loading"
        case .unavailable:
            "Not available"
        case .reading(let snapshot, _):
            if isStale {
                "\(snapshot.spokenTemperature()), \(snapshot.conditionDescription), "
                    + "last updated \(snapshot.formattedAge()) ago"
            } else {
                "\(snapshot.spokenTemperature()), \(snapshot.conditionDescription)"
            }
        }
    }

    /// Marks the reading stale, now or at the moment it becomes so.
    ///
    /// The immediate check is not redundant with the sleep: a launch that
    /// restores a reading from last night and a return from hours in the
    /// background both arrive here with one that is already past its deadline,
    /// and waiting out a negative interval would leave it undimmed.
    private func trackStaleness() async {
        guard let snapshot = state.snapshot else {
            isStale = false
            return
        }
        isStale = snapshot.isStale()
        guard !isStale else { return }
        let remaining = snapshot.stalenessDate().timeIntervalSinceNow
        try? await Task.sleep(for: .seconds(max(0, remaining)))
        guard !Task.isCancelled else { return }
        isStale = true
    }
}

extension WeatherBadgeState {
    /// The compact badge names searched places only. A selected hike remains
    /// identifiable in the detail sheet without spending map space on its title.
    var badgeName: String? {
        guard case .place(_, let name) = subject else { return nil }
        return name
    }

    var badgeAccessibilityLabel: String {
        guard let subject else { return "Current weather" }
        switch subject {
        case .me: return "Current weather"
        case .place(_, let name): return "Weather in \(name)"
        case .trail: return "Trail weather"
        }
    }
}

#Preview("Fresh, here") {
    WeatherBadge(
        state: .reading(
            WeatherSnapshot(
                symbolName: "cloud.sun.fill",
                temperature: Measurement(value: 12, unit: UnitTemperature.celsius),
                conditionDescription: "Partly Cloudy",
                capturedAt: .now
            ),
            subject: .me(.init(latitude: 47.4979, longitude: 19.0402))
        ),
        onTap: { /* preview */ }
    )
}

#Preview("Fresh, a searched place") {
    WeatherBadge(
        state: .reading(
            WeatherSnapshot(
                symbolName: "sun.max.fill",
                temperature: Measurement(value: 24, unit: UnitTemperature.celsius),
                conditionDescription: "Clear",
                capturedAt: .now
            ),
            subject: .place(.init(latitude: 47.4979, longitude: 19.0402), name: "Budapest")
        ),
        onTap: { /* preview */ }
    )
}

#Preview("Stale") {
    WeatherBadge(
        state: .reading(
            WeatherSnapshot(
                symbolName: "cloud.rain.fill",
                temperature: Measurement(value: 4, unit: UnitTemperature.celsius),
                conditionDescription: "Rain",
                capturedAt: .now.addingTimeInterval(-WeatherPollingPolicy.standard.stalenessInterval)
            ),
            subject: .me(.init(latitude: 47.4979, longitude: 19.0402))
        ),
        onTap: { /* preview */ }
    )
}

#Preview("Loading") {
    WeatherBadge(
        state: .loading(.place(.init(latitude: 47.4979, longitude: 19.0402), name: "Budapest")),
        onTap: { /* preview */ }
    )
}

#Preview("Unavailable") {
    WeatherBadge(
        state: .unavailable(.me(.init(latitude: 47.4979, longitude: 19.0402))),
        onTap: { /* preview */ }
    )
}
