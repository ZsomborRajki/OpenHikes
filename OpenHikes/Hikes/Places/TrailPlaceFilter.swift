//
//  TrailPlaceFilter.swift
//  OpenHikes
//
//  Which kinds of place the maker's *Search this area* looks for.
//
//  One switch per ``TrailPlaceSymbol`` a search can find — see
//  ``TrailPointQuery/searchableSymbols`` — rather than one per OpenStreetMap
//  tag. A hiker who does not want shelters on the map means the house glyph,
//  and the three tags drawn with it are one idea to them.
//
//  **What is stored is what was turned off**, not what is on. Every switch
//  starts on, so an empty store is the default list, and a symbol a later
//  version learns to search for arrives switched on rather than silently
//  missing for everybody who ever touched a switch.
//
//  App-wide rather than per drawing: a hiker who never wants parking pins has
//  said so once, and a fresh trail that put them back would be asking again.
//  Kept on this device like ``TrailStopRecents`` and not synced — it is a
//  preference about this phone's map, not about a trail.
//
//  A switch turned off does two things and this type owns neither of them:
//  the next request leaves the tag out (``TrailPointFinder``), and the pins of
//  that kind already on the trail go (``TrailDraftController/setShowsPlaces(_:of:)``).
//
//  ## And one switch above all of them
//
//  ``placesShown`` is the switch beside the section's heading, and it is a
//  different kind of *off*: it hides rather than removes. The trail's places
//  stay on the drawing, out of sight, the *Search this area* pill goes, and a
//  save attaches none of them — see ``TrailDraftSave``. On again brings them
//  all back, because nothing was taken away. App-wide and on this device for
//  the reasons the kinds are.
//

import Foundation
import Observation
import OpenHikesData
import os

@MainActor
@Observable
final class TrailPlaceFilter {
    private static let logger = Logger(subsystem: "OpenHikes", category: "TrailDraft")

    /// The symbols switched off.
    private(set) var hidden: Set<TrailPlaceSymbol>

    /// Whether the maker deals in places at all: its pins, its pill, and what
    /// a save attaches. See the file header for how this differs from a kind
    /// switched off.
    private(set) var placesShown: Bool

    /// Where the choice is kept, or `nil` for one that lives only as long as
    /// this object — a preview, and every suite that does not ask for one.
    @ObservationIgnored private let defaults: UserDefaults?

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        hidden = defaults.map(Self.load(from:)) ?? []
        // What is stored is the switch turned *off*, so an empty store is the
        // default: places are shown.
        placesShown = !(defaults?.bool(forKey: SettingsKey.trailPlacesHidden) ?? false)
    }

    nonisolated deinit { /* intentionally empty */ }

    /// The symbols a search asks for: every searchable one not switched off.
    /// Empty when every switch is off, which is a search with nothing to ask.
    var shown: Set<TrailPlaceSymbol> {
        Set(TrailPointQuery.searchableSymbols).subtracting(hidden)
    }

    func shows(_ symbol: TrailPlaceSymbol) -> Bool {
        !hidden.contains(symbol)
    }

    /// Whether a found place may go on the trail. A place that claims no
    /// symbol has no switch to be turned off by.
    func admits(_ place: TrailPlace) -> Bool {
        place.symbol.map(shows) ?? true
    }

    func setShows(_ shows: Bool, _ symbol: TrailPlaceSymbol) {
        guard self.shows(symbol) != shows else { return }
        if shows {
            hidden.remove(symbol)
        } else {
            hidden.insert(symbol)
        }
        save()
    }

    func setPlacesShown(_ shown: Bool) {
        guard placesShown != shown else { return }
        placesShown = shown
        defaults?.set(!shown, forKey: SettingsKey.trailPlacesHidden)
    }

    // MARK: - Storage

    private func save() {
        // Sorted, so the same choice is the same bytes whatever order the set
        // happens to iterate in.
        defaults?.set(hidden.map(\.rawValue).sorted(), forKey: SettingsKey.trailPlaceHiddenSymbols)
    }

    /// Raw values this build does not know are dropped rather than failing
    /// the whole list — the same reading ``TrailPlaceSymbol/named(_:)`` gives a
    /// mirrored column.
    private static func load(from defaults: UserDefaults) -> Set<TrailPlaceSymbol> {
        guard let stored = defaults.array(forKey: SettingsKey.trailPlaceHiddenSymbols) else { return [] }
        let names = stored.compactMap { $0 as? String }
        if names.count != stored.count {
            logger.error("The hidden place kinds held something other than names; ignoring it.")
        }
        return Set(names.compactMap(TrailPlaceSymbol.named))
    }
}
