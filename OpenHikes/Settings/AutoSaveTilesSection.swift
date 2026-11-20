//
//  AutoSaveTilesSection.swift
//  OpenHikes
//
//  The settings switch over keeping the map around a hike as it is browsed.
//
//  It was a switch on every hike's screen, on until turned off, from when
//  browsing was the only way the default map could be kept: OpenStreetMap's
//  tile policy forbids a bulk download. That map is the app's own now and
//  downloads by country, so this is one switch for the device, off until the
//  hiker turns it on, above the storage it spends. The footer says what it
//  does and sends a hiker on the OpenHikes map to *Offline Maps*, the row
//  under it.
//
//  Its own file, and a view rather than another computed property on
//  ``SettingsView``, so the `@AppStorage` behind it is this section's input
//  and not one more of the whole form's.
//

import SwiftUI

struct AutoSaveTilesSection: View {
    /// Told when the switch moves, so the hike the map has selected starts
    /// or stops being saved for at once — see
    /// ``AutoSaveController/switchDidChange()``.
    let autoSave: AutoSaveController

    @AppStorage(SettingsKey.autoSaveTilesEnabled) private var isOn = SettingsDefault.autoSaveTilesEnabled

    var body: some View {
        Section {
            Toggle("Auto-Save Tiles", isOn: $isOn)
                .accessibilityIdentifier("auto-save-tiles-toggle")
                // After the write, which the controller reads back from the
                // same defaults.
                .onChange(of: isOn) { _, _ in autoSave.switchDidChange() }
        } footer: {
            Text("""
            Saves the map around a hike as you browse it, so it’s there without a signal. For the \
            OpenHikes map, Offline Maps downloads a whole country instead.
            """)
        }
    }
}
