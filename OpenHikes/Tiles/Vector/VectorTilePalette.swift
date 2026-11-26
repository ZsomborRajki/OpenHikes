//
//  VectorTilePalette.swift
//  OpenHikes
//
//  The colors a tile is drawn in. The style is OpenStreetMap Carto's, and so
//  are its colors (``VectorTileStyle``); a palette says what each of them is
//  on the picture. Carto's own palette changes none of them. The dark map's
//  (`VectorTileDarkPalette.swift`) gives each a dark counterpart, so the dark
//  map is the light map's drawing, every width, zoom, dash and order of it,
//  in other colors, and a rule added to the style is drawn on both maps with
//  nothing said here.
//
//  A color is translated where it meets the picture, never in the style:
//  ``VectorTilePainter`` and the layouts it draws ask the palette as they set
//  a fill, a stroke or a name's ink. So the style's own figures stay Carto's,
//  and every test of them holds for both maps.
//
//  One of Carto's colors can be two things. White is a street's surface, the
//  halo round a name and the dashes down a railway, and on a dark map the
//  first is the lightest thing on the ground and the other two the darkest.
//  So a color is translated by what it is put down as (``Role``): by the
//  role's own table where it has the color, then by the table every role
//  shares, and for a color neither names, by the palette's rule: the dark
//  map's keeps a color's hue and makes it light where it was dark and dark
//  where it was light (``VectorTileDarkening``). The rule is what keeps a
//  color Carto adds readable until someone picks a color for it.
//
//  The pictures Carto fills an area with, a wood's leaves and the dots of
//  scree, are translated too, each of the few colors in one to its
//  counterpart, and kept as the pictures themselves are
//  (``pattern(_:unit:from:)``). An icon is vector art set in one color, so a
//  dark map's icon is the same art in the palette's color for it.
//

import CoreGraphics
import Foundation
import Synchronization

nonisolated struct VectorTilePalette: Sendable, Hashable {
    /// What a color is put down as.
    enum Role: Sendable, Hashable, CaseIterable {
        /// The edge of a street, under its surface.
        case casing
        /// An area: the ground, water, a building.
        case fill
        /// The edge drawn round a name's letters.
        case halo
        /// A point's icon.
        case icon
        /// A line that is no street's surface: a stream, a fence, a railway,
        /// a path, a border.
        case line
        /// One of the colors in a picture an area is filled with.
        case pattern
        /// A street's surface, between its casings.
        case surface
        /// A name's letters.
        case text
    }

    /// OpenStreetMap Carto's own colors, as the style names them.
    static let carto = Self(name: "carto", isDark: false, translation: nil)

    /// What tells one palette from another.
    let name: String
    /// Whether the map it draws is a dark page: what the controls over the
    /// map take their appearance from (``MapChrome``).
    let isDark: Bool
    private let translation: Translation?

    /// Whether this is Carto's own palette, which the raster tiles of
    /// tile.openstreetmap.org are drawn in too.
    var isCarto: Bool { translation == nil }

    /// A palette that draws each of `shared`'s colors as its counterpart,
    /// whatever it is put down as, except where `roles` gives the role
    /// another, and any color neither names as `rule` works it out. Colors
    /// are `#RRGGBB`, and `rule`'s `0xRRGGBB`; an entry that is not a color
    /// is left out.
    init(
        name: String,
        isDark: Bool,
        shared: [(carto: String, own: String)],
        roles: [Role: [(carto: String, own: String)]] = [:],
        otherwise rule: @escaping @Sendable (_ rgb: UInt32, _ role: Role) -> UInt32
    ) {
        self.init(name: name, isDark: isDark, translation: Translation(shared: shared, roles: roles, rule: rule))
    }

    private init(name: String, isDark: Bool, translation: Translation?) {
        self.name = name
        self.isDark = isDark
        self.translation = translation
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }

    /// One of the style's colors as this palette has it when put down as
    /// `role`, as see-through as it was.
    func color(_ color: CGColor, as role: Role) -> CGColor {
        translation?.color(color, as: role) ?? color
    }

    /// Whether the palette names a color of its own for `color` as `role`,
    /// rather than working one out: what a suite asks of the colors a map is
    /// mostly made of.
    func names(_ color: CGColor, as role: Role) -> Bool {
        guard let translation, let rgb = Self.components(of: color)?.rgb else { return true }
        return translation.named(rgb, as: role) != nil
    }

    /// The pattern `asset` out of `icons`, in this palette's colors; `nil`
    /// where there is no such pattern.
    func pattern(_ asset: String, unit: CGFloat, from icons: any VectorTileIconDrawing) -> CGImage? {
        guard let translation else { return icons.pattern(asset: asset, unit: unit) }
        return translation.pattern(asset, unit: unit, from: icons)
    }

    // MARK: Colors as numbers

    /// A color's red, green and blue as one number, `0xRRGGBB`, and how
    /// opaque it is; `nil` for a color that is neither RGB nor gray.
    static func components(of color: CGColor) -> (rgb: UInt32, alpha: CGFloat)? {
        guard let components = color.components else { return nil }
        switch (color.colorSpace?.model, components.count) {
        case (.rgb, rgbComponentCount):
            return (packed(red: components[0], green: components[1], blue: components[2]), components[3])
        case (.monochrome, 2):
            return (packed(red: components[0], green: components[0], blue: components[0]), components[1])
        default:
            return nil
        }
    }

    /// The number `#RRGGBB` writes, or `nil` for anything else.
    static func rgb(hex: String) -> UInt32? {
        guard hex.hasPrefix("#"), hex.count == hexLength else { return nil }
        return UInt32(hex.dropFirst(), radix: hexRadix)
    }

    /// The opaque sRGB color `rgb` is.
    static func color(rgb: UInt32) -> CGColor {
        let channel = { (shift: UInt32) in CGFloat((rgb >> shift) & channelMask) / CGFloat(channelMask) }
        return CGColor(srgbRed: channel(redShift), green: channel(greenShift), blue: channel(0), alpha: 1)
    }

    static func packed(red: CGFloat, green: CGFloat, blue: CGFloat) -> UInt32 {
        let channel = { (value: CGFloat) in UInt32((min(max(value, 0), 1) * CGFloat(channelMask)).rounded()) }
        return channel(red) << redShift | channel(green) << greenShift | channel(blue)
    }

    static let redShift: UInt32 = 16
    static let greenShift: UInt32 = 8
    static let channelMask: UInt32 = 0xFF
    private static let rgbComponentCount = 4
    private static let hexLength = 7
    private static let hexRadix = 16
}

// MARK: - Translating

private extension VectorTilePalette {
    /// One palette's tables, and what it has worked out or drawn since.
    ///
    /// `@unchecked` for the `NSCache`, which is safe from any thread and not
    /// declared so; everything else is immutable or behind a `Mutex`.
    nonisolated final class Translation: @unchecked Sendable {
        private let shared: [UInt32: UInt32]
        private let roles: [Role: [UInt32: UInt32]]
        private let rule: @Sendable (UInt32, Role) -> UInt32
        /// The colors made so far, each once: a tile sets thousands.
        private let made = Mutex<[Made: CGColor]>([:])
        // swiftlint:disable:next legacy_objc_type
        private let patterns: NSCache<NSString, CGImage> = {
            // swiftlint:disable:next legacy_objc_type
            let cache = NSCache<NSString, CGImage>()
            cache.totalCostLimit = CatalogIcons.patternByteLimit
            return cache
        }()

        private struct Made: Hashable {
            let rgb: UInt32
            let role: Role
        }

        init(
            shared: [(carto: String, own: String)],
            roles: [Role: [(carto: String, own: String)]],
            rule: @escaping @Sendable (UInt32, Role) -> UInt32
        ) {
            self.shared = Self.table(shared)
            self.roles = roles.mapValues(Self.table)
            self.rule = rule
        }

        private static func table(_ entries: [(carto: String, own: String)]) -> [UInt32: UInt32] {
            var table: [UInt32: UInt32] = [:]
            for entry in entries {
                guard let carto = VectorTilePalette.rgb(hex: entry.carto),
                      let own = VectorTilePalette.rgb(hex: entry.own)
                else { continue }
                table[carto] = own
            }
            return table
        }

        /// The color the tables name for `rgb` as `role`, if either does.
        func named(_ rgb: UInt32, as role: Role) -> UInt32? {
            roles[role]?[rgb] ?? shared[rgb]
        }

        func color(_ color: CGColor, as role: Role) -> CGColor {
            guard let (rgb, alpha) = VectorTilePalette.components(of: color) else { return color }
            let key = Made(rgb: rgb, role: role)
            let opaque = made.withLock { made in
                if let kept = made[key] { return kept }
                let translated = VectorTilePalette.color(rgb: own(rgb, as: role))
                made[key] = translated
                return translated
            }
            return alpha < 1 ? opaque.copy(alpha: alpha) ?? opaque : opaque
        }

        /// This palette's color for `rgb` as `role`: the one a table names,
        /// or the one the rule works out.
        private func own(_ rgb: UInt32, as role: Role) -> UInt32 {
            named(rgb, as: role) ?? rule(rgb, role)
        }

        // MARK: Patterns

        func pattern(_ asset: String, unit: CGFloat, from icons: any VectorTileIconDrawing) -> CGImage? {
            // swiftlint:disable:next legacy_objc_type
            let key = "\(asset)@\(unit)" as NSString
            if let kept = patterns.object(forKey: key) { return kept }
            guard let carto = icons.pattern(asset: asset, unit: unit) else { return nil }
            // Two tiles may both find it missing and both draw it: the same
            // picture twice, and the second one kept.
            guard let own = recolored(carto) else { return carto }
            patterns.setObject(own, forKey: key, cost: own.bytesPerRow * own.height)
            return own
        }

        /// `picture` with each of its colors as this palette has it, as
        /// see-through at every pixel as it was. A pattern is a few colors
        /// and the soft edges between them and nothing, so each pixel takes
        /// the counterpart of the color it is nearest to: translated one at
        /// a time, the edge pixels, whose color is known only roughly, would
        /// come out as a fringe of their own.
        private func recolored(_ picture: CGImage) -> CGImage? {
            guard var bitmap = PatternBitmap(picture) else { return nil }
            let colors = bitmap.mainColors()
            guard !colors.isEmpty else { return picture }
            bitmap.replace(colors, with: colors.map { nearest(to: $0) })
            return bitmap.image
        }

        /// This palette's color for one of a pattern's: the tables' for it,
        /// or for a color they name within a rounding of it, a pattern's
        /// color being read back off its pixels, or the rule's.
        private func nearest(to rgb: UInt32) -> UInt32 {
            if let named = named(rgb, as: .pattern) { return named }
            let tables = [roles[.pattern] ?? [:], shared]
            for table in tables {
                let close = table.keys
                    .map { (key: $0, distance: PatternBitmap.distance($0, rgb)) }
                    .filter { $0.distance <= PatternBitmap.rounding }
                    .min { $0.distance < $1.distance }
                if let close, let own = table[close.key] { return own }
            }
            return rule(rgb, .pattern)
        }
    }
}

/// A pattern's pixels, to be read and written in place: four bytes each,
/// red, green, blue and how opaque, the colors already multiplied by that.
nonisolated private struct PatternBitmap {
    private var bytes: [UInt8]
    private let width: Int
    private let height: Int

    private static let bytesPerPixel = 4
    private static let opaque = 255
    /// A pixel fainter than this says too little of its color to be counted
    /// among a pattern's colors.
    private static let faintest = 48
    /// The colors told apart are sixteen levels of each of red, green and
    /// blue: what a soft edge's rounding cannot move a color across.
    private static let levelShift: UInt32 = 4
    /// A pattern's main colors are at most this many, each at least this
    /// share of its pixels.
    private static let mostColors = 4
    private static let leastShare = 0.04
    /// How far a color read off a pattern's pixels may be from the color the
    /// pattern was drawn in: a level of each channel.
    static let rounding = 16

    init?(_ picture: CGImage) {
        width = picture.width
        height = picture.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        bytes = [UInt8](repeating: 0, count: width * height * Self.bytesPerPixel)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * Self.bytesPerPixel,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
    }

    var image: CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData)
        else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8 * Self.bytesPerPixel,
            bytesPerRow: width * Self.bytesPerPixel,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    /// The largest difference between two colors' channels.
    static func distance(_ lhs: UInt32, _ rhs: UInt32) -> Int {
        let (left, right) = (Channels(lhs), Channels(rhs))
        return max(abs(left.red - right.red), abs(left.green - right.green), abs(left.blue - right.blue))
    }

    /// A color's red, green and blue, each out of 255, or sums of them.
    private struct Channels {
        var red: Int
        var green: Int
        var blue: Int

        init(_ rgb: UInt32) {
            red = Int((rgb >> VectorTilePalette.redShift) & VectorTilePalette.channelMask)
            green = Int((rgb >> VectorTilePalette.greenShift) & VectorTilePalette.channelMask)
            blue = Int(rgb & VectorTilePalette.channelMask)
        }

        var rgb: UInt32 {
            UInt32(red) << VectorTilePalette.redShift | UInt32(green) << VectorTilePalette.greenShift | UInt32(blue)
        }
    }

    /// The pixel at `offset`'s color with its opacity divided back out, or
    /// `nil` for one fainter than `faintest`. Asked once for every pixel, so
    /// nothing here is made that has to be let go.
    private func color(at offset: Int, faintest: Int) -> UInt32? {
        let alpha = Int(bytes[offset + 3])
        guard alpha >= faintest, alpha > 0 else { return nil }
        let red = min(Int(bytes[offset]) * Self.opaque / alpha, Self.opaque)
        let green = min(Int(bytes[offset + 1]) * Self.opaque / alpha, Self.opaque)
        let blue = min(Int(bytes[offset + 2]) * Self.opaque / alpha, Self.opaque)
        return UInt32(red) << VectorTilePalette.redShift | UInt32(green) << VectorTilePalette.greenShift | UInt32(blue)
    }

    private static func level(of rgb: UInt32) -> UInt32 {
        let mask = (VectorTilePalette.channelMask >> levelShift) << levelShift
        return rgb & (mask << VectorTilePalette.redShift | mask << VectorTilePalette.greenShift | mask)
    }

    /// The colors most of the pattern is drawn in, the commonest first:
    /// each the mean of the pixels at its level. A pattern faint all over,
    /// as Carto's red hatch is, is read from every pixel it has.
    func mainColors() -> [UInt32] {
        let colors = mainColors(faintest: Self.faintest)
        return colors.isEmpty ? mainColors(faintest: 1) : colors
    }

    private func mainColors(faintest: Int) -> [UInt32] {
        var sums: [UInt32: (sum: Channels, count: Int)] = [:]
        var counted = 0
        for offset in stride(from: 0, to: bytes.count, by: Self.bytesPerPixel) {
            guard let rgb = color(at: offset, faintest: faintest) else { continue }
            let pixel = Channels(rgb)
            var entry = sums[Self.level(of: rgb)] ?? (Channels(0), 0)
            entry.sum.red += pixel.red
            entry.sum.green += pixel.green
            entry.sum.blue += pixel.blue
            entry.count += 1
            sums[Self.level(of: rgb)] = entry
            counted += 1
        }
        let least = max(Int(Double(counted) * Self.leastShare), 1)
        return sums.values
            .sorted { $0.count > $1.count }
            .prefix(Self.mostColors)
            .enumerated()
            .filter { index, entry in index == 0 || entry.count >= least }
            .map { _, entry in
                var mean = entry.sum
                mean.red /= entry.count
                mean.green /= entry.count
                mean.blue /= entry.count
                return mean.rgb
            }
    }

    /// Every pixel in the one of `replacements` that stands for the one of
    /// `colors` it is nearest to, as opaque as it was.
    mutating func replace(_ colors: [UInt32], with replacements: [UInt32]) {
        var nearest: [UInt32: Channels] = [:]
        for offset in stride(from: 0, to: bytes.count, by: Self.bytesPerPixel) {
            guard let rgb = color(at: offset, faintest: 1) else { continue }
            let level = Self.level(of: rgb)
            let own: Channels
            if let kept = nearest[level] {
                own = kept
            } else {
                let index = colors.indices.min { Self.distance(colors[$0], rgb) < Self.distance(colors[$1], rgb) }
                own = Channels(replacements[index ?? 0])
                nearest[level] = own
            }
            let alpha = Int(bytes[offset + 3])
            bytes[offset] = UInt8(own.red * alpha / Self.opaque)
            bytes[offset + 1] = UInt8(own.green * alpha / Self.opaque)
            bytes[offset + 2] = UInt8(own.blue * alpha / Self.opaque)
        }
    }
}
