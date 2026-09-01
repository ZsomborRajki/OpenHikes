//
//  WeatherDetailSheet.swift
//  OpenHikes
//
//  What the weather badge opens: the conditions in full, how old the reading
//  is, and Apple Weather's credits.
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
        RenderSignpost.mark("WeatherDetailBody")
        return NavigationStack {
            List {
                if let snapshot = weather.current {
                    conditionsSection(snapshot)
                    freshnessSection(snapshot)
                }
                attributionSection
            }
            .navigationTitle("Weather")
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
            .accessibilityLabel("Current conditions")
            .accessibilityValue("\(snapshot.spokenTemperature()), \(snapshot.conditionDescription)")
            .accessibilityIdentifier("weather-detail-conditions")
        }
    }

    /// How old the reading is, exactly.
    ///
    /// This is the other half of the badge's dimming: the map shows only that
    /// something is off, deliberately, because a timestamp over the map is
    /// chrome a walker did not ask for. The number belongs here, where they
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
