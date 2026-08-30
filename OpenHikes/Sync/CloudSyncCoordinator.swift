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
    nonisolated private static let logger = Logger(subsystem: "OpenHikes", category: "CloudSync")

    /// The default container for this bundle identifier, spelled out rather
    /// than left to `CKContainer.default()` so that it is greppable and so
    /// that it matches the entitlement literally.
    ///
    /// Mirroring picks its own container from the entitlement and never reads
    /// this. The account check does, which is the only CloudKit call this app
    /// still makes by hand.
    nonisolated static let containerIdentifier = "iCloud.tappium.com.OpenHikes"

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
    /// Builds the `CKContainer` the account check asks about.
    ///
    /// Held as a closure and never called from here, because calling it is not
    /// the cheap value-type construction it looks like: the first
    /// `CKContainer(identifier:)` in a process loads CloudKit and shakes hands
    /// with its daemon, synchronously, and on a fresh install that is seconds
    /// rather than milliseconds. See ``accountStatus(making:)`` for where it is
    /// allowed to run, and `PERFORMANCE.md` for the launch cost that first
    /// moved it off the stored default it used to be.
    @ObservationIgnored private let makeCloudContainer: @Sendable () -> CKContainer
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
        cloudContainer: @autoclosure @escaping @Sendable () -> CKContainer = CKContainer(
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
            // `queue: .main` above is load-bearing, not a formality. Core
            // Data posts these from its own threads, `apply(_:)` is
            // main-actor, and asking for the main queue is the whole reason
            // the `assumeIsolated` below is sound rather than a crash waiting
            // for a background post. So this block runs on the main queue —
            // there is no hop here, and nothing crosses an isolation
            // boundary.
            //
            // The reduction happens here anyway, for a different reason:
            // `Event` is a class whose `error` is an existential, and keeping
            // it out of `apply(_:)` is what lets that reducer take a
            // `Sendable` value a test can construct. Everything the row can
            // say about a pass is in the four cases of ``CloudSyncOutcome``.
            guard let outcome = CloudSyncOutcome(notification: notification) else { return }
            MainActor.assumeIsolated { self?.apply(outcome) }
        }
    }

    /// Not `private`: this is the reducer the mirroring observer feeds, and
    /// the one place the transient/succeeded distinction is made. Tests drive
    /// it directly because `NSPersistentCloudKitContainer.Event` cannot be
    /// constructed to post a notification with.
    func apply(_ outcome: CloudSyncOutcome) {
        switch outcome {
        case .began:
            status.began()
        case .succeeded:
            status.finished()
        case .transientFailure(let reason):
            Self.logger.error(
                "Transient iCloud mirroring error: \(reason, privacy: .public)"
            )
            // Neither a success nor a problem to report: mirroring retries
            // these itself, so a device in a tunnel is not a device with a
            // sync problem — but nothing was transferred either, so the pass
            // must not go idle and stamp a fresh "last synced" time.
            status.retrying()
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
        // Nothing to ask iCloud about: this launch's store does not mirror,
        // whatever the account would have said. Saying so outright is what
        // keeps the row off "Checking iCloud…" for the rest of the session —
        // the account check below is the only thing that ever resolves it,
        // and it is precisely what this branch skips.
        guard canSync, isSyncingThisLaunch else {
            status.disabled()
            return
        }
        let previous = accountTask
        let makeContainer = makeCloudContainer
        accountTask = Task { [weak self] in
            await previous?.value
            let account = await Self.accountStatus(making: makeContainer)
            guard let self else { return }
            status.account = account
            // A usable account is the last thing standing between a mirroring
            // store and a truthful row: mirroring posts no event on a launch
            // with nothing to carry, so waiting for one left the row reading
            // "Sync Off" over a store that was syncing all along.
            if account.isUsable { status.ready() } else { status.paused() }
        }
    }

    /// Builds the container and asks CloudKit about the account, both away
    /// from the main thread.
    ///
    /// `Task.detached` rather than a plain `Task`, and this is the whole
    /// point of the function: this type is `@MainActor`, and a `Task {}`
    /// started from one of its methods *inherits* that isolation. Building the
    /// container inside one therefore ran CloudKit's synchronous framework
    /// load and daemon handshake on the main thread — which on a fresh install
    /// pinned it for seconds and left a new user looking at a grey map, no
    /// sheet and an app that did not respond, on the very first launch. Making
    /// the container `lazy` did not help: it moved *when* the handshake ran,
    /// not *where*.
    ///
    /// Not cached, deliberately. `CKContainer(identifier:)` hands back the
    /// same instance for an identifier it has already seen, so the cost this
    /// avoids is paid once per process no matter how often this is called, and
    /// a cache would only be somewhere else for a non-`Sendable` reference to
    /// have to live.
    private static func accountStatus(
        making container: @escaping @Sendable () -> CKContainer
    ) async -> CloudAccountStatus {
        await offMainThread {
            do {
                return CloudAccountStatus(try await container().accountStatus())
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

    /// Runs `work` somewhere that is not the main thread, and waits for it.
    ///
    /// Belt and braces, and both are load-bearing on their own: `nonisolated`
    /// stops the function inheriting this type's `@MainActor` isolation, and
    /// `Task.detached` refuses to inherit any isolation even if it did. Either
    /// alone is enough; together they mean a later edit has to remove two
    /// things to reintroduce the bug, and the suite fails when it does.
    ///
    /// Its own function so that the guarantee has somewhere to be tested at
    /// all. What it prevents is invisible at the call site and fatal at
    /// launch: `Task {}` started from a main-actor method looks exactly like
    /// `Task.detached` and runs its body on the main thread.
    nonisolated static func offMainThread<T: Sendable>(
        _ work: @escaping @Sendable () async -> T
    ) async -> T {
        await Task.detached(priority: .utility) { await work() }.value
    }
}
