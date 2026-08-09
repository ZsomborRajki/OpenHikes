//
//  SettingsView.swift
//  OpenTrails
//
//  The profile/settings sheet reached from the button next to the search bar.
//  Hosts a (future) Apple sign-in and the map tile-provider selector.
//

import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var hikes: [Hike]

    @AppStorage(SettingsKey.tileProviderID) private var tileProviderID = TileProvider.default.id
    @AppStorage(SettingsKey.offlineMaxZoom) private var offlineMaxZoom = OfflineTileDownloader.defaultMaxZoom

    /// Total tile-cache size on disk; `nil` until measured.
    @State private var totalBytes: Int64?
    @State private var showDeleteAll = false

    private var selectedProvider: TileProvider {
        TileProvider.provider(id: tileProviderID)
    }

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                mapProviderSection
                offlineSection
                offlineStorageSection
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await refreshTotalBytes() }
        }
    }

    // MARK: - Account

    private var accountSection: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Not signed in")
                        .font(.headline)
                    Text("Sign in to sync your hikes across devices.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)

            appleSignInPlaceholder
        } header: {
            Text("Account")
        }
    }

    /// A disabled preview of Sign in with Apple — wired up in a future release.
    private var appleSignInPlaceholder: some View {
        HStack {
            Label("Sign in with Apple", systemImage: "apple.logo")
                .font(.body.weight(.medium))
            Spacer()
            Text("Coming soon")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
        }
        .foregroundStyle(.primary)
        .opacity(0.55)
        .allowsHitTesting(false)
    }

    // MARK: - Map tiles

    private var mapProviderSection: some View {
        Section {
            ForEach(TileProvider.all) { provider in
                providerRow(provider)
            }
        } header: {
            Text("Map Tiles")
        } footer: {
            Text(selectedProvider.attribution)
        }
    }

    // MARK: - Offline

    private var offlineSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Detail level", systemImage: "square.stack.3d.down.right")
                    Spacer()
                    Text("Zoom \(offlineMaxZoom)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: offlineZoomBinding,
                    in: zoomBounds,
                    step: 1
                ) {
                    Text("Offline detail level")
                } minimumValueLabel: {
                    Text("Less").font(.caption2).foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("More").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        } header: {
            Text("Offline Maps")
        } footer: {
            Text("How deep the “Offline” button saves tiles for a hike. Higher detail captures more of the trail up close, but uses more storage and downloads more slowly.")
        }
    }

    private var offlineStorageSection: some View {
        Section {
            HStack {
                Label("Downloaded tiles", systemImage: "internaldrive")
                Spacer()
                Text(totalBytes.map(Self.byteText) ?? "…")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Button(role: .destructive) {
                showDeleteAll = true
            } label: {
                Text("Delete All Offline Tiles")
            }
            .disabled((totalBytes ?? 0) == 0)
            .confirmationDialog(
                "Delete all downloaded map tiles?",
                isPresented: $showDeleteAll,
                titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) { deleteAllTiles() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Frees the storage they use. Tiles re-download automatically when you view maps online again.")
            }
        } header: {
            Text("Offline Storage")
        }
    }

    private func refreshTotalBytes() async {
        let bytes = await Task.detached { TileCache.shared.totalDiskBytes() }.value
        totalBytes = bytes
    }

    private func deleteAllTiles() {
        for hike in hikes {
            hike.offlineDownloads.removeAll()
            hike.autoSavedTileKeys.removeAll()
            hike.autoSaveTilesEnabled = false
        }
        AutoSaveTileStore.shared.clearActiveHike()
        totalBytes = 0
        Task.detached { TileCache.shared.removeAllTiles() }
    }

    /// `nonisolated`: passed as a bare function reference to `Optional.map`,
    /// which (unlike a closure literal) doesn't inherit the view's actor
    /// isolation. Doesn't touch any actor-isolated state, so this is safe.
    private static nonisolated func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Bridges the `Int` setting to the `Double`-valued slider.
    private var offlineZoomBinding: Binding<Double> {
        Binding(
            get: { Double(offlineMaxZoom) },
            set: { offlineMaxZoom = Int($0.rounded()) }
        )
    }

    private var zoomBounds: ClosedRange<Double> {
        Double(OfflineTileDownloader.zoomRange.lowerBound)...Double(OfflineTileDownloader.zoomRange.upperBound)
    }

    private func providerRow(_ provider: TileProvider) -> some View {
        let isSelected = provider.id == tileProviderID
        return Button {
            tileProviderID = provider.id
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(provider.name)
                            .font(.body.weight(.medium))
                        if provider.supportsBulkDownload {
                            Text("Offline")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.green.opacity(0.18), in: Capsule())
                        }
                    }
                    Text(provider.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}

#Preview {
    SettingsView()
}
