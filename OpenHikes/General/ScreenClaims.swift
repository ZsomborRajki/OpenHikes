//
//  ScreenClaims.swift
//  OpenHikes
//
//  Which of the sheet's screens owns a piece of the map — the camera pill, the
//  photo pins, the place pins — when more than one has said *mine*.
//
//  ## The deepest screen wins, not the last to appear
//
//  Every claim used to be *the last `onAppear` wins*, which rests on SwiftUI
//  appearing screens in the order they are pushed. It does not, three deep:
//  pushing a third screen onto the sheet's stack appears the one two levels
//  down again — measured with *Places Around Trail*, where the hike's screen
//  under it re-claimed the pins and the pill a moment after *Add Place* or a
//  place's screen had claimed them, so the placeholder pin vanished and a
//  photograph taken from the pill was filed under the hike instead of the
//  place. So a claim carries how deep in the stack its screen is — see
//  ``SheetDepthKey`` — and the deepest one is the one in force; between two
//  at the same depth, the newer, which is the old rule where it still holds.
//
//  Every claim is kept until its own screen hands it back, rather than only
//  the one in force, so a pop hands the map back to the screen beneath
//  without waiting for an `onAppear` SwiftUI may already have spent.
//

import SwiftUI

struct ScreenClaims<Payload> {
    private struct Claim {
        let token: Int
        let depth: Int
        var payload: Payload
    }

    private var claims: [Claim] = []
    private var nextToken = 0

    /// Records a claim, and answers the token that updates or withdraws it.
    @discardableResult mutating func attach(_ payload: Payload, depth: Int) -> Int {
        nextToken += 1
        claims.append(Claim(token: nextToken, depth: depth, payload: payload))
        return nextToken
    }

    /// Replaces what a claim still standing says. Answers whether it stood.
    @discardableResult mutating func update(_ token: Int, _ change: (inout Payload) -> Void) -> Bool {
        guard let index = claims.firstIndex(where: { $0.token == token }) else { return false }
        change(&claims[index].payload)
        return true
    }

    /// Withdraws a claim. A token already withdrawn changes nothing.
    mutating func detach(_ token: Int) {
        claims.removeAll { $0.token == token }
    }

    /// The claim in force: the deepest, and the newest of those.
    var active: (token: Int, payload: Payload)? {
        claims.max { lhs, rhs in
            lhs.depth != rhs.depth ? lhs.depth < rhs.depth : lhs.token < rhs.token
        }
        .map { ($0.token, $0.payload) }
    }
}

/// How deep in the sheet's navigation stack a screen is: 0 for the sheet's
/// own root, 1 for the first screen pushed. Set on every pushed screen by
/// ``MapSheet`` and read by the modifiers that claim a piece of the map — see
/// ``ScreenClaims``.
private struct SheetDepthKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    var sheetDepth: Int {
        get { self[SheetDepthKey.self] }
        set { self[SheetDepthKey.self] = newValue }
    }
}
