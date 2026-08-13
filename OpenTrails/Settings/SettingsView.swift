//
//  SettingsView.swift
//  OpenTrails
//
//  The profile/settings sheet reached from the button next to the search bar.
//  Hosts a (future) Apple sign-in and the map tile-provider selector.
//

import SwiftUI
import SwiftData
#if os(iOS)
import UIKit
#endif

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var hikes: [Hike]

    /// Needed to fold in tiles auto-saved since the last drain before anything
    /// here reads the manifests — this screen both measures and deletes by them.
    let autoSave: AutoSaveController
    let backgroundTracker: BackgroundTrailTracker

    @AppStorage(SettingsKey.tileProviderID) private var tileProviderID = TileProvider.default.id
    @AppStorage(SettingsKey.backgroundTrackingEnabled) private var backgroundTrackingEnabled = false

    /// Tile bytes on disk, split into offline coverage and browsing residue;
    /// `nil` until measured.
    @State private var usage: TileCache.DiskUsage?
    @State private var showDeleteAll = false

    /// The provider the map is really drawing with, which is not always the
    /// stored one — see ``TileProvider/renderable(id:)``. The attribution and
    /// the checkmark both follow this: showing Stadia's attribution over
    /// OpenStreetMap tiles would be wrong twice over.
    private var selectedProvider: TileProvider {
        TileProvider.renderable(id: tileProviderID)
    }

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                mapProviderSection
                backgroundTrackingSection
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
            .task { await refreshUsage() }
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
            VStack(alignment: .leading, spacing: 6) {
                Text(selectedProvider.attribution)
                if TileProvider.all.contains(where: { !Secrets.canLoadTiles($0) }) {
                    Text("Sources marked “Needs API key” aren’t available in this build. Adding one is a build-time step — see Secrets.example.plist in the project.")
                }
            }
        }
    }

    // MARK: - Background tracking

    /// iOS-only: this is what feeds the Home Screen widget while OpenTrails
    /// isn't open. Off by default — turning it
    /// on is what first triggers the system's Always-location prompt.
    @ViewBuilder
    private var backgroundTrackingSection: some View {
        #if os(iOS)
        Section {
            Toggle("Background Trail Tracking", isOn: backgroundTrackingBinding)
            if backgroundTrackingEnabled && UIApplication.shared.backgroundRefreshStatus != .available {
                Label(
                    "Background App Refresh is off, so this may not update while OpenTrails is closed.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        } header: {
            Text("Background Tracking")
        } footer: {
            Text("Keeps your Home Screen widget showing your progress along the selected trail even when OpenTrails isn't open, using occasional, low-power location updates.")
        }
        #endif
    }

    private var backgroundTrackingBinding: Binding<Bool> {
        Binding(
            get: { backgroundTrackingEnabled },
            set: { newValue in
                backgroundTrackingEnabled = newValue
                backgroundTracker.setEnabled(newValue)
            }
        )
    }

    // MARK: - Offline

    /// Two numbers, not one: the tiles the hikes are keeping for offline use,
    /// and the ones the map merely happened to draw. They used to be added
    /// together and labelled "Downloaded tiles", which read as a single pile of
    /// deliberately-saved data and left the total permanently ahead of what any
    /// hike could account for — or delete.
    private var offlineStorageSection: some View {
        Section {
            usageRow(
                "Saved for offline",
                systemImage: "internaldrive",
                bytes: usage?.claimed
            )
            usageRow(
                "Map cache",
                systemImage: "clock.arrow.circlepath",
                bytes: usage?.unclaimed
            )

            Button("Clear Map Cache", action: clearMapCache)
                .disabled((usage?.unclaimed ?? 0) == 0)

            Button(role: .destructive) {
                showDeleteAll = true
            } label: {
                Text("Delete All Saved Tiles")
            }
            .disabled((usage?.total ?? 0) == 0)
            .confirmationDialog(
                "Delete every saved map tile?",
                isPresented: $showDeleteAll,
                titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) { deleteAllTiles() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your hikes lose their offline maps, and the map cache is cleared too. Tiles re-download when you view maps online again.")
            }
        } header: {
            Text("Offline Storage")
        } footer: {
            Text("Saved tiles keep your hikes usable without a signal, and are never removed automatically. The map cache is just what you’ve recently looked at — it’s kept under \(Self.byteText(TileCache.cacheByteLimit)), oldest first, and clearing it costs you nothing offline.")
        }
    }

    private func usageRow(_ title: String, systemImage: String, bytes: Int64?) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(bytes.map(Self.byteText) ?? "…")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    /// Snapshots every hike's claims on the main actor so the expensive part —
    /// enumerating each one's tile grid — can run off it. Mirrors the delete
    /// path in ``MapSheet``.
    private func claimSnapshots() -> [TileOwnership] {
        // Tiles auto-saved in the last couple of seconds are on disk with
        // nothing in SwiftData pointing at them yet. Unflushed, they measure as
        // cache and — worse — a cache clear would delete them.
        autoSave.flushPendingKeys()
        return hikes.filter(\.hasStoredTiles).map(TileOwnership.init)
    }

    private func refreshUsage() async {
        let claims = claimSnapshots()
        usage = await Task.detached {
            TileCache.shared.diskUsage(claimedBy: Self.keys(of: claims))
        }.value
    }

    /// Both storage actions below report by re-measuring, never by assuming.
    ///
    /// They used to write the expected result into `usage` before the detached
    /// delete had run, and nothing refreshed afterwards — so a delete that
    /// failed, or freed less than expected, left the screen claiming zero bytes
    /// until the sheet was reopened. `nil` in the meantime is the "…" the rows
    /// already show before the first measurement, which also disables the
    /// buttons while the work is in flight.
    private func reportingUsage(_ work: @escaping @Sendable () -> Void) {
        usage = nil
        Task {
            await Task.detached(operation: work).value
            await refreshUsage()
        }
    }

    private func clearMapCache() {
        let claims = claimSnapshots()
        reportingUsage { TileCache.shared.removeTiles(unclaimedBy: Self.keys(of: claims)) }
    }

    private func deleteAllTiles() {
        // Before the manifests are cleared: stopping auto-save folds in whatever
        // it saved since the last drain, which would otherwise land in a
        // manifest emptied a line later and claim tiles that are about to go.
        // Held onto so it can be resumed below — this is a storage action, not
        // a change to which hike is being saved.
        let resumed = autoSave.currentHike
        autoSave.hikeSelectionChanged(to: nil)

        for hike in hikes {
            hike.offlineDownloads.removeAll()
            hike.autoSavedTileKeys.removeAll()
            // `autoSaveTilesEnabled` is deliberately left alone. Reclaiming
            // disk is not a decision about whether a hike should keep saving
            // tiles, and this used to silently turn that setting off for every
            // hike the user had ever enabled it on.
        }

        // Back on, with an empty manifest and a fresh cap, for whatever was
        // selected before.
        autoSave.hikeSelectionChanged(to: resumed)

        reportingUsage { TileCache.shared.removeAllTiles() }
    }

    /// `nonisolated`: the union is O(tile budget) trig per download record, so
    /// it belongs inside the detached tasks above rather than on the way in.
    private static nonisolated func keys(of claims: [TileOwnership]) -> Set<String> {
        claims.reduce(into: Set<String>()) { $0.formUnion($1.tileKeys()) }
    }

    /// `nonisolated`: passed as a bare function reference to `Optional.map`,
    /// which (unlike a closure literal) doesn't inherit the view's actor
    /// isolation. Doesn't touch any actor-isolated state, so this is safe.
    private static nonisolated func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// A provider whose key didn't resolve is shown, but not selectable: it can
    /// only ever draw a blank map, and the previous behaviour — letting it be
    /// picked and leaving the user staring at nothing — gave no hint that a
    /// missing key was the reason.
    private func providerRow(_ provider: TileProvider) -> some View {
        let isUsable = Secrets.canLoadTiles(provider)
        // Against the *effective* provider, so a stored id that has since lost
        // its key doesn't leave a checkmark on a row the map is ignoring.
        let isSelected = provider.id == selectedProvider.id
        return Button {
            tileProviderID = provider.id
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(provider.name)
                            .font(.body.weight(.medium))
                        if !isUsable {
                            Text("Needs API key")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.quaternary, in: Capsule())
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
        .opacity(isUsable ? 1 : 0.55)
        .disabled(!isUsable)
    }
}

#Preview {
    let container = try! ModelContainer(for: Hike.self, configurations: .init(isStoredInMemoryOnly: true))
    SettingsView(
        autoSave: AutoSaveController(),
        backgroundTracker: BackgroundTrailTracker(container: container)
    )
}
