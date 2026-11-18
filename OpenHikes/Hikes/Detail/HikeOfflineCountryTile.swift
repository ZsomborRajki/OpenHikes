//
//  HikeOfflineCountryTile.swift
//  OpenHikes
//
//  The hike screen's *Offline* tile on the OpenHikes map, which downloads
//  whole countries rather than a trail's tiles (#1482): it finds the
//  countries the trail passes through and offers the ones not yet down.
//  The tile shows the download's progress while one is coming down, *Saved*
//  once the whole trail is inside countries on the device, and *Partly
//  Saved* once those it crosses are but some of it is in none there is to
//  download (``OfflineRouteCoverage``).
//
//  Reads the countries from the app's model in the environment, so the hike
//  screen takes no new input; a preview, with no model, draws the tile
//  disabled. Which countries a trail crosses is worked out off the body, once
//  a line lands or the list changes, because it tests every few points of
//  the line against every outline.
//

import OpenHikesData
import SwiftUI

struct HikeOfflineCountryTile: View {
    let line: ShownLine

    @Environment(OpenHikesModel.self) private var appModel: OpenHikesModel?
    @State private var coverage = OfflineRouteCoverage()
    @State private var isAsking = false

    var body: some View {
        let countries = appModel?.offlineCountries
        let missing = coverage.crossed.filter { countries?.isInstalled($0.id) == false }
        let download = coverage.crossed.lazy.compactMap { countries?.downloads[$0.id] }.first
        let saving = countries?.saving(coverage) ?? .unsaved
        Button {
            if download != nil || !missing.isEmpty { isAsking = true }
        } label: {
            tile(download: download, saving: saving, canDownload: !missing.isEmpty)
        }
        .buttonStyle(.plain)
        .disabled(coverage.crossed.isEmpty)
        .accessibilityLabel("Save maps for offline use")
        .accessibilityValue(accessibilityValue(download: download, saving: saving))
        .accessibilityIdentifier("offline-country-button")
        .confirmationDialog("Offline Maps", isPresented: $isAsking, titleVisibility: .visible) {
            if let download, let countries {
                Button("Cancel Download", role: .destructive) {
                    countries.cancel(download.country.id)
                }
            } else if let countries {
                ForEach(missing) { country in
                    let name = OfflineCountries.name(of: country.id)
                    Button("Download \(name) · \(OfflineCountryRow.bytes(country.byteCount))") {
                        countries.download(country)
                    }
                }
            }
        } message: {
            Text("The OpenHikes map draws a downloaded country with no signal. Downloads use Wi-Fi.")
        }
        .task(id: TaskKey(revision: line.revision, listed: countries?.listed.map(\.id) ?? [])) {
            guard let countries else { return }
            if countries.listPhase == .idle, countries.listed.isEmpty { await countries.refreshList() }
            coverage = countries.coverage(alongRoute: line.current?.route ?? [])
        }
    }

    private struct TaskKey: Equatable {
        let revision: Int
        let listed: [String]
    }

    @ViewBuilder
    private func tile(download: OfflineCountryDownload?, saving: OfflineRouteSaving, canDownload: Bool)
        -> some View {
        if let download, !download.hasFailed {
            ActionTile {
                ProgressView().controlSize(.small)
                    .accessibilityHidden(true)
                Text(download.fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        } else if saving == .whole {
            ActionTile(tint: .green) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .accessibilityHidden(true)
                Text("Saved").font(.caption2.weight(.medium))
            }
        } else if saving == .part, !canDownload {
            ActionTile(tint: .orange) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.title3)
                    .accessibilityHidden(true)
                Text("Partly Saved").font(.caption2.weight(.medium))
            }
        } else {
            ActionTile(tint: coverage.crossed.isEmpty ? .secondary : .accentColor) {
                Image(systemName: "arrow.down.circle")
                    .font(.title3)
                    .accessibilityHidden(true)
                Text("Offline").font(.caption2.weight(.medium))
            }
        }
    }

    private func accessibilityValue(download: OfflineCountryDownload?, saving: OfflineRouteSaving) -> String {
        if let download, !download.hasFailed {
            return download.fraction.formatted(.percent.precision(.fractionLength(0)))
        }
        return switch saving {
        case .whole: String(localized: "Saved")
        case .part: String(localized: "Partly Saved")
        case .unsaved: String(localized: "Not saved")
        }
    }
}
