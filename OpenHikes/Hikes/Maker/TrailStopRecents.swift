//
//  TrailStopRecents.swift
//  OpenHikes
//
//  The places a hiker has picked out of the stop search before, offered again
//  before they type anything — Apple Maps' *Recents*.
//
//  A trail is often drawn from the same few places: the car park the walks
//  start from, the hut a weekend is built around, the town the bus goes back
//  to. Typing "Wimbachbrücke" for the fourth time is the cost this removes.
//
//  ## What is kept, and what is not
//
//  A place the search *resolved* — its name, the address line the suggestion
//  carried, and where it is. Not a query, not a suggestion nobody picked, and
//  not a *My Location* pick, which names nothing: the next time, the hiker is
//  standing somewhere else. Newest first, one entry per place, and at most
//  ``TrailStopRecents/limit`` of them, because a list that grows forever stops
//  being the short list of places this hiker actually uses.
//
//  On this device only, in `UserDefaults` beside the other settings — see
//  ``SettingsKey/trailStopRecents``. Not synced: it is a convenience of this
//  phone's search field, and none of it leaves the device.
//

import CoreLocation
import Foundation
import Observation
import os

/// One place the stop search found and the hiker picked.
nonisolated struct TrailStopRecent: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var name: String
    /// The address line the suggestion carried, or empty for none.
    var subtitle: String
    var latitude: Double
    var longitude: Double

    init(name: String, subtitle: String, latitude: Double, longitude: Double, id: UUID = UUID()) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.latitude = latitude
        self.longitude = longitude
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Put down again exactly as it was picked the first time.
    var pick: TrailStopSearchPick {
        TrailStopSearchPick(name: name, coordinate: clCoordinate, subtitle: subtitle)
    }

    /// Whether `other` is this place picked again.
    ///
    /// By name and by being within a few metres, rather than by coordinate
    /// alone: two picks of one car park land a metre or two apart depending on
    /// which suggestion resolved them, and two different huts can share a
    /// name across a range.
    func isSamePlace(as other: Self) -> Bool {
        name == other.name
            && RouteGeometry.distanceMeters(from: clCoordinate, to: other.clCoordinate)
            <= Self.samePlaceMeters
    }

    private static let samePlaceMeters: CLLocationDistance = 50
}

/// The recent places, newest first, kept across launches.
///
/// A stable `@Observable` for the reason ``TrailStopSearchRun`` is one: the
/// sheet that shows the list is torn down between searches and the list is
/// not. Held by ``TrailDraftController`` so every maker session shares it.
@MainActor
@Observable
final class TrailStopRecents {
    private static let logger = Logger(subsystem: "OpenHikes", category: "TrailDraft")

    /// How many are kept — enough for the places a hiker returns to, few
    /// enough that the list still fits above the keyboard.
    static let limit = 10

    private(set) var entries: [TrailStopRecent]

    /// Where they are kept, or `nil` for a list that lives only as long as
    /// this object — a preview, and every suite that does not ask for one.
    @ObservationIgnored private let defaults: UserDefaults?

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        entries = defaults.map(Self.load(from:)) ?? []
    }

    nonisolated deinit { /* intentionally empty */ }

    /// Puts a picked place at the top, taking out an older entry for the same
    /// place. Refused for a pick with no name, which is a *My Location* pick —
    /// see the file header.
    func record(_ pick: TrailStopSearchPick) {
        guard !pick.name.isEmpty else { return }
        let recent = TrailStopRecent(
            name: pick.name,
            subtitle: pick.subtitle,
            latitude: pick.latitude,
            longitude: pick.longitude
        )
        var updated = entries.filter { !$0.isSamePlace(as: recent) }
        updated.insert(recent, at: 0)
        if updated.count > Self.limit { updated.removeLast(updated.count - Self.limit) }
        entries = updated
        save()
    }

    /// Forgets the entries at `offsets` — a swipe on a row of the list.
    func remove(atOffsets offsets: IndexSet) {
        let kept = entries.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        guard kept.count != entries.count else { return }
        entries = kept
        save()
    }

    // MARK: - Storage

    private func save() {
        guard let defaults else { return }
        do {
            defaults.set(try JSONEncoder().encode(entries), forKey: SettingsKey.trailStopRecents)
        } catch {
            // The list in memory is right for this launch; the next one starts
            // from whatever was last written.
            Self.logger.error("Could not store the recent stops: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func load(from defaults: UserDefaults) -> [TrailStopRecent] {
        guard let data = defaults.data(forKey: SettingsKey.trailStopRecents) else { return [] }
        do {
            return Array(try JSONDecoder().decode([TrailStopRecent].self, from: data).prefix(limit))
        } catch {
            logger.error("Could not read the recent stops: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
