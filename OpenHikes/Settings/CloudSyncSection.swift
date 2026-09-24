//
//  CloudSyncSection.swift
//  OpenHikes
//
//  The settings section for iCloud sync: what it is doing, and the switch.
//
//  Its own file rather than another computed property on ``SettingsView``
//  because it is the one section with live state — a status that changes while
//  the sheet is open, as an account check returns or an upload finishes.
//
//  The status line is deliberately wordy. Sync is invisible when it works, so
//  the only time anyone reads this is when a hike did not appear on the other
//  device, and "Sync Off" on its own does not tell them whether to sign into
//  iCloud, flip a switch, or wait.
//

import SwiftUI

struct CloudSyncSection: View {
    @Bindable var sync: CloudSyncCoordinator

    var body: some View {
        Section {
            statusRow
            Toggle("Sync with iCloud", isOn: $sync.isEnabled)
                .accessibilityIdentifier("cloud-sync-toggle")
        } header: {
            Text("iCloud")
        } footer: {
            Text(
                "Your recorded and imported hikes, and the photos taken along them, "
                    + "are kept in your private iCloud storage and appear on your other "
                    + "devices. Downloaded maps are not — they stay on the device that "
                    + "downloaded them."
            )
        }
    }

    private var statusRow: some View {
        HStack(spacing: 14) {
            Image(systemName: symbolName)
                .font(.system(size: 32))
                .foregroundStyle(symbolStyle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(sync.status.title)
                    .font(.headline)
                Text(sync.status.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        // One row, one thing said: the glyph repeats what the headline already
        // states, and reading the title and the detail as separate elements
        // would make the explanation the section exists for sound like an
        // unrelated second item.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sync.status.title)
        .accessibilityValue(sync.status.detail)
        .accessibilityIdentifier("cloud-sync-status")
    }

    private var symbolName: String {
        // Ahead of the account for the reason ``CloudSyncStatus/title`` gives:
        // a launch that never mirrors leaves the account unresolved, and an
        // unasked question is not a warning to raise.
        if sync.status.activity == .disabled { return "icloud.slash.fill" }
        guard sync.status.account.isUsable else { return "exclamationmark.icloud.fill" }
        switch sync.status.activity {
        case .disabled, .paused: return "icloud.slash.fill"
        case .failed: return "exclamationmark.icloud.fill"
        case .idle: return "checkmark.icloud.fill"
        case .retrying: return "arrow.trianglehead.2.clockwise.rotate.90.icloud.fill"
        case .working: return "arrow.trianglehead.2.clockwise.rotate.90.icloud.fill"
        }
    }

    private var symbolStyle: Color {
        if sync.status.activity == .disabled { return .secondary }
        guard sync.status.account.isUsable else { return .orange }
        switch sync.status.activity {
        case .disabled, .paused: return .secondary
        case .failed: return .orange
        case .idle: return .accentColor
        // Not the accent colour: waiting on the network is not the tick of a
        // finished pass, and not orange either — there is nothing to fix.
        case .retrying: return .secondary
        case .working: return .accentColor
        }
    }
}
