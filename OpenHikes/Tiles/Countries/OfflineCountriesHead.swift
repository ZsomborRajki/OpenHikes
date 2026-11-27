//
//  OfflineCountriesHead.swift
//  OpenHikes
//
//  The head of *Offline Maps*' list, over every area: which map the
//  downloads are for, the way back to it where another is selected, *Extra
//  Detail*, and *Elevation Data* under it.
//
//  Only the OpenHikes map is cut by country, and nothing else on the screen
//  says so: the outlines are drawn over whichever map is up, and a hiker on
//  Apple Maps who downloads a country still has no map with no signal. So
//  the heading says it always, and the row under it says it where it bites.
//
//  *Extra Detail* is here rather than at the foot, where it was under some
//  two hundred and forty countries. It changes what every download below it
//  costs, and so does *Elevation Data*, which is a section of its own so
//  that each switch has its own footer: the heights cost a tenth of a map in
//  the mountains and many times one over ice, so a hiker short of space is
//  told which to turn off. Each downloaded row says whether it has them.
//

import SwiftUI

struct OfflineCountriesHead: View {
    let countries: OfflineCountries

    var body: some View {
        Section {
            OfflineCountriesMapRow()
            Toggle("Extra Detail", isOn: Binding(
                get: { countries.includesDetail },
                set: { countries.setIncludesDetail($0) }
            ))
            .accessibilityIdentifier("offline-maps-extra-detail")
        } header: {
            // A sentence, so in a sentence's weight and case rather than a
            // heading's, and in the colour of what it stands over rather than
            // a header's grey, which reads as something to pass.
            Text("Downloads are for the OpenHikes map only.")
                .font(.subheadline)
                .foregroundStyle(Color.primary)
                .textCase(nil)
        } footer: {
            Text(
                """
                Adds buildings and small places such as water taps, toilets and benches. \
                Downloads take about twice the space.
                """
            )
        }
        Section {
            Toggle("Elevation Data", isOn: Binding(
                get: { countries.includesElevation },
                set: { countries.setIncludesElevation($0) }
            ))
            .accessibilityIdentifier("offline-maps-elevation-data")
        } footer: {
            Text(
                """
                Gives trails in a downloaded country their elevation profile with no signal. \
                Large or icy countries take much more space.
                """
            )
        }
    }
}

/// The row that says another map is selected, and selects the OpenHikes one:
/// drawn only while the map on screen is one the downloads are not drawn on
/// (``OfflineCountries/areDrawn(on:)``).
///
/// Reads the selected map from the app's model in the environment, as
/// ``OfflineCountriesSettingsRow`` reads the countries, so the list takes no
/// new input and a pass of this row is no pass of the list; a preview, which
/// has no model, draws nothing.
struct OfflineCountriesMapRow: View {
    @Environment(OpenHikesModel.self) private var appModel: OpenHikesModel?

    var body: some View {
        if let appModel {
            let selected = TileProvider.renderable(
                id: appModel.storedSettings.tileProviderID,
                entitlement: appModel.entitlement.state
            )
            if !OfflineCountries.areDrawn(on: selected) {
                Button {
                    appModel.storedSettings.setTileProviderID(TileProvider.openStreetMap.id)
                } label: {
                    label(selected: selected)
                }
                .accessibilityIdentifier("offline-maps-use-openhikes-map")
            }
        }
    }

    private func label(selected: TileProvider) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                // The colour itself: a hierarchical style in a button's
                // label is a level of its tint.
                Text("You’re using \(selected.name).")
                    .foregroundStyle(Color.primary)
                Text("Use the OpenHikes Map")
                    .font(.footnote)
                    .foregroundStyle(.tint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}
