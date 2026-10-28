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
//  wrong than a switch the hiker has to set before setting off.
//

import OpenHikesData
import StoreKit
import SwiftData
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext

    /// Fetched on demand rather than held in a `@Query`.
    ///
    /// `@Query` is a `DynamicProperty`: it invalidates the view that *declares*
    /// it on any write to the queried type, whether or not the body reads the
    /// results. This body renders no hike at all — the hikes are wanted by the
    /// storage measurement and the two delete actions, none of which is a
    /// render — so the query was an input this screen did not want.
    ///
    /// Measured both ways before the change was kept, and it is worth being
    /// straight about the result: Clear Cache cost the same two body passes of
    /// this screen with the query and without it, because that action's writes
    /// land in one transaction and SwiftData coalesces them into a single
    /// invalidation that the explicit state changes were already paying for.
    /// What the fetch removes is the *shape* — an unbounded number of
    /// invalidation sources, none of them visible at this screen — not a
    /// number anything currently reproduces.
    ///
    /// A fetch is also the more correct of the two. Every caller wants a
    /// snapshot at the moment it acts, and a fetch taken then cannot be a pass
    /// behind the store the way a captured query result can.
    ///
    /// It throws for the reason the launch sweeps' fetch does: two of the
    /// three callers spend the result as a tile *claim set*, and `?? []` is
    /// not a cautious reading of a failed fetch there — it is the reading that
    /// says every tile on the device is unclaimed.
    private func fetchHikes() throws -> [Hike] {
        try modelContext.fetch(FetchDescriptor<Hike>())
    }

    /// Needed to fold in tiles auto-saved since the last drain before anything
    /// here reads the manifests — this screen both measures and deletes by them.
    let autoSave: AutoSaveController
    let backgroundTracker: BackgroundTrailTracker
    /// Only for the authorization it reports — see
    /// ``BackgroundTrackingSection``.
    let locationManager: LocationManager
    /// The community authors this device has blocked. Drawn by
    /// ``BlockedHikersSection``, which is absent while the list is empty.
    let blocks: CommunityBlockList
    let cloudSync: CloudSyncCoordinator
    let entitlement: MapEntitlementStore

    @AppStorage(SettingsKey.tileProviderID) private var tileProviderID = TileProvider.default.id
    @AppStorage(SettingsKey.showsHikingRoutes) private var showsHikingRoutes = SettingsDefault.showsHikingRoutes
    @AppStorage(SettingsKey.liveActivitiesEnabled) private var liveActivitiesEnabled =
        SettingsDefault.liveActivitiesEnabled
    @AppStorage(SettingsKey.savePhotosToLibrary) private var savePhotosToLibrary = SettingsDefault.savePhotosToLibrary
    @AppStorage(SettingsKey.movementRemindersEnabled) private var movementRemindersEnabled =
        SettingsDefault.movementRemindersEnabled
    @AppStorage(SettingsKey.keepScreenAwake) private var keepScreenAwake = SettingsDefault.keepScreenAwake
    @AppStorage(SettingsKey.savesHikesToHealth) private var savesHikesToHealth = SettingsDefault.savesHikesToHealth

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
    /// attribution and the selected card both follow this: showing Stadia's
    /// attribution over OpenStreetMap tiles would be wrong twice over.
    ///
    /// Reads `entitlement.state` rather than letting `renderable` default to
    /// the process-wide answer, so this recomputes when StoreKit resolves.
    private var selectedProvider: TileProvider {
        TileProvider.renderable(id: tileProviderID, entitlement: entitlement.state)
    }

    var body: some View {
        // This screen is a `Form` of eleven sections in one body, so every
        // input it takes costs all of it. An input that follows a *hike* — a
        // recording writing to its draft per fix, or auto-save folding tile
        // keys in every couple of seconds — would be the expensive one, and
        // neither is visible by reading the body, which mentions no hike at
        // all.
        NavigationStack {
            Form {
                CloudSyncSection(sync: cloudSync)
                mapProviderSection
                photosSection
                healthSection
                BackgroundTrackingSection(
                    tracker: backgroundTracker,
                    locationManager: locationManager
                )
                liveActivitySection
                movementReminderSection
                displaySection
                offlineStorageSection
                // Below the app's own switches and above the about links,
                // which is where somebody looks for it: it is not a setting
                // they turn on, it is a list of decisions they already made,
                // and it sits next to the other thing the community feature
                // put in this screen's reach.
                BlockedHikersSection(blocks: blocks)
                // The paywall's second entry point, and the only one a build
                // with no `Secrets.plist` still has — the provider rows that
                // used to be its sole route are disabled outright there. Not
                // drawn for a subscriber, who has `manageSubscriptionRow`
                // above and for whom `MapPaywallView` dismisses itself the
                // moment it opens.
                //
                // `isEntitled` is false while StoreKit is still answering, so
                // the row is present in that window rather than missing from
                // it. That is the right way round: the cost of showing it to
                // somebody who turns out to be subscribed is a sheet that
                // closes itself, and the cost of hiding it is the dead end
                // this whole section is here to remove.
                AboutSection(
                    showPro: entitlement.isEntitled ? nil : { showPaywall = true }
                )
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                // Trailing rather than `.confirmationAction`, which would draw
                // the system ✕ in the prominent tint of a Save.
                ToolbarItem(placement: .topBarTrailing) {
                    // A view rather than `Button(role: .close) { dismiss() }`:
                    // a `.toolbar` closure is inlined into the body around it,
                    // and this body is the whole `Form` above. See
                    // ``DismissButton`` for what the environment's dismiss
                    // action costs a screen that declares it.
                    DismissButton()
                        .accessibilityIdentifier("settings-close")
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
            MapStylePicker(
                tileProviderID: $tileProviderID,
                selected: selectedProvider,
                entitlement: entitlement,
                locationManager: locationManager,
                showPaywall: { showPaywall = true }
            )
            // Edge to edge, so the row scrolls out from under the section's
            // rounded corners rather than stopping short of them.
            .listRowInsets(EdgeInsets())
            // Waymarked Trails' hiking routes over whichever map is chosen
            // above — a layer rather than a sixth card, because it is drawn
            // with any of them.
            HikingRoutesToggle()
            if entitlement.isEntitled {
                manageSubscriptionRow
            }
        } header: {
            Text("Map Tiles")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                // The map's credits and the layer's, as the line on the map
                // draws them, then every other source a card above shows
                // imagery from: a card is that provider's imagery too.
                if let drawn = TileAttribution.drawn(
                    base: selectedProvider.attribution,
                    layer: TileLayer.shown(isOn: showsHikingRoutes)?.attribution
                ) {
                    TileAttributionView(attribution: drawn.including(
                        previews: TileProvider.all.filter(Secrets.canLoadTiles).map(\.attribution)
                    ))
                }
                // What each map saves for offline use is said once, in the
                // selected map's summary above, rather than again down here.
                if TileProvider.all.contains(where: { !Secrets.canLoadTiles($0) }) {
                    // A sentence a hiker can act on, and — under `#if DEBUG`
                    // — the one a contributor needs. It used to be the second
                    // half alone, which named a file in the project to
                    // whoever was reading it. That is a contributor's
                    // instruction shown to a customer, and it could only ever
                    // appear in a build where the paid rows are dead, which
                    // is the build this text most needs to not read like a
                    // half-finished app.
                    Text("Maps marked \u{201C}Needs API key\u{201D} aren’t available in this build.")
                    #if DEBUG
                    // Verbatim: only a contributor reads it, so it is not
                    // for translation, and Xcode's own catalog sync leaves
                    // `#if DEBUG` code out and deleted the key on every build.
                    Text(verbatim: "Adding one is a build-time step — see Secrets.example.plist in the project.")
                    #endif
                }
                if !entitlement.isEntitled,
                   TileProvider.all.contains(where: \.requiresPaidAccess) {
                    Text("Maps with a lock need OpenHikes Pro.")
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
            LabeledContent("OpenHikes Pro", value: String(localized: "Subscribed"))
        }
        .accessibilityIdentifier("manage-subscription-row")
        .accessibilityHint("Opens the App Store subscription settings.")
        #if os(iOS)
        .manageSubscriptionsSheet(isPresented: $showManageSubscription)
        #endif
    }

    // MARK: Photos

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
                Text("""
                Your hikes lose their offline maps, and the map cache is cleared too. Tiles \
                re-download when you view maps online again.
                """)
            }
        } header: {
            Text("Offline Storage")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("""
                Saved maps keep your hikes usable without a signal. The map cache holds recently \
                viewed maps, up to \(Self.byteText(TileCache.cacheByteLimit)). Clearing it doesn’t \
                touch saved maps.
                """)
                if let quota = DurableTileQuota.all.first {
                    // Named rather than described in general terms: a ceiling
                    // that isn't the phone's free space needs to say whose it
                    // is, or it reads as a bug. And the styles are listed,
                    // because one figure covering two of them is the part
                    // nobody would guess.
                    Text("""
                    The \(quota.holder) license allows \(Self.byteText(quota.byteLimit)) of saved maps \
                    on this device, shared by \(quota.providers.map(\.name).formatted(.list(type: .and))). \
                    Other map styles have no limit.
                    """)
                }
            }
        }
    }

    /// `title` is a key so the names written at the call sites reach the
    /// String Catalog; a `String` was drawn by the verbatim overloads (#1028).
    private func usageRow(_ title: LocalizedStringKey, systemImage: String, bytes: Int64?) -> some View {
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
        .accessibilityValue(bytes.map(Self.byteText) ?? String(localized: "Measuring"))
    }
}

// MARK: - Photos

/// The photo-library switch. Out of the view's own body for length, and
/// otherwise a section like any other.
private extension SettingsView {
    /// The switch behind the photo-library mirror: the add-only access a
    /// camera photo's copy needs, not the read/write access *Find Photos*
    /// asks for on its own (see ``SettingsKey/savePhotosToLibrary``).
    ///
    /// Off by default, and flipping it on asks for nothing: the prompt comes
    /// with the first photo actually saved, where the request is about
    /// something the user is doing rather than something they might do. The
    /// app's own copy is written either way, which is what the footer says —
    /// otherwise "off" reads as "photos aren't kept".
    var photosSection: some View {
        Section {
            Toggle("Also Save to Photos", isOn: $savePhotosToLibrary)
                .accessibilityIdentifier("save-photos-to-library-toggle")
        } header: {
            Text("Photos")
        } footer: {
            Text("""
            Photos you take on a hike are always kept with the hike. Turn this on to also \
            save a copy to your photo library.
            """)
        }
    }
}

// MARK: - Health

/// The one switch that writes into a store belonging to another app.
private extension SettingsView {
    /// Off by default — see ``SettingsDefault/savesHikesToHealth``. Health is
    /// the hiker's most sensitive store and the app has no business writing to
    /// it because they recorded a walk.
    ///
    /// The footer says what goes and what a delete takes back, and nothing
    /// more. What is read — nothing on the phone — is the purpose string's to
    /// say, and the prompt comes at the first write rather than at the flick
    /// of this switch, as it does for *Also Save to Photos*. It promises
    /// nothing about Activity rings: the workout carries no energy, so whether
    /// it moves one is Health's call, not this app's.
    @ViewBuilder var healthSection: some View {
        #if os(iOS)
        Section {
            Toggle("Save Hikes to Health", isOn: $savesHikesToHealth)
                .accessibilityIdentifier("saves-hikes-to-health-toggle")
        } header: {
            Text("Health")
        } footer: {
            Text("""
            Saves each hike you record to the Health app as a hiking workout with its route. \
            Deleting the hike also removes the workout.
            """)
        }
        #endif
    }
}

// MARK: - Live Activities

/// The one switch the hiker owns over the Lock Screen banner. Kept out of the
/// view's own body for length; it is a section like any other.
private extension SettingsView {
    /// On by default — see ``SettingsDefault/liveActivitiesEnabled``. The
    /// switch is the app's half of the answer: a hiker who turned Live
    /// Activities off for OpenHikes in the system's own Settings sees nothing
    /// however this reads. The support page says so; the footer says only
    /// what the switch shows.
    @ViewBuilder var liveActivitySection: some View {
        #if os(iOS)
        Section {
            Toggle("Show on Lock Screen", isOn: $liveActivitiesEnabled)
                .accessibilityIdentifier("live-activities-toggle")
        } header: {
            Text("Live Activity")
        } footer: {
            Text("""
            Shows your distance, time and trail progress on the Lock Screen and in the \
            Dynamic Island while you record or follow a trail.
            """)
        }
        #endif
    }

}

// MARK: - Movement reminders

/// The switch over the banners a hike can put up. A section like any other,
/// kept out of the view's body for length.
private extension SettingsView {
    /// On by default — see ``SettingsDefault/movementRemindersEnabled``.
    ///
    /// One switch for every reminder ``MovementReminderController`` decides:
    /// resume and pause for a recording, resume for a walk, and the two a
    /// followed trail adds — off the trail, and finishing after dark. It was
    /// named for the first two alone and the other two arrived behind it, so
    /// it is named for all of them now, and the footer lists each in a clause.
    /// The fifteen minutes is ``MovementReminderPolicy/stillFor``. Severe
    /// weather is not behind this switch, and the footer does not claim it.
    @ViewBuilder var movementReminderSection: some View {
        #if os(iOS)
        Section {
            Toggle("Hike Reminders", isOn: $movementRemindersEnabled)
                .accessibilityIdentifier("movement-reminders-toggle")
        } header: {
            Text("Reminders")
        } footer: {
            Text("""
            Notifies you when you set off while a hike is paused, stop for 15 minutes while \
            recording, leave the trail you’re following, or may finish after dark.
            """)
        }
        #endif
    }
}

// MARK: - Display

/// The one switch that can cost a hiker battery rather than save it, and so
/// the one whose footer has to say what it costs.
private extension SettingsView {
    /// Off by default — see ``SettingsDefault/keepScreenAwake``. The footer
    /// names the scope because the scope is what makes the switch affordable:
    /// it holds the display only while a hike is live and the app is in
    /// front. A hiker who reads "keep the screen on" as "for the whole hike"
    /// would decline something they would in fact want.
    @ViewBuilder var displaySection: some View {
        #if os(iOS)
        Section {
            Toggle("Keep the Screen On", isOn: $keepScreenAwake)
                .accessibilityIdentifier("keep-screen-awake-toggle")
        } header: {
            Text("Display")
        } footer: {
            Text("""
            Keeps the screen on while you record or hike a trail with OpenHikes open. \
            This uses more battery.
            """)
        }
        #endif
    }
}

// MARK: - Offline storage

/// The disk accounting behind the storage section: snapshotting claims on
/// the main actor, then measuring and deleting off it. Kept apart from the
/// view above because none of it draws anything.
private extension SettingsView {
    /// The fetch the measurement and the cache clear take, with auto-save
    /// drained first.
    ///
    /// Tiles auto-saved in the last couple of seconds are on disk with nothing
    /// in SwiftData pointing at them yet. Unflushed, they measure as cache
    /// and — worse — a cache clear would delete them. Folded into the fetch so
    /// that it happens on the main actor at the moment the claims are taken,
    /// and so neither call site can forget it.
    func fetchHikesAfterFlush() throws -> [Hike] {
        autoSave.flushPendingKeys()
        return try fetchHikes()
    }

    /// Leaves `usage` alone — and so the rows at "…" and both buttons
    /// disabled — when the claims cannot be established. See
    /// ``OfflineStorageActions/measureDiskUsage(in:fetchingHikes:)``.
    func refreshUsage() async {
        guard let measurement = OfflineStorageActions.measureDiskUsage(
            in: .shared,
            fetchingHikes: fetchHikesAfterFlush
        ) else { return }
        usage = await measurement.value
    }

    /// Measured off the main actor for the same reason the tile numbers are:
    /// ``HikePhotoStore/byteCount(of:)`` stats two files per photo and asserts
    /// it is not on the main thread. The photos are snapshotted here, where
    /// reading SwiftData is legal, and only the array crosses.
    func refreshPhotoBytes() async {
        guard let hikes = try? fetchHikes() else { return }
        photoBytes = await Self.photoByteCount(
            of: hikes.flatMap(\.photos).map(HikePhotoStore.PhotoFiles.init)
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
    func reportingUsage(after sweep: Task<Void, Never>) {
        usage = nil
        Task(priority: .utility) {
            await sweep.value
            await refreshUsage()
        }
    }

    func clearMapCache() {
        guard let sweep = OfflineStorageActions.clearMapCache(
            in: .shared,
            fetchingHikes: fetchHikesAfterFlush
        ) else { return }
        reportingUsage(after: sweep)
    }

    func deleteAllTiles() {
        // Before the manifests are cleared: stopping auto-save folds in whatever
        // it saved since the last drain, which would otherwise land in a
        // manifest emptied a line later and claim tiles that are about to go.
        // Held onto so it can be resumed below — this is a storage action, not
        // a change to which hike is being saved.
        let resumed = autoSave.currentHike
        autoSave.hikeSelectionChanged(to: nil)

        let sweep = OfflineStorageActions.deleteAllTiles(in: .shared, fetchingHikes: fetchHikes)

        // Back on, with an empty manifest and a fresh cap, for whatever was
        // selected before — including on the path where the fetch failed and
        // nothing was cleared at all.
        autoSave.hikeSelectionChanged(to: resumed)

        guard let sweep else { return }
        reportingUsage(after: sweep)
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
        locationManager: LocationManager(),
        blocks: CommunityBlockList(),
        cloudSync: CloudSyncCoordinator(defaults: .standard, isSyncingThisLaunch: false),
        entitlement: MapEntitlementStore(currentEntitlements: { false })
    )
}
