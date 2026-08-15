//
//  TileNetworkPolicy.swift
//  OpenHikes
//
//  Whether a tile is worth a radio.
//
//  The cellular radio is the second-largest energy line item on a hike after
//  the GPS, and unlike the GPS it is mostly avoidable: this app's whole
//  premise is that the map you need is already on the device. What was missing
//  was anything that *acted* on that. `NWPathMonitor` reported `.satisfied`
//  and the cache asked the tile server, whether the connection was Wi-Fi at
//  home or one bar of cellular in a valley — and one bar of cellular is the
//  expensive case, because a weak signal makes the radio transmit harder and
//  for longer to move the same tile.
//
//  Three conditions the system already publishes and this app ignored:
//
//  * `isConstrained` — Low Data Mode. An explicit, per-network instruction
//    from the user to stop doing optional networking. Nothing here overrides
//    it, and there is no setting to; a tile is by definition optional when a
//    cached one exists and a blank square when one doesn't.
//  * `isExpensive` — cellular (or a personal hotspot). Gated on a setting,
//    because a hiker on the approach road may well want the map to fill in,
//    and silently refusing would look like a bug rather than a saving.
//  * Low Power Mode and thermal pressure, via ``PowerState/current``. These
//    stop *speculative* traffic only. A map the walker is looking at still
//    loads; what stops is the app fetching tiles nobody asked to see yet.
//
//  Split by purpose rather than by caller, because the same
//  ``TileCache/loadTile(forKey:url:)`` serves both a visible tile and a
//  prefetch, and only the caller knows which one it is.
//

import Foundation

nonisolated enum TileFetchPurpose: String, Sendable {
    /// The map is trying to draw this tile now. Refusing shows the walker a
    /// blank square, so only an unambiguous instruction — offline, Low Data
    /// Mode, cellular with the setting off — is allowed to.
    case interactive = "interactive"
    /// Bulk download, auto-save promotion, or anything else fetching a tile
    /// ahead of it being needed. Always the first thing to give up.
    case speculative = "speculative"
}

nonisolated struct TileNetworkConditions: Equatable, Sendable {
    /// `NWPath.status == .satisfied`.
    var isOnline = true
    /// `NWPath.isExpensive` — cellular or a hotspot.
    var isExpensive = false
    /// `NWPath.isConstrained` — Low Data Mode is on for this network.
    var isConstrained = false
}

nonisolated enum TileNetworkDecision: Equatable, Sendable {
    case allowed
    /// Carries a short, stable reason so a suppressed fetch is visible in the
    /// signpost stream. A tile that silently never loads is the single
    /// hardest thing to debug in this pipeline, and this policy exists to
    /// create exactly that situation on purpose.
    case denied(String)

    var isAllowed: Bool { self == .allowed }

    var reason: String? {
        switch self {
        case .allowed: nil
        case .denied(let reason): reason
        }
    }
}

nonisolated enum TileNetworkPolicy {
    static func decide(
        _ purpose: TileFetchPurpose,
        conditions: TileNetworkConditions,
        allowsCellular: Bool,
        power: PowerState = .current
    ) -> TileNetworkDecision {
        guard conditions.isOnline else { return .denied("offline") }
        // Checked before the cellular setting because Low Data Mode is the
        // stronger statement of the two, and a walker who has turned it on for
        // their carrier's network should not have to find a second toggle in
        // this app to be taken at their word.
        if conditions.isConstrained { return .denied("low-data-mode") }
        if conditions.isExpensive, !allowsCellular { return .denied("cellular") }
        guard purpose == .speculative else { return .allowed }
        if power.isLowPowerModeEnabled { return .denied("low-power-mode") }
        if RecordingEnergyPolicy.conserves(power.thermalState) { return .denied("thermal") }
        // Speculative traffic over cellular costs the same radio as
        // interactive traffic and buys nothing the walker is waiting for, so
        // it needs the setting even when the setting has been granted for
        // interactive use — which it has, or the check above would have
        // returned already. Left explicit rather than folded upward so the
        // asymmetry is visible.
        if conditions.isExpensive { return .denied("cellular-speculative") }
        return .allowed
    }
}
