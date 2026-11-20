//
//  OfflineCountryRow.swift
//  OpenHikes
//
//  One area in *Offline Maps*: its name, what it costs or how far its
//  download has come, and the one thing to do with it next. The only view
//  that reads a download's progress, so a tick re-runs this row and nothing
//  above it (*Render isolation, in practice*).
//

import SwiftUI

struct OfflineCountryRow: View {
    let country: OfflineCountryManifest.Country
    let countries: OfflineCountries
    /// Whether a region is named with its country, as it is anywhere but
    /// under that country.
    var namesCountry = true
    let isSelected: Bool
    /// Whether the list stands over the map, where a row is the hike
    /// detail's card rather than the system's — see ``background``.
    var isOverMap = false
    /// Shows the country on the map, where there is one behind the list.
    let onSelect: () -> Void

    var body: some View {
        let download = countries.downloads[country.id]
        HStack(spacing: 12) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(namesCountry ? OfflineCountries.fullName(of: country) : OfflineCountries.name(of: country))
                        .foregroundStyle(.primary)
                    status(download)
                        .font(.footnote)
                        .foregroundStyle(download?.hasFailed == true ? .red : .secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier("offline-country-\(country.id)")
            action(download)
        }
        .listRowBackground(background.map { Rectangle().fill($0) })
        .swipeActions { removal(of: download) }
        .contextMenu { removal(of: download) }
    }

    /// What takes the row's area off the device: *Delete* for one that is
    /// downloaded, and for a download that stopped, the cancel its ring
    /// offered while it ran. Without the second a download that can never
    /// finish stayed on its row for good.
    @ViewBuilder
    private func removal(of download: OfflineCountryDownload?) -> some View {
        if download?.hasFailed == true {
            Button("Cancel Download", systemImage: "xmark", role: .destructive) {
                countries.cancel(country.id)
            }
        }
        if countries.isInstalled(country.id) {
            Button("Delete", systemImage: "trash", role: .destructive) {
                countries.delete(country.id)
            }
        }
    }

    @ViewBuilder
    private func status(_ download: OfflineCountryDownload?) -> some View {
        if let download {
            switch download.phase {
            case .waitingForWiFi: Text("Waiting for Wi-Fi")
            case .downloading:
                Text("\(Self.bytes(download.writtenBytes)) of \(Self.bytes(download.byteCount))")
            case .checking: Text("Checking…")
            case let .failed(failure): Text(Self.message(for: failure))
            }
        } else if let update = countries.update(for: country.id) {
            Text("Update available · \(Self.bytes(countries.byteCount(of: update)))")
        } else if let record = countries.installed[country.id] {
            Text("Downloaded · \(Self.bytes(record.byteCount))")
        } else {
            Text(Self.bytes(countries.byteCount(of: country)))
        }
    }

    @ViewBuilder
    private func action(_ download: OfflineCountryDownload?) -> some View {
        let name = OfflineCountries.name(of: country)
        if let download, !download.hasFailed {
            if download.phase == .checking {
                ProgressView()
                    .minimumTapTarget()
            } else {
                Button {
                    countries.cancel(country.id)
                } label: {
                    OfflineCountryProgressRing(fraction: download.fraction)
                }
                .buttonStyle(.plain)
                .minimumTapTarget()
                .accessibilityLabel("Cancel Download")
                .accessibilityValue(download.fraction.formatted(.percent.precision(.fractionLength(0))))
            }
        } else if download?.hasFailed == true {
            glyphButton("Try Again", systemImage: "arrow.clockwise") {
                Task { await countries.retry(country.id) }
            }
        } else if let update = countries.update(for: country.id) {
            Button("Update") { countries.download(update) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Update \(name)")
        } else if countries.isInstalled(country.id) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
                .accessibilityHidden(true)
        } else {
            glyphButton("Download \(name)", systemImage: "arrow.down.circle") {
                countries.download(country)
            }
        }
    }

    private func glyphButton(
        _ label: LocalizedStringResource,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
        }
        .buttonStyle(.borderless)
        .minimumTapTarget()
        .accessibilityLabel(Text(label))
    }

    /// The chosen row's tint, or else the card the list's other rows stand
    /// on: the hike detail's over the map — see
    /// ``SwiftUICore/View/placeCardRows(_:)`` — and the system's, `nil`, in
    /// Settings.
    ///
    /// Spelled out here rather than left to the list's `placeCardRows`: a
    /// row's own background is the one drawn, even `nil`, which is the
    /// system's card, and that is opaque on the side panel.
    private var background: AnyShapeStyle? {
        if isSelected {
            AnyShapeStyle(Color.accentColor.opacity(Self.selectedTint))
        } else if isOverMap {
            AnyShapeStyle(.quaternary)
        } else {
            nil
        }
    }

    /// How strongly the chosen row is tinted, as the outline on the map is.
    private static let selectedTint = 0.12

    static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }

    static func message(for failure: OfflineCountries.Failure) -> String {
        switch failure {
        case .connection: String(localized: "Couldn’t download. Try again on Wi-Fi.")
        case .space: String(localized: "Not enough free space.")
        case .damaged: String(localized: "The download was damaged. Try again.")
        case .conserving: String(localized: "Turn off Low Power Mode or let the device cool, then try again.")
        }
    }
}

/// How far a download has come, as a ring with a stop square in it, which
/// is what cancelling it looks like everywhere on the system.
struct OfflineCountryProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(Self.trackOpacity), lineWidth: Self.lineWidth)
            Circle()
                .trim(from: 0, to: max(fraction, Self.visibleMinimum))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.accentColor)
                .frame(width: Self.stopSide, height: Self.stopSide)
        }
        .frame(width: Self.side, height: Self.side)
        .animation(.default, value: fraction)
    }

    private static let side: CGFloat = 24
    private static let stopSide: CGFloat = 8
    private static let lineWidth: CGFloat = 2.5
    private static let trackOpacity = 0.3
    /// A sliver of ring from the start, so a download that has not moved yet
    /// still reads as one.
    private static let visibleMinimum = 0.02
}
