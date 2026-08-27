//
//  SettingsView.swift
//  OpenHikes
//
//  The profile/settings sheet reached from the button next to the search bar.
//  Hosts the iCloud sync section, the map tile-provider selector, the photo
//  and background-tracking switches, and the offline tile storage readout.
//
//  There is deliberately no data-use section. The app is meant to be walked
//  with rather than configured, so the choice between cellular and Wi-Fi is
//  made automatically by ``TileNetworkPolicy`` from conditions the system
//  already publishes — see its notes for why that is both cheaper and less
//  wrong than a switch the walker has to set before setting off.
//

import StoreKit
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

    /// Fetched on demand rather than held in a `@Query`.
    ///
    /// `@Query` is a `DynamicProperty`: it invalidates the view that *declares*
    /// it on any write to the queried type, whether or not the body reads the
    /// results. This body renders no hike at all — the hikes are wanted by the
    /// storage measurement and the two delete actions, none of which is a
    /// render — so the query was an input this screen did not want.
    ///
    /// Measured both ways before the change was kept, and it is worth being
    /// straight about the result: the `settings` scenario reads the same 2
    /// `SettingsBody` passes for Clear Cache with the query and without it,
    /// because that action's writes land in one transaction and SwiftData
    /// coalesces them into a single invalidation that the explicit state
    /// changes were already paying for. What the fetch removes is the *shape*
    /// — an unbounded number of invalidation sources, none of them visible at
    /// this screen — not a number anything currently reproduces.
    ///
    /// A fetch is also the more correct of the two. Every caller wants a
    /// snapshot at the moment it acts, and a fetch taken then cannot be a pass
    /// behind the store the way a captured query result can.
    private func fetchHikes() -> [Hike] {
        (try? modelContext.fetch(FetchDescriptor<Hike>())) ?? []
    }

    /// Needed to fold in tiles auto-saved since the last drain before anything
    /// here reads the manifests — this screen both measures and deletes by them.
    let autoSave: AutoSaveController
    let backgroundTracker: BackgroundTrailTracker
    let cloudSync: CloudSyncCoordinator
    let entitlement: MapEntitlementStore

    @AppStorage(SettingsKey.tileProviderID)
    private var tileProviderID = TileProvider.default.id
    @AppStorage(SettingsKey.backgroundTrackingEnabled)
    private var backgroundTrackingEnabled = false
    @AppStorage(SettingsKey.savePhotosToLibrary)
    private var savePhotosToLibrary = SettingsDefault.savePhotosToLibrary

    private static let disabledOpacity: Double = 0.55
    private static let badgeHorizontalPadding: CGFloat = 7
    private static let badgeVerticalPadding: CGFloat = 3
    private static let badgeTintOpacity: Double = 0.15

    /// Tile bytes on disk, split into offline coverage and browsing residue;
    /// `nil` until measured.
    @State private var usage: TileCache.DiskUsage?
    /// What the hikes' pictures cost on disk, thumbnails included; `nil` until
    /// measured. Separate from ``usage`` because it is measured from SwiftData
    /// rather than by enumerating a tile directory, and because a hike deleted
    /// while this sheet is open changes it without changing a tile count.
    @State private var photoBytes: Int64?
    @State private var showDeleteAll = false
    @State private var showPaywall = false
    @State private var showManageSubscription = false

    /// The provider the map is really drawing with, which is not always the
    /// stored one — see ``TileProvider/renderable(id:entitlement:)``. The
    /// attribution and the checkmark both follow this: showing Stadia's
    /// attribution over OpenStreetMap tiles would be wrong twice over.
    ///
    /// Reads `entitlement.state` rather than letting `renderable` default to
    /// the process-wide answer, so this recomputes when StoreKit resolves.
    private var selectedProvider: TileProvider {
        TileProvider.renderable(id: tileProviderID, entitlement: entitlement.state)
    }

    var body: some View {
        // This screen is a seven-section `Form` in one body, so every input it
        // takes costs all of it. The mark is how an input that follows a
        // *hike* would show up — a recording writing to its draft per fix, or
        // auto-save folding tile keys in every couple of seconds — since
        // neither of those is visible by reading the body, which mentions no
        // hike at all.
        RenderSignpost.mark("SettingsBody")
        return NavigationStack {
            Form {
                CloudSyncSection(sync: cloudSync)
                mapProviderSection
                photosSection
                backgroundTrackingSection
                offlineStorageSection
                FieldMetricsSection()
                contactSection
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
            .task { await refreshPhotoBytes() }
            // Presented from inside this sheet, which is itself presented from
            // inside `MapSheet` — the repository's rule about where a modal
            // has to live applies at every level.
            .sheet(isPresented: $showPaywall) {
                MapPaywallView(store: entitlement)
            }
        }
        .accessibilityIdentifier("settings-screen")
    }

    // MARK: Map tiles

    private var mapProviderSection: some View {
        Section {
            ForEach(TileProvider.all) { provider in
                providerRow(provider)
            }
            if entitlement.isEntitled {
                manageSubscriptionRow
            }
        } header: {
            Text("Map Tiles")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                TileAttributionView(attribution: selectedProvider.attribution)
                if selectedProvider.usesSystemBaseMap {
                    Text(
                        "OpenHikes downloads, caches and auto-saves no map tiles while this is"
                        + " selected, so it uses the least battery and data — but the map needs"
                        + " a signal where the system hasn't already cached it."
                        + " Tiles already saved by other sources are kept, and listed below."
                    )
                }
                if TileProvider.all.contains(where: { !Secrets.canLoadTiles($0) }) {
                    Text(
                        "Sources marked \u{201C}Needs API key\u{201D} aren't available in this build."
                        + " Adding one is a build-time step — see Secrets.example.plist in the project."
                    )
                }
                if !entitlement.isEntitled,
                   TileProvider.all.contains(where: \.requiresPaidAccess) {
                    Text(
                        "Sources marked \u{201C}Pro\u{201D} are commercial map services that bill"
                        + " OpenHikes for every map view, every month. Subscribing pays for that,"
                        + " and keeps the free OpenStreetMap option free."
                    )
                }
            }
        }
    }

    /// The way out, shown to a subscriber in the section their money unlocks.
    ///
    /// Apple already offers this in the system Settings app, but a
    /// subscription the app will not help you leave is both a support burden
    /// and a bad-faith one. `manageSubscriptionsSheet` opens the App Store's
    /// own sheet, so nothing here can misreport what is actually being billed.
    private var manageSubscriptionRow: some View {
        Button {
            showManageSubscription = true
        } label: {
            LabeledContent("Pro Maps", value: "Subscribed")
        }
        .accessibilityIdentifier("manage-subscription-row")
        .accessibilityHint("Opens the App Store subscription settings.")
        #if os(iOS)
        .manageSubscriptionsSheet(isPresented: $showManageSubscription)
        #endif
    }

    // MARK: Photos

    /// The one switch behind photo-library access.
    ///
    /// Off by default, and flipping it on asks for nothing: the prompt comes
    /// with the first photo actually saved, where the request is about
    /// something the user is doing rather than something they might do. The
    /// app's own copy is written either way, which is what the footer says —
    /// otherwise "off" reads as "photos aren't kept".
    private var photosSection: some View {
        Section {
            Toggle("Also Save to Photos", isOn: $savePhotosToLibrary)
                .accessibilityIdentifier("save-photos-to-library-toggle")
        } header: {
            Text("Photos")
        } footer: {
            Text(
                "Photos you take on a hike are always kept in OpenHikes and shown"
                + " with that hike. Turn this on to put a copy in your photo library"
                + " too, in an album called \"OpenHikes\". You'll be asked for"
                + " permission the first time one is saved."
            )
        }
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
            // Read-only, deliberately: a photo is the one thing in this app
            // that cannot be re-fetched, so there is no "clear" beside it.
            // It is here because it was the only sizeable thing the app wrote
            // to disk with no number anywhere in the UI.
            usageRow(
                "Photos",
                systemImage: "photo.on.rectangle",
                bytes: photoBytes
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
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    "Saved tiles keep your hikes usable without a signal. The map cache is just"
                    + " what you've recently looked at — it's kept under"
                    + " \(Self.byteText(TileCache.cacheByteLimit)), oldest first,"
                    + " and clearing it costs you nothing offline."
                    + " Photos are only removed when you delete them, or the hike they belong to."
                )
                if let capped = Self.cappedProviders.first {
                    // Named rather than described in general terms: a ceiling
                    // that isn't the phone's free space needs to say whose it
                    // is, or it reads as a bug.
                    Text(
                        "\(capped.name)'s licence allows"
                        + " \(Self.byteText(capped.durableByteLimit ?? 0)) of saved tiles on this"
                        + " device. Once that's used, saving a new route asks before replacing"
                        + " your least-recently-used saved tiles. Other sources are unlimited."
                    )
                }
            }
        }
    }

    /// The sources whose terms cap durable storage. A tuple of `TileProvider`
    /// rather than a `Bool`, so the footer can name the one it means.
    private static var cappedProviders: [TileProvider] {
        TileProvider.all.filter { $0.durableByteLimit != nil }
    }

    // MARK: Contact

    private var contactSection: some View {
        Section {
            Link(destination: URL(string: "https://github.com/ZsomborRajki/OpenHikes")!) {
                Label("Project on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .accessibilityIdentifier("project-github-link")
        } header: {
            Text("Contact & Feedback")
        } footer: {
            Text("Share feedback, suggestions, or report an issue on GitHub.")
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
    ///
    /// A locked commercial source is shown for the opposite reason: it *is*
    /// available, just not yet bought, so tapping it opens the paywall rather
    /// than doing nothing. Locking waits for `entitlement.state.isResolved`,
    /// so a paying user's row never flips from unlocked to locked under their
    /// finger while StoreKit is still answering.
    private func providerRow(_ provider: TileProvider) -> some View {
        let isUsable = Secrets.canLoadTiles(provider)
        let isLocked = provider.requiresPaidAccess
            && entitlement.state.isResolved
            && !entitlement.isEntitled
        // Against the *effective* provider, so a stored id that has since lost
        // its key doesn't leave a checkmark on a row the map is ignoring.
        let isSelected = provider.id == selectedProvider.id
        return Button {
            if isLocked {
                showPaywall = true
            } else {
                tileProviderID = provider.id
            }
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
                            badge("Needs API key")
                        } else if isLocked {
                            badge("Pro", tinted: true)
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
        // The badge is a `Text` inside a composite row, so it is spoken only
        // if the row says it: "Pro" alone would also not explain that the
        // tap opens a purchase screen rather than switching the map.
        .accessibilityHint(isLocked ? "Requires OpenHikes Pro. Opens the unlock screen." : "")
        .accessibilityIdentifier("provider-row-\(provider.id)")
    }

    private func badge(_ title: String, tinted: Bool = false) -> some View {
        Text(title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tinted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .padding(.horizontal, Self.badgeHorizontalPadding)
            .padding(.vertical, Self.badgeVerticalPadding)
            .background(
                tinted
                    ? AnyShapeStyle(.tint.opacity(Self.badgeTintOpacity))
                    : AnyShapeStyle(.quaternary),
                in: Capsule()
            )
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
        return fetchHikes().filter(\.hasStoredTiles).map(TileOwnership.init)
    }

    func refreshUsage() async {
        usage = await Self.diskUsage(claimedBy: claimSnapshots())
    }

    /// Measured off the main actor for the same reason the tile numbers are:
    /// ``HikePhotoStore/byteCount(of:)`` stats two files per photo and asserts
    /// it is not on the main thread. The photos are snapshotted here, where
    /// reading SwiftData is legal, and only the array crosses.
    func refreshPhotoBytes() async {
        photoBytes = await Self.photoByteCount(
            of: fetchHikes().flatMap(\.photos).map(HikePhotoStore.PhotoFiles.init)
        )
    }

    @concurrent
    static func photoByteCount(of files: [HikePhotoStore.PhotoFiles]) async -> Int64 {
        HikePhotoStore.shared.byteCount(of: files)
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

        for hike in fetchHikes() {
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
    @concurrent
    static func diskUsage(
        claimedBy claims: [TileOwnership]
    ) async -> TileCache.DiskUsage? {
        guard let keys = try? keys(of: claims) else { return nil }
        return TileCache.shared.diskUsage(claimedBy: keys)
    }

    @concurrent
    static func removeTiles(unclaimedBy claims: [TileOwnership]) async {
        guard let keys = try? keys(of: claims) else { return }
        TileCache.shared.removeTiles(unclaimedBy: keys)
    }

    @concurrent
    static func removeAllTiles() async {
        TileCache.shared.removeAllTiles()
    }

    /// `nonisolated`: passed as a bare function reference to `Optional.map`,
    /// which (unlike a closure literal) doesn't inherit the view's actor
    /// isolation. Doesn't touch any actor-isolated state, so this is safe.
    nonisolated static func byteText(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }
}

#Preview {
    let container: ModelContainer
    do {
        container = try ModelContainer.openHikes(isStoredInMemoryOnly: true)
    } catch {
        preconditionFailure("Failed to create preview container: \(error)")
    }
    return SettingsView(
        autoSave: AutoSaveController(),
        backgroundTracker: BackgroundTrailTracker(container: container),
        cloudSync: CloudSyncCoordinator(defaults: .standard, isSyncingThisLaunch: false),
        entitlement: MapEntitlementStore(currentEntitlements: { false })
    )
}
