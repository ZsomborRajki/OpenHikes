//
//  Color+Hex.swift
//  OpenTrailsShared
//
//  A small, platform-portable subset of the app's own Color+Hex (see
//  OpenTrails/General/Color+Hex.swift) — just enough to turn a hike's stored
//  tint back into a Color for widget rendering. This package only ever needs
//  to read a hex string, never produce one.
//

import SwiftUI

extension Color {
    /// Parses "#RRGGBB" or "#RRGGBBAA" (with or without the leading `#`).
    /// Mirrors the app target's own `Color.init?(hex:)` exactly.
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard let value = UInt32(s, radix: 16) else { return nil }
        switch s.count {
        case 6:
            self.init(
                .sRGB,
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255,
                opacity: 1
            )
        case 8:
            self.init(
                .sRGB,
                red: Double((value >> 24) & 0xFF) / 255,
                green: Double((value >> 16) & 0xFF) / 255,
                blue: Double((value >> 8) & 0xFF) / 255,
                opacity: Double(value & 0xFF) / 255
            )
        default:
            return nil
        }
    }
}
