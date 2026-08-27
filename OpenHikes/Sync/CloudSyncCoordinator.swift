//
//  CloudSyncCoordinator.swift
//  OpenHikes
//
//  The one object the rest of the app talks to about sync, now that SwiftData
//  does the syncing.
//
//  There is no engine here any more. `Hike` lives in a store configured with
//  `cloudKitDatabase: .automatic`, so mirroring uploads, downloads, merges and
//  deletes on its own, from inside Core Data, with no queue this app owns and
//  no change token it has to persist. What is left is the part mirroring does
//  not do: tell the person what is happening, and remember whether they wanted
//  it at all.
//
//  The switch is the awkward part of that bargain. A `ModelConfiguration` is
//  fixed for the life of its container, so flipping it cannot take effect
//  until the app is next launched — ``OpenHikesModel`` reads
//  ``SettingsKey/cloudSyncEnabled`` when it builds the container, and
//  ``pendingRelaunch`` is what makes the gap between the switch and the
//  behaviour something the settings screen says out loud rather than something
//  the user discovers.
//

import CloudKit
import CoreData
import Foundation
import Observation
import os
import SwiftData

@MainActor
@Observable
final class CloudSyncCoordinator {
    private static let logger = Logger(subsystem: "OpenHikes", category: "CloudSync")

    /// The default container for this bundle identifier, spelled out rather
    /// than left to `CKContainer.default()` so that it is greppable and so
    /// that it matches the entitlement literally.
    ///
    /// Mirroring picks its own container from the entitlement and never reads
    /// this. The account check does, which is the only CloudKit call this app
    /// still makes by hand.
    static let containerIdentifier = "iCloud.tappium.com.OpenHikes"

    let status: CloudSyncStatus

    /// The user's switch. Persisted, and read at launch by whoever builds the
    /// container.
    ///
    /// On by default. This is the person's own private iCloud storage, it is
    /// how every first-party app on the device behaves, and the alternative —
    /// a phone restored from backup showing an empty hikes list until its
    /// owner finds a switch — is the failure this feature exists to prevent.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: SettingsKey.cloudSyncEnabled)
            updateSettingsMirror()
            refreshStatus()
        }
    }

    /// Whether the switch and this launch's container disagree.
    ///
    /// True exactly between flipping the switch and relaunching. Read by
    /// ``CloudSyncStatus`` so the row explains itself instead of claiming a
    /// state the store is not in.
    var pendingRelaunch: Bool { isEnabled != isSyncingThisLaunch }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageIsDurable: Bool
    /// What the container was actually built with — see ``pendingRelaunch``.
    @ObservationIgnored private let isSyncingThisLaunch: Bool
    /// Built on first use. Its only reader is the `async` account check, and a
    /// `CKContainer` constructed as a stored default argument put CloudKit's
    /// framework load and daemon handshake on the launch path; see
    /// `PERFORMANCE.md`.
    @ObservationIgnored private let makeCloudContainer: () -> CKContainer
    @ObservationIgnored private lazy var cloudContainer: CKContainer = makeCloudContainer()
    @ObservationIgnored private let settings: SyncedSettingsMirror
    @ObservationIgnored private var eventObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var accountObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var accountTask: Task<Void, Never>?

    /// Whether the user's setting says sync should be on, for the call site
    /// that has to decide before there is a coordinator to ask: the container
    /// is built first, and the coordinator takes what it was built with.
    static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: SettingsKey.cloudSyncEnabled) as? Bool
            ?? SettingsDefault.cloudSyncEnabled
    }

    /// - Parameter isSyncingThisLaunch: Whether the container this coordinator
    ///   reports on was actually built to mirror. Not re-derived from
    ///   `defaults`, because the two differ precisely in the case
    ///   ``pendingRelaunch`` exists to describe.
    /// - Parameter storageIsDurable: False when ``OpenHikesModel`` fell back to
    ///   its in-memory container because the persistent store would not open.
    ///   That container never mirrors, whatever the switch says.
    init(
        defaults: UserDefaults,
        isSyncingThisLaunch: Bool,
        storageIsDurable: Bool = true,
        settings: SyncedSettingsMirror? = nil,
        status: CloudSyncStatus = CloudSyncStatus(),
        cloudContainer: @autoclosure @escaping () -> CKContainer = CKContainer(
            identifier: CloudSyncCoordinator.containerIdentifier
        )
    ) {
        self.defaults = defaults
        self.isSyncingThisLaunch = isSyncingThisLaunch && storageIsDurable
        self.storageIsDurable = storageIsDurable
        self.status = status
        self.settings = settings ?? SyncedSettingsMirror(defaults: defaults)
        makeCloudContainer = cloudContainer
        isEnabled = Self.isEnabled(in: defaults)
        status.pendingRelaunch = isEnabled != self.isSyncingThisLaunch
    }

    // MARK: - Lifecycle

    /// Starts reporting on what mirroring is doing.
    ///
    /// Behind the test guard for the same reason every other startup writer
    /// is: both unit-test bundles are hosted by the app, so this would
    /// otherwise reach for a real iCloud account underneath suites that own
    /// their own store.
    func start() {
        updateSettingsMirror()
        guard canSync else {
            status.paused()
            refreshStatus()
            return
        }
        observeMirroringEvents()
        observeAccountChanges()
        refreshStatus()
    }

    /// Matches the settings mirror to the switch, immediately.
    ///
    /// Unlike the hikes themselves, settings need no relaunch to change their
    /// minds: they ride on `NSUbiquitousKeyValueStore`, which this object owns
    /// outright rather than receiving pre-configured from a
    /// ``ModelConfiguration``. Turning the switch off has to stop them the
    /// moment it is turned off — a user who has just said "do not put my
    /// things in iCloud" and watches their map provider upload anyway has been
    /// told something untrue.
    private func updateSettingsMirror() {
        if canSync, isEnabled {
            settings.start()
        } else {
            settings.stop()
        }
    }

    /// Re-checks iCloud.
    ///
    /// Mirroring needs no nudge to fetch — it holds its own subscription and
    /// wakes on the same pushes — so unlike the engine this replaced, it asks
    /// nothing of the store. It exists so a user who signed into iCloud in the
    /// Settings app and came back sees the row change.
    func sceneDidBecomeActive() {
        refreshStatus()
    }

    /// Whether mirroring is running at all, for reasons that have nothing to
    /// do with the user's switch.
    private var canSync: Bool {
        storageIsDurable && !AppLaunchEnvironment.isRunningTests
    }

    // MARK: - Observation

    /// Turns Core Data's mirroring events into the three words the settings
    /// row is allowed to say.
    ///
    /// `NSPersistentCloudKitContainer` is what SwiftData builds underneath a
    /// mirrored `ModelConfiguration`, and it posts these whether or not
    /// anybody holds a reference to it — which is fortunate, because SwiftData
    /// does not hand one out. This is the only window onto sync the framework
    /// leaves open, and it is narrower than the engine's was: an event says a
    /// setup, import or export began or ended and whether it succeeded, and
    /// nothing about what was in it.
    private func observeMirroringEvents() {
        guard eventObserver == nil else { return }
        eventObserver = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Reduced to a `Sendable` value *here*, on the posting thread,
            // rather than carried across the hop: `Event` is a class and its
            // `error` is an existential, so neither can cross an isolation
            // boundary. Everything the row can say about a pass is in the four
            // cases of ``CloudSyncOutcome`` anyway.
            guard let outcome = CloudSyncOutcome(notification: notification) else { return }
            MainActor.assumeIsolated { self?.apply(outcome) }
        }
    }

    private func apply(_ outcome: CloudSyncOutcome) {
        switch outcome {
        case .began:
            status.began()
        case .succeeded:
            status.finished()
        case .transientFailure(let reason):
            Self.logger.error(
                "Transient iCloud mirroring error: \(reason, privacy: .public)"
            )
            // Reported as a completed pass rather than a failure: mirroring
            // retries these itself, and a device in a tunnel is not a device
            // with a sync problem.
            status.finished()
        case .failed(let reason):
            Self.logger.error("iCloud mirroring failed: \(reason, privacy: .public)")
            status.failed(reason)
        }
    }

    private func observeAccountChanges() {
        guard accountObserver == nil else { return }
        accountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatus() }
        }
    }

    /// Re-reads the things the row shows that are not events: whether there is
    /// an account, and whether the switch is waiting on a relaunch.
    ///
    /// The account check is chained behind whatever is already in flight, so
    /// two overlapping round-trips — a foregrounding and an account change
    /// arriving together — cannot land out of order and leave the row
    /// describing the older of the two.
    private func refreshStatus() {
        status.pendingRelaunch = pendingRelaunch
        guard canSync else {
            status.account = .available
            status.paused()
            return
        }
        guard isSyncingThisLaunch else {
            status.paused()
            return
        }
        let previous = accountTask
        accountTask = Task { [weak self] in
            await previous?.value
            guard let container = self?.cloudContainer else { return }
            let account = await Self.accountStatus(of: container)
            guard let self else { return }
            status.account = account
            if !account.isUsable { status.paused() }
        }
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
