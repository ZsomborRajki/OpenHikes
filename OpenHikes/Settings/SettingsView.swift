//
//  SettingsView.swift
//  OpenHikes
//
//  The profile/settings sheet reached from the button next to the search bar.
//  Hosts a (future) Apple sign-in, the map tile-provider selector, the
//  cellular-download and background-tracking switches, and the offline tile
//  storage readout.
//

import SwiftData
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct SettingsView: View {
    @Environment(\.dismiss)
    private var dismiss
    @Environment(\.modelContext)
    private var modelContext
    @Query private var hikes: [Hike]

    /// Needed to fold in tiles auto-saved since the last drain before anything
    /// here reads the manifests — this screen both measures and deletes by them.
    let autoSave: AutoSaveController
    let backgroundTracker: BackgroundTrailTracker

    @AppStorage(SettingsKey.tileProviderID)
    private var tileProviderID = TileProvider.default.id
    @AppStorage(SettingsKey.backgroundTrackingEnabled)
    private var backgroundTrackingEnabled = false
    @AppStorage(SettingsKey.cellularTileDownloads)
    private var cellularTileDownloads = SettingsDefault.cellularTileDownloads

    private static let disabledOpacity: Double = 0.55

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
                dataUseSection
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
        .accessibilityIdentifier("settings-screen")
    }

    // MARK: Account

    private var accountSection: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Not signed in")
                        .font(.headline)
                    Text("Sign in to sync your hikes across devices.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)

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
        .opacity(Self.disabledOpacity)
        .allowsHitTesting(false)
        // Faded and un-tappable is a visual-only "not yet"; the badge has to
        // be read out alongside the row it disables.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sign in with Apple")
        .accessibilityValue("Coming soon")
    }

    // MARK: Map tiles

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
                    Text(
                        "Sources marked \u{201C}Needs API key\u{201D} aren't available in this build."
                        + " Adding one is a build-time step — see Secrets.example.plist in the project."
                    )
                }
            }
        }
    }

    // MARK: Data use

    /// The one energy control worth exposing. Everything else the app does
    /// about battery — backing the GPS off in Low Power Mode, dropping
    /// speculative tile traffic when the device is throttling — follows a
    /// system signal the user has already given somewhere else, and a second
    /// switch for it here would only be a way to contradict them.
    ///
    /// Low Data Mode is deliberately not represented: it is honoured
    /// unconditionally by ``TileNetworkPolicy``, and a toggle implying it
    /// could be overridden would be a lie.
    private var dataUseSection: some View {
        Section {
            Toggle("Download Maps on Cellular", isOn: cellularTileBinding)
                .accessibilityIdentifier("cellular-tiles-toggle")
        } header: {
            Text("Data Use")
        } footer: {
            Text(
                "Turning this off keeps map tiles coming from what's already saved on"
                + " your device while you're on cellular, which is the cheapest thing"
                + " a hike can do for its battery. Downloads resume on Wi-Fi."
            )
        }
    }

    private var cellularTileBinding: Binding<Bool> {
        Binding(
            get: { cellularTileDownloads },
            set: { newValue in
                cellularTileDownloads = newValue
                // Pushed as well as stored: `TileCache` reads this per tile
                // miss from a background queue and caches it, so the write
                // above alone would not reach it until the next launch.
                TileCache.shared.setAllowsCellularDownloads(newValue)
            }
        )
    }

    // MARK: Background tracking

    /// iOS-only: this is what feeds the Home Screen widget while OpenHikes
    /// isn't open. Off by default — turning it
    /// on is what first triggers the system's Always-location prompt.
    @ViewBuilder private var backgroundTrackingSection: some View {
        #if os(iOS)
        Section {
            Toggle("Background Trail Tracking", isOn: backgroundTrackingBinding)
            if backgroundTrackingEnabled, UIApplication.shared.backgroundRefreshStatus != .available {
                Label(
                    "Background App Refresh is off, so this may not update while OpenHikes is closed.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        } header: {
            Text("Background Tracking")
        } footer: {
            Text(
                "Keeps your Home Screen widget showing your progress along the selected trail"
                + " even when OpenHikes isn't open, using occasional, low-power location updates."
            )
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

    // MARK: Offline

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
                Button("Cancel", role: .cancel) { /* intentionally empty */ }
            } message: {
                Text(
                    "Your hikes lose their offline maps, and the map cache is cleared too."
                    + " Tiles re-download when you view maps online again."
                )
            }
        } header: {
            Text("Offline Storage")
        } footer: {
            Text(
                "Saved tiles keep your hikes usable without a signal, and are never removed automatically."
                + " The map cache is just what you've recently looked at — it's kept under"
                + " \(Self.byteText(TileCache.cacheByteLimit)), oldest first,"
                + " and clearing it costs you nothing offline."
            )
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        // "…" is a placeholder a screen reader has no way to interpret.
        .accessibilityValue(bytes.map(Self.byteText) ?? "Measuring")
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
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)

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
        .opacity(isUsable ? 1 : Self.disabledOpacity)
        .disabled(!isUsable)
        // Which provider is in use was drawn as a checkmark and nothing else,
        // and that checkmark is hidden from VoiceOver as decoration — so the
        // selection was unreadable without it.
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("provider-row-\(provider.id)")
    }
}

// MARK: - Offline storage

/// The disk accounting behind the storage section: snapshotting claims on
/// the main actor, then measuring and deleting off it. Kept apart from the
/// view above because none of it draws anything.
private extension SettingsView {
    /// Snapshots every hike's claims on the main actor so the expensive part —
    /// enumerating each one's tile grid — can run off it. Mirrors the delete
    /// path in ``MapSheet``.
    func claimSnapshots() -> [TileOwnership] {
        // Tiles auto-saved in the last couple of seconds are on disk with
        // nothing in SwiftData pointing at them yet. Unflushed, they measure as
        // cache and — worse — a cache clear would delete them.
        autoSave.flushPendingKeys()
        return hikes.filter(\.hasStoredTiles).map(TileOwnership.init)
    }

    func refreshUsage() async {
        usage = await Self.diskUsage(claimedBy: claimSnapshots())
    }

    /// Both storage actions below report by re-measuring, never by assuming.
    ///
    /// They used to write the expected result into `usage` before the detached
    /// delete had run, and nothing refreshed afterwards — so a delete that
    /// failed, or freed less than expected, left the screen claiming zero bytes
    /// until the sheet was reopened. `nil` in the meantime is the "…" the rows
    /// already show before the first measurement, which also disables the
    /// buttons while the work is in flight.
    func reportingUsage(_ work: @escaping @Sendable () async -> Void) {
        usage = nil
        Task(priority: .utility) {
            await work()
            await refreshUsage()
        }
    }

    func clearMapCache() {
        let claims = claimSnapshots()
        reportingUsage { await Self.removeTiles(unclaimedBy: claims) }
    }

    func deleteAllTiles() {
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

        reportingUsage { await Self.removeAllTiles() }
    }

    /// The union is O(tile budget) trig per download record, so it belongs
    /// inside the `@concurrent` measurements and deletions below rather than
    /// on the way in.
    nonisolated static func keys(
        of claims: [TileOwnership]
    ) throws(CancellationError) -> Set<String> {
        var keys = Set<String>()
        for claim in claims {
            keys.formUnion(try claim.tileKeys())
        }
        return keys
    }

    /// The three storage jobs, each `@concurrent` so they run on the concurrent
    /// executor while staying in the caller's task — a `Task` started from this
    /// main-actor view would otherwise inherit its isolation and put the trig,
    /// the `stat` calls and the deletions straight back on the main thread.
    ///
    /// A cancelled key enumeration deletes nothing rather than a partial set:
    /// cache keys carry no hike identity, so an under-reported claim set frees
    /// tiles that a surviving hike still needs.
    @concurrent nonisolated
    static func diskUsage(
        claimedBy claims: [TileOwnership]
    ) async -> TileCache.DiskUsage? {
        guard let keys = try? keys(of: claims) else { return nil }
        return TileCache.shared.diskUsage(claimedBy: keys)
    }

    @concurrent nonisolated
    static func removeTiles(unclaimedBy claims: [TileOwnership]) async {
        guard let keys = try? keys(of: claims) else { return }
        TileCache.shared.removeTiles(unclaimedBy: keys)
    }

    @concurrent nonisolated
    static func removeAllTiles() async {
        TileCache.shared.removeAllTiles()
    }

    /// `nonisolated`: passed as a bare function reference to `Optional.map`,
    /// which (unlike a closure literal) doesn't inherit the view's actor
    /// isolation. Doesn't touch any actor-isolated state, so this is safe.
    nonisolated static func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

#Preview {
    let container: ModelContainer
    do {
        container = try ModelContainer(for: Hike.self, configurations: .init(isStoredInMemoryOnly: true))
    } catch {
        preconditionFailure("Failed to create preview container: \(error)")
    }
    return SettingsView(
        autoSave: AutoSaveController(),
        backgroundTracker: BackgroundTrailTracker(container: container)
    )
}
