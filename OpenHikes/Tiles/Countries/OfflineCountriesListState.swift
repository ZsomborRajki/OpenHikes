//
//  OfflineCountriesListState.swift
//  OpenHikes
//
//  What *Offline Maps*' list holds while it is up: what is typed in its
//  search field, the order the hiker picked and the split countries opened to
//  their regions, where a turn of the phone cannot reach it.
//
//  Under the map the list is drawn in the sheet upright and in the side panel
//  on its side, so a turn builds it again in the other host. While these were
//  the list's own `@State`, they went with the old one: half a name typed, or
//  the list put largest first, and a turn brought back the empty field and the
//  order the list opens in. ``SheetPresentation`` keeps one of these while
//  *Offline Maps* is on the stack, as it keeps *Places Nearby*'s
//  ``HikePlacesNearbySession`` (see ``SheetRetained``), and lets it go when
//  the screen is popped, so the next visit opens afresh. In Settings, where
//  nothing turns the list into another host, it is the screen's own.
//

import Observation

@Observable
final class OfflineCountriesListState {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    /// What is typed in the search field.
    var query = ""
    /// The order the hiker picked, or `nil` for the one the list opens in —
    /// see ``OfflineCountrySort/inForce(chosen:hasPosition:)``.
    var chosenSort: OfflineCountrySort?
    /// The split countries open in the list.
    var expanded: Set<String> = []
}
