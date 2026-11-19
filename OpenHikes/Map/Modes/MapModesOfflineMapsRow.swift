//
//  MapModesOfflineMapsRow.swift
//  OpenHikes
//
//  *Offline Maps* on *Map Modes*: the way to the countries, states and
//  provinces the OpenHikes map can be downloaded for (#1482), beside the maps they are for, saying which
//  are down already. A tap closes *Map Modes* and opens the list over the
//  map — see ``MapModesPresentation/dismissOpeningOfflineMaps()``.
//
//  The first-run tip over it is the one tip *Map Modes* shows, because a
//  row at the foot of a sheet about choosing a map is easy to pass.
//

import SwiftUI
import TipKit

struct MapModesOfflineMapsRow: View {
    /// The row's glyph. `nonisolated` because the first-run tip over the row
    /// draws it too — see ``OfflineMapsTip`` — and a tip is not main-actor
    /// isolated.
    nonisolated static let symbolName = "arrow.down.circle"

    let countries: OfflineCountries
    let onOpen: () -> Void

    @Environment(\.appTips) private var tips

    private static let horizontalMargin: CGFloat = 16

    var body: some View {
        VStack(spacing: 8) {
            if tips != nil {
                TipView(OfflineMapsTip())
            }
            Button {
                tips?.used(OfflineMapsTip())
                onOpen()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: Self.symbolName)
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Offline Maps")
                            .foregroundStyle(.primary)
                        Text(summary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding(12)
                .glassSurface(.regular.interactive(), in: .rect(cornerRadius: 12))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("map-modes-offline-maps")
        }
        .padding(.horizontal, Self.horizontalMargin)
        .padding(.bottom, 12)
    }

    /// The countries downloaded and what they take, or what the row is for.
    private var summary: String {
        let names = countries.installed.values.map { OfflineCountries.name(of: $0.country) }.sorted()
        guard !names.isEmpty else {
            return String(localized: "Download a country to use the OpenHikes map with no signal.")
        }
        let size = OfflineCountryRow.bytes(countries.installedByteCount)
        return String(localized: "\(names.formatted(.list(type: .and))) · \(size)")
    }
}
