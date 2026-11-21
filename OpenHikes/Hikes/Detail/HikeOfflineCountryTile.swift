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
//  download (``OfflineRouteCoverage``). A download that stopped says why,
//  and offers to try again from where it stopped.
//
//  Reads the countries from the app's model in the environment, so the hike
//  screen takes no new input; a preview, with no model, draws the tile
//  disabled. Which countries a trail crosses is worked out off the main
//  actor, once a line lands or the list changes, because it tests every
//  walked leg of the line against the outlines near it.
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
        // None to offer where the device's own list cannot be read: nothing
        // downloads then, and what it holds is not known.
        let missing = countries?.isAvailable == true
            ? coverage.crossed.filter { countries?.isInstalled($0.id) == false }
            : []
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
                if download.hasFailed {
                    Button("Try Again") {
                        Task { await countries.retry(download.country.id) }
                    }
                }
                Button("Cancel Download", role: .destructive) {
                    countries.cancel(download.country.id)
                }
            } else if let countries {
                ForEach(missing) { country in
                    let name = OfflineCountries.fullName(of: country)
                    Button("Download \(name) · \(OfflineCountryRow.bytes(countries.byteCount(of: country)))") {
                        countries.download(country)
                    }
                }
            }
        } message: {
            if let failure = Self.failure(of: download) {
                Text(OfflineCountryRow.message(for: failure))
            } else {
                Text("The OpenHikes map draws a downloaded country with no signal. Downloads use Wi-Fi.")
            }
        }
        .task(id: TaskKey(revision: line.revision, listed: countries?.listed.map(\.id) ?? [])) {
            guard let countries else { return }
            if countries.listPhase == .idle, countries.listed.isEmpty { await countries.refreshList() }
            guard let measured = try? await countries.coverage(alongRoute: line.current?.route ?? []),
                  !Task.isCancelled
            else { return }
            coverage = measured
        }
    }

    private static func failure(of download: OfflineCountryDownload?) -> OfflineCountries.Failure? {
        guard case let .failed(failure)? = download?.phase else { return nil }
        return failure
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
        } else if download?.hasFailed == true {
            ActionTile(tint: .red) {
                Image(systemName: "exclamationmark.circle")
                    .font(.title3)
                    .accessibilityHidden(true)
                Text("Offline").font(.caption2.weight(.medium))
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
        if saving != .whole, let failure = Self.failure(of: download) {
            return OfflineCountryRow.message(for: failure)
        }
        return switch saving {
        case .whole: String(localized: "Saved")
        case .part: String(localized: "Partly Saved")
        case .unsaved: String(localized: "Not saved")
        }
    }
}
