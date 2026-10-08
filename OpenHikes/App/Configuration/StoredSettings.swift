//
//  StoredSettings.swift
//  OpenHikes
//
//  The settings the always-on screens draw from, as values that change when
//  the settings do and at no other time.
//

import Foundation
import Observation
import OpenHikesData

/// The map's style and hiking-route layer, the hikes list's order and the
/// photo-library switch, read from `UserDefaults` and published only when they
/// change.
///
/// `@AppStorage` cannot be handed to a screen that is always up. It re-runs the
/// view that declares it on **every** write to its `UserDefaults` — any key,
/// from anywhere in the app, whatever the value — which
/// `AppStorageInvalidationTests` pins, and this app writes there all the time:
/// the selected hike on every selection, the weather reading, the
/// entitlement, and a followed trail's last matched distance each time its
/// position is published.
/// The map screen's root, the hikes list and the hike detail screen each held
/// one, so every one of those writes was a pass of all three. Here the suite's
/// change notification re-reads each value and assigns only the ones that
/// moved, so a screen reading one re-runs when that setting changes and not
/// when something else is written beside it.
///
/// Who writes these is unchanged. The settings screen and the route-layer
/// switch keep their `@AppStorage` bindings — a screen that is only up while it
/// is being used can afford them — and their writes reach this through the
/// notification, as iCloud's copy does through ``SyncedSettingsMirror``. The
/// list's order is the exception, written here by the list's own menu.
@Observable
final class StoredSettings {
    /// The chosen map — see ``TileProvider/renderable(id:entitlement:)`` for
    /// the one actually drawn.
    private(set) var tileProviderID: String
    /// Whether Waymarked Trails' hiking routes are drawn over it.
    private(set) var showsHikingRoutes: Bool
    /// The hikes list's order, as ``HikeListSort``'s raw value.
    private(set) var hikeListSort: String
    /// Whether a photo filed by the app is also saved to the photo library.
    /// Only ever read when one is filed, so no screen depends on it.
    private(set) var savesPhotosToLibrary: Bool

    @ObservationIgnored private let defaults: UserDefaults
    /// Removed by the deinit: a block-based observer is retained by the
    /// notification centre until it is, and the app-hosted test bundles build
    /// a model, and so one of these, per suite.
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        tileProviderID = Self.tileProviderID(in: defaults)
        showsHikingRoutes = Self.showsHikingRoutes(in: defaults)
        hikeListSort = Self.hikeListSort(in: defaults)
        savesPhotosToLibrary = Self.savesPhotosToLibrary(in: defaults)
        // Scoped to this suite, never the process-wide notification. A write
        // made on the main thread is delivered before it returns, so an
        // `@AppStorage` binding in Settings and the screens reading this move
        // in the same update.
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: nil
        ) { [weak self] _ in
            onMainActor { self?.refresh() }
        }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Puts the hikes list in another order, and remembers it.
    func setHikeListSort(_ rawValue: String) {
        guard rawValue != hikeListSort else { return }
        hikeListSort = rawValue
        defaults.set(rawValue, forKey: SettingsKey.hikeListSort)
    }

    /// Re-reads every value and assigns only the ones that moved.
    ///
    /// The notification names no key, so this runs for every write the app
    /// makes, and the comparisons say what the class is for. They are not what
    /// stops an equal assignment waking a reader: `@Observable` already
    /// filters those for an `Equatable` value — see *Render isolation, in
    /// practice* in the repository instructions.
    private func refresh() {
        let provider = Self.tileProviderID(in: defaults)
        if provider != tileProviderID { tileProviderID = provider }
        let routes = Self.showsHikingRoutes(in: defaults)
        if routes != showsHikingRoutes { showsHikingRoutes = routes }
        let sort = Self.hikeListSort(in: defaults)
        if sort != hikeListSort { hikeListSort = sort }
        let photos = Self.savesPhotosToLibrary(in: defaults)
        if photos != savesPhotosToLibrary { savesPhotosToLibrary = photos }
    }

    // Each falls back to what the `@AppStorage` it replaced declared, so a key
    // nothing has written yet reads the same either way.

    private static func tileProviderID(in defaults: UserDefaults) -> String {
        defaults.string(forKey: SettingsKey.tileProviderID) ?? TileProvider.default.id
    }

    private static func showsHikingRoutes(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: SettingsKey.showsHikingRoutes) as? Bool ?? SettingsDefault.showsHikingRoutes
    }

    private static func hikeListSort(in defaults: UserDefaults) -> String {
        defaults.string(forKey: SettingsKey.hikeListSort) ?? HikeListSort.newest.rawValue
    }

    private static func savesPhotosToLibrary(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: SettingsKey.savePhotosToLibrary) as? Bool ?? SettingsDefault.savePhotosToLibrary
    }
}
