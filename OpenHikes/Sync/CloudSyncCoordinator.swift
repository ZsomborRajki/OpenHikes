//
//  CloudSyncCoordinator.swift
//  OpenHikes
//
//  The one object the rest of the app talks to about sync, and the only place
//  that decides whether sync should be running at all.
//
//  Four unrelated reasons make sync a no-op — the user turned it off, there is
//  no Apple Account on the device, this process is hosting a test bundle, or
//  the persistent store did not open and the app is running on the empty
//  in-memory fallback — and they all arrive here rather than being re-checked
//  at each call site. Everything below this line can then assume it was
//  started deliberately.
//
//  It also owns the one thing that would otherwise need a hook in every screen
//  that edits a hike: the SwiftData save notification. A title changed in the
//  detail view, a photo added from the map, a route saved by the recorder and
//  a hike imported from Files all end in the same `save`, so all four are
//  noticed by watching that instead of by remembering to call something.
//

import CloudKit
import CoreLocation
import Foundation
import Observation
import os
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
final class CloudSyncCoordinator {
    private static let logger = Logger(subsystem: "OpenHikes", category: "CloudSync")

    let status: CloudSyncStatus

    /// The user's switch. Persisted, and the only one of the three reasons
    /// sync might be off that the app itself decides.
    ///
    /// On by default. This is the person's own private iCloud storage, it is
    /// how every first-party app on the device behaves, and the alternative —
    /// a phone restored from backup showing an empty hikes list until its
    /// owner finds a switch — is the failure this feature exists to prevent.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: SettingsKey.cloudSyncEnabled)
            requestState(resetting: !isEnabled)
        }
    }

    @ObservationIgnored private let applier: HikeSyncApplier
    @ObservationIgnored private let engine: HikeSyncEngine
    @ObservationIgnored private let settings: SyncedSettingsMirror
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageIsDurable: Bool
    @ObservationIgnored private let cloudContainer: CKContainer
    @ObservationIgnored private var saveObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var accountObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var lifecycleObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private var stateTask: Task<Void, Never>?

    #if canImport(UIKit)
    @ObservationIgnored private var flushAssertion = UIBackgroundTaskIdentifier.invalid
    #endif

    /// - Parameter storageIsDurable: False when ``OpenHikesModel`` fell back
    ///   to its in-memory container because the persistent store would not
    ///   open. See ``canSync``.
    convenience init(
        container: ModelContainer,
        defaults: UserDefaults,
        storageIsDurable: Bool = true
    ) {
        let sharedStatus = CloudSyncStatus()
        let sharedApplier = HikeSyncApplier(container: container)
        self.init(
            applier: sharedApplier,
            engine: HikeSyncEngine(applier: sharedApplier, status: sharedStatus),
            settings: SyncedSettingsMirror(defaults: defaults),
            status: sharedStatus,
            defaults: defaults,
            storageIsDurable: storageIsDurable
        )
    }

    init(
        applier: HikeSyncApplier,
        engine: HikeSyncEngine,
        settings: SyncedSettingsMirror,
        status: CloudSyncStatus,
        defaults: UserDefaults,
        storageIsDurable: Bool = true,
        cloudContainer: CKContainer = CKContainer(
            identifier: CloudSyncSchema.containerIdentifier
        )
    ) {
        self.applier = applier
        self.engine = engine
        self.settings = settings
        self.status = status
        self.defaults = defaults
        self.storageIsDurable = storageIsDurable
        self.cloudContainer = cloudContainer
        isEnabled = defaults.object(forKey: SettingsKey.cloudSyncEnabled) as? Bool
            ?? SettingsDefault.cloudSyncEnabled
    }

    // MARK: - Lifecycle

    /// Starts watching for local changes and brings the engine up if it should
    /// be up.
    ///
    /// Behind the test guard for the same reason every other startup writer
    /// is: both unit-test bundles are hosted by the app, so this would
    /// otherwise reach for a real iCloud account, a real container and the
    /// user's real hikes underneath suites that own their own store.
    func start() {
        guard canSync else {
            status.paused()
            return
        }
        observeAccountChanges()
        observeSaves()
        observeAppLifecycle()
        requestState(resetting: false)
    }

    /// Re-checks iCloud and pulls anything waiting.
    ///
    /// Necessary because a CloudKit push is a best effort: the system drops
    /// them under pressure, and the Simulator cannot receive them at all. A
    /// foreground fetch is what makes those two cases indistinguishable from
    /// the working one.
    func sceneDidBecomeActive() {
        guard isEnabled else { return }
        requestState(resetting: false)
    }

    /// Whether sync may touch iCloud at all, for reasons that have nothing to
    /// do with the user's switch.
    ///
    /// The store matters as much as the test host does. When the persistent
    /// store will not open, ``OpenHikesModel`` falls back to an empty
    /// in-memory container for that launch — but this feature's bookkeeping
    /// lives in Application Support, is untouched by that failure, and still
    /// names every hike the device has uploaded. Syncing an empty library
    /// against it ends in the whole account being reconciled away, on that
    /// launch or the next one, and no relaunch undoes it.
    private var canSync: Bool {
        storageIsDurable && !AppLaunchEnvironment.isRunningTests
    }

    // MARK: - Local changes

    /// Queues a hike's removal while it can still say which photos were its
    /// own.
    ///
    /// Called from the same place, and in the same breath, as
    /// ``AutoSaveController/hikeWillBeDeleted(_:)`` and
    /// ``HikePhotoImport/discardFiles(of:store:)`` — a deleted `@Model` has
    /// nothing left to enumerate, so all three have to ask before rather than
    /// after.
    func hikeWillBeDeleted(_ hike: Hike) {
        // Deliberately not gated on ``isEnabled``. A hike deleted with sync
        // switched off is still a hike iCloud may hold a copy of, and turning
        // sync back on would download it again; the engine writes the
        // deletion down now and sends it whenever it next can.
        guard canSync else { return }
        let identifiers = applier.deletionIdentifiers(of: hike)
        guard !identifiers.isEmpty else { return }
        Task {
            await engine.enqueueDeletions(
                hikeIDs: identifiers.hikeIDs,
                photoIDs: identifiers.photoIDs
            )
        }
    }

    /// The photo files sync is holding onto that no `Hike` claims yet.
    ///
    /// Handed to the launch-time orphan sweep, which would otherwise delete
    /// the pixels of a photo still waiting for its hike — see
    /// ``CloudSyncStateStore/deferredPhotoFileNames()``.
    ///
    /// `nil` means "this launch cannot enumerate them", which must skip the
    /// sweep rather than shrink the claim set.
    func deferredPhotoClaims() async -> Set<String>? { // swiftlint:disable:this discouraged_optional_collection
        await engine.deferredPhotoClaims()
    }

    // MARK: - Observation

    private func observeSaves() {
        guard saveObserver == nil else { return }
        // `queue: nil` deliberately: the block then runs *synchronously* on
        // the thread that posted, which for the main context is inside
        // `save()` itself — while ``HikeSyncApplier/isApplyingRemoteChanges``
        // is still up. Handing this to `.main` instead would run it a turn
        // later, after the flag came down, and every change fetched from
        // iCloud would be queued straight back for upload: two devices
        // re-sending each other a hike neither of them touched, forever.
        saveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let identifiers = Self.changedIdentifiers(in: notification)
            guard !identifiers.isEmpty else { return }
            guard Thread.isMainThread else {
                // A background context, which is never where a fetched change
                // is written, so there is no flag to be inside of.
                Task { @MainActor in self?.recordChanges(identifiers) }
                return
            }
            MainActor.assumeIsolated { self?.recordChanges(identifiers) }
        }
    }

    private func observeAccountChanges() {
        guard accountObserver == nil else { return }
        accountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Through the same queue as every other transition: an
                // unchained one would race a reset across the account
                // round-trip and could restart the engine after it.
                self?.requestState(resetting: false)
            }
        }
    }

    /// Gets the sync bookkeeping the engine is holding onto disk before the
    /// process stops running.
    ///
    /// The record cache and the record index are coalesced — see
    /// ``CloudSyncStateStore/flush()`` — so the last acknowledgements of a
    /// session are still in memory when the app leaves the foreground.
    /// `willTerminate` is only delivered to a foreground app, which is why
    /// backgrounding is the hook that matters: a suspended process is killed
    /// without being told.
    private func observeAppLifecycle() {
        #if canImport(UIKit)
        guard lifecycleObservers.isEmpty else { return }
        let center = NotificationCenter.default
        lifecycleObservers = [
            UIApplication.didEnterBackgroundNotification,
            UIApplication.willTerminateNotification,
        ].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushSyncState() }
            }
        }
        #endif
    }

    private func flushSyncState() {
        beginFlushAssertion()
        Task { [weak self, engine] in
            await engine.flushState()
            self?.endFlushAssertion()
        }
    }

    /// Keeps the process alive for the length of one flush.
    ///
    /// The write is an actor hop away and a process the system has just
    /// suspended does not get to finish one — which would leave the coalesced
    /// half of the state waiting for a launch that reads it back stale.
    private func beginFlushAssertion() {
        #if canImport(UIKit)
        guard flushAssertion == .invalid else { return }
        flushAssertion = UIApplication.shared.beginBackgroundTask(
            withName: "CloudSyncStateFlush"
        ) { [weak self] in
            MainActor.assumeIsolated { self?.endFlushAssertion() }
        }
        #endif
    }

    private func endFlushAssertion() {
        #if canImport(UIKit)
        guard flushAssertion != .invalid else { return }
        UIApplication.shared.endBackgroundTask(flushAssertion)
        flushAssertion = .invalid
        #endif
    }

    nonisolated private static func changedIdentifiers(
        in notification: Notification
    ) -> [PersistentIdentifier] {
        let userInfo = notification.userInfo ?? [:]
        let inserted = userInfo[ModelContext.NotificationKey.insertedIdentifiers.rawValue]
            as? [PersistentIdentifier] ?? []
        let updated = userInfo[ModelContext.NotificationKey.updatedIdentifiers.rawValue]
            as? [PersistentIdentifier] ?? []
        return inserted + updated
    }

    private func recordChanges(_ identifiers: [PersistentIdentifier]) {
        guard isEnabled, !applier.isApplyingRemoteChanges else { return }
        let changed = applier.photosByHike(for: identifiers)
        guard !changed.isEmpty else { return }
        Task { await engine.enqueue(photosByHike: changed) }
    }

    // MARK: - Reaching the right state

    /// Queues a state transition behind whatever is already in flight.
    ///
    /// Four unsynchronised things ask for one — launch, foregrounding, the
    /// switch and an account change — and `@MainActor` only excludes them
    /// between suspension points, not across the account round-trip in the
    /// middle. Left to interleave, a foregrounding that started before the
    /// user switched sync off would finish *after* it, restart the engine
    /// against a store the reset had just emptied, and upload the entire
    /// library to the iCloud account the user had just opted out of.
    ///
    /// - Parameter resetting: Whether to forget where sync had got to. True
    ///   only when the user turned it off — an account that merely went away
    ///   may come back, and throwing away the change token would cost a full
    ///   re-download for nothing.
    private func requestState(resetting: Bool) {
        guard canSync else {
            status.paused()
            return
        }
        let previous = stateTask
        stateTask = Task { [weak self] in
            await previous?.value
            await self?.applyEnabledState(resetting: resetting)
        }
    }

    private func applyEnabledState(resetting: Bool) async {
        guard isEnabled else {
            settings.stop()
            if resetting {
                await engine.reset()
            } else {
                await engine.stop()
            }
            return
        }

        let account = await Self.accountStatus(of: cloudContainer)
        // The switch may have moved while that round-trip was in flight, and
        // the branch above has already run for it.
        guard isEnabled else { return }
        status.account = account
        guard account.isUsable else {
            settings.stop()
            await engine.stop()
            return
        }

        settings.start()
        await engine.start()
        Self.registerForPushes()
        await engine.fetchChanges()
    }

    /// Asks for a device token so CloudKit can wake the app when another
    /// device writes something.
    ///
    /// No permission prompt and no `UNUserNotificationCenter`: these are
    /// silent pushes that never become an alert, and `CKSyncEngine` intercepts
    /// them itself rather than handing them to an app delegate — which is why
    /// there is no delegate here to hand them to.
    private static func registerForPushes() {
        #if canImport(UIKit)
        UIApplication.shared.registerForRemoteNotifications()
        #endif
    }

    private static func accountStatus(of container: CKContainer) async -> CloudAccountStatus {
        do {
            return CloudAccountStatus(try await container.accountStatus())
        } catch {
            logger.error(
                """
                Could not read the iCloud account status: \
                \(error.localizedDescription, privacy: .public)
                """
            )
            return .unknown
        }
    }
}
