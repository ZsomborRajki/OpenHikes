//
//  Color+Hex.swift
//  OpenTrails
//
//  Hex string <-> Color conversions, used to persist a Hike's tint.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension Color {
    /// The resolved sRGB components (0…1) of this color.
    private var rgba: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
        #else
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return (c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
        #endif
    }

    /// "#RRGGBBAA" for the resolved color — the inverse of `init?(hex:)`, used to
    /// persist a picked color (with its alpha) back into `Hike.tintHex`.
    var hexRGBA: String {
        let c = rgba
        return String(
            format: "#%02X%02X%02X%02X",
            Int((c.r * 255).rounded()), Int((c.g * 255).rounded()),
            Int((c.b * 255).rounded()), Int((c.a * 255).rounded())
        )
    }

    /// The same color forced fully opaque (alpha = 1).
    var opaque: Color {
        let c = rgba
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
    }

    /// Parses "#RRGGBB" or "#RRGGBBAA" (with or without the leading `#`).
    init?(hex: String) {
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
