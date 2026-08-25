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
//    it; a tile is by definition optional when a cached one exists and a
//    blank square when one doesn't.
//  * `isExpensive` — cellular (or a personal hotspot). Stops *speculative*
//    traffic only. A hiker on the approach road still gets the map they are
//    looking at, because refusing that would look like a bug rather than a
//    saving; what they do not get is the app reading ahead on their data plan.
//  * Low Power Mode and thermal pressure, via ``PowerState/current``. These
//    also stop *speculative* traffic only.
//
//  There is deliberately no setting behind any of this. The app is meant to
//  be used hands-free — pocket, glance, walk on — and every question it asks
//  in Settings about Wi-Fi versus cellular is a question the walker has to
//  answer correctly *before* the walk to get the right behaviour during it.
//  So the policy assumes a connection is available wherever the walker is and
//  spends as little of it as it can: everything nobody is waiting for is
//  given up the moment the connection becomes metered, throttled or
//  constrained, and everything the walker is actually looking at still loads.
//
//  Split by purpose rather than by caller: what the policy weighs is whether
//  anyone is waiting for the tile. ``TileCache/loadTile(forKey:url:purpose:)``
//  takes that as a parameter, defaulting to `.interactive`, while
//  ``TileCache/saveTileDurably(forKey:url:)`` — the bulk-download path — fixes
//  it at `.speculative`.
//

import Foundation

nonisolated enum TileFetchPurpose: String, Sendable {
    /// The map is trying to draw this tile now. Refusing shows the walker a
    /// blank square, so only an unambiguous instruction — offline, or Low Data
    /// Mode — is allowed to.
    case interactive = "interactive"
    /// A bulk download, or anything else fetching a tile ahead of it being
    /// needed. Always the first thing to give up.
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
        power: PowerState = .current
    ) -> TileNetworkDecision {
        guard conditions.isOnline else { return .denied("offline") }
        // The one condition that reaches interactive traffic, because it is
        // the only one where the user has already said, per network and in
        // the system's own words, that optional networking should stop. The
        // app has nothing to add to that and no toggle that contradicts it.
        if conditions.isConstrained { return .denied("low-data-mode") }
        guard purpose == .speculative else { return .allowed }
        if power.isLowPowerModeEnabled { return .denied("low-power-mode") }
        if RecordingEnergyPolicy.conserves(power.thermalState) { return .denied("thermal") }
        // Cellular costs the same radio as Wi-Fi for a tile the walker is
        // waiting on, and buys nothing for one they are not. Reading ahead is
        // therefore the whole of what a metered connection gives up: the map
        // in front of them still fills in, and the app stops spending their
        // allowance on ground they may never walk.
        if conditions.isExpensive { return .denied("cellular-speculative") }
        return .allowed
    }
}
