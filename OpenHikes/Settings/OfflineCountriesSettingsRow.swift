//
//  OfflineCountriesSettingsRow.swift
//  OpenHikes
//
//  *Offline Maps* in Settings, beside the storage it costs: what the
//  downloaded countries take, and the same list *Map Modes* opens over the
//  map, here without one. It is where a Mac finds it too, and where somebody
//  freeing space looks.
//
//  Reads the countries from the app's model in the environment rather than
//  being handed them, so the Settings form takes no new input; a preview,
//  which has no model, draws nothing.
//

import CoreLocation
import SwiftUI

struct OfflineCountriesSettingsRow: View {
    @Environment(OpenHikesModel.self) private var appModel: OpenHikesModel?

    var body: some View {
        if let appModel {
            let countries = appModel.offlineCountries
            NavigationLink {
                SettingsOfflineCountries(countries: countries, locationManager: appModel.locationManager)
            } label: {
                HStack {
                    Label("Offline Maps", systemImage: MapModesOfflineMapsRow.symbolName)
                    Spacer()
                    Text(OfflineCountryRow.bytes(countries.installedByteCount))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
            .accessibilityIdentifier("settings-offline-maps")
        }
    }
}

/// The list, pushed in Settings. The hiker's position is read once, as it
/// comes up, so a fix neither re-runs the row above nor reorders the list.
private struct SettingsOfflineCountries: View {
    let countries: OfflineCountries
    let locationManager: LocationManager

    @State private var near: CLLocationCoordinate2D?

    var body: some View {
        OfflineCountriesList(countries: countries, near: near)
            .navigationTitle("Offline Maps")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .onAppear { near = locationManager.coordinate }
            .task { await countries.refreshList() }
    }
}
