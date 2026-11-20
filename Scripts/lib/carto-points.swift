#!/usr/bin/env swift
//
//  carto-points.swift
//  Scripts/lib
//
//  Reads OpenStreetMap Carto's points — the icons and names its
//  `amenity-points.mss` and `stations.mss` draw, the style
//  tile.openstreetmap.org is drawn in — and writes them out as the table the
//  vector map draws points from, with every icon the table names copied into
//  an asset catalog, and beside them the pictures Carto fills an area with or
//  lays along a line.
//
//  Carto is written in CartoCSS: nested blocks whose filters and zooms add
//  up, where the more specific of two declarations wins and the later one
//  breaks a tie. Carto's own compiler flattens that into Mapnik's rules; this
//  evaluates the same cascade for each kind of point the archive can name, at
//  each zoom, and keeps what a point read from the archive can meet: open to
//  everyone or not, not a building, and with only the details the archive
//  keeps — a place of worship's religion, a pitch's sport, a car park's
//  `parking` and a protected area's class, in `kind_detail`, and whether it
//  has a name. A point has no size (`way_pixels` 0); an area, which the
//  vector extras give with its size, is evaluated again for each range of
//  sizes the rules tell apart, below zoom 10 in the layer Carto names large
//  areas in at low zooms.
//
//  Only the CartoCSS these rules are written in is read: variables, nested
//  blocks, filters on attributes and on zoom, an attribute named as a text,
//  quoted or not, and the color functions darken, lighten, saturate,
//  desaturate, fade, fadeout and mix. Anything else stops the script rather
//  than being read as something it is not.
//
//  Which OpenStreetMap key a feature belongs to comes from Carto's SQL, in
//  `project.mml`: the archive files a point by its value alone (`parking`,
//  not `amenity=parking`), and where two keys share a value, Carto's own
//  order of keys decides. The shops Carto draws are `common-values.sql`'s.
//
//  Usage:
//    swift Scripts/lib/carto-points.swift <openstreetmap-carto> <points.json> <icons.xcassets>
//

import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("carto-points: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    fail("usage: carto-points.swift <openstreetmap-carto> <points.json> <icons.xcassets>")
}
let cartoRoot = URL(fileURLWithPath: arguments[1])
let tableURL = URL(fileURLWithPath: arguments[2])
let catalogURL = URL(fileURLWithPath: arguments[3])
guard catalogURL.pathExtension == "xcassets" else { fail("\(catalogURL.path) is not an asset catalog") }

func read(_ path: String) -> String {
    guard let text = try? String(contentsOf: cartoRoot.appending(path: path), encoding: .utf8) else {
        fail("cannot read \(path) in \(cartoRoot.path)")
    }
    return text
}

/// The zooms the map draws.
let zooms = 0...19

// MARK: - Reading CartoCSS

/// `text` without its comments, keeping whatever is quoted.
func uncommented(_ text: String) -> String {
    let characters = Array(text)
    var output = ""
    var index = 0
    var quote: Character?
    while index < characters.count {
        let character = characters[index]
        let next = index + 1 < characters.count ? characters[index + 1] : nil
        if let open = quote {
            output.append(character)
            if character == open { quote = nil }
            index += 1
        } else if character == "\"" || character == "'" {
            quote = character
            output.append(character)
            index += 1
        } else if character == "/", next == "*" {
            index += 2
            while index + 1 < characters.count, !(characters[index] == "*" && characters[index + 1] == "/") {
                index += 1
            }
            index += 2
        } else if character == "/", next == "/" {
            while index < characters.count, characters[index] != "\n" { index += 1 }
        } else {
            output.append(character)
            index += 1
        }
    }
    return output
}

indirect enum Statement {
    case declaration(property: String, value: String)
    case block(selectors: String, body: [Statement])
}

/// Reads statements: a declaration ends at `;`, a block's selectors at `{`,
/// and neither counts what is quoted or bracketed.
struct StatementReader {
    let characters: [Character]
    var index = 0

    init(_ text: String) {
        characters = Array(uncommented(text))
    }

    mutating func statements() -> [Statement] {
        var result: [Statement] = []
        while true {
            while index < characters.count, characters[index].isWhitespace { index += 1 }
            guard index < characters.count else { return result }
            if characters[index] == "}" {
                index += 1
                return result
            }
            var text = ""
            var depth = 0
            var quote: Character?
            while index < characters.count {
                let character = characters[index]
                if let open = quote {
                    if character == open { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == "(" || character == "[" {
                    depth += 1
                } else if character == ")" || character == "]" {
                    depth -= 1
                } else if depth == 0, character == "{" || character == ";" || character == "}" {
                    break
                }
                text.append(character)
                index += 1
            }
            let terminator = index < characters.count ? characters[index] : ";"
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if terminator == "{" {
                index += 1
                result.append(.block(selectors: trimmed, body: statements()))
                continue
            }
            if terminator == ";" { index += 1 }
            guard !trimmed.isEmpty else { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { fail("cannot read '\(trimmed)'") }
            result.append(.declaration(
                property: trimmed[..<colon].trimmingCharacters(in: .whitespaces),
                value: trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
    }
}

/// `text` split at the commas that are not quoted or bracketed.
func topLevelParts(_ text: String) -> [String] {
    var parts: [String] = []
    var current = ""
    var depth = 0
    var quote: Character?
    for character in text {
        if let open = quote {
            if character == open { quote = nil }
        } else if character == "\"" || character == "'" {
            quote = character
        } else if character == "(" || character == "[" {
            depth += 1
        } else if character == ")" || character == "]" {
            depth -= 1
        } else if depth == 0, character == "," {
            parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
            current = ""
            continue
        }
        current.append(character)
    }
    parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
    return parts.filter { !$0.isEmpty }
}

// MARK: - Selectors

enum Literal: Hashable {
    case text(String)
    case number(Double)
    case null
}

struct Condition {
    let key: String
    let operation: String
    let value: Literal
}

struct Selector {
    var layers: [String] = []
    var attachment = ""
    var conditions: [Condition] = []
    var minimumZoom = 0
    var maximumZoom = 99
    /// Filters and zooms, which CartoCSS weighs a selector by.
    var weight = 0

    func nested(_ child: Self) -> Self {
        var combined = self
        if !child.layers.isEmpty { combined.layers = child.layers }
        if !child.attachment.isEmpty { combined.attachment = child.attachment }
        combined.conditions += child.conditions
        combined.minimumZoom = max(minimumZoom, child.minimumZoom)
        combined.maximumZoom = min(maximumZoom, child.maximumZoom)
        combined.weight += child.weight
        return combined
    }
}

let filterPattern = try! NSRegularExpression(
    pattern: #"^\s*("[^"]+"|'[^']+'|[A-Za-z_:][A-Za-z0-9_:]*)\s*(=~|!=|>=|<=|=|>|<)\s*(.+?)\s*$"#
)

func literal(_ text: String) -> Literal {
    if text == "null" { return .null }
    if let first = text.first, first == "'" || first == "\"", text.last == first, text.count >= 2 {
        return .text(String(text.dropFirst().dropLast()))
    }
    if let number = Double(text) { return .number(number) }
    fail("cannot read the value \(text)")
}

func selector(_ text: String) -> Selector {
    var result = Selector()
    let characters = Array(text)
    var index = 0
    func identifier() -> String {
        var name = ""
        while index < characters.count,
              characters[index].isLetter || characters[index].isNumber || "-_".contains(characters[index]) {
            name.append(characters[index])
            index += 1
        }
        return name
    }
    while index < characters.count {
        let character = characters[index]
        if character.isWhitespace {
            index += 1
        } else if character == "#" {
            index += 1
            result.layers.append(identifier())
        } else if character == ":", index + 1 < characters.count, characters[index + 1] == ":" {
            index += 2
            result.attachment = identifier()
        } else if character == "[" {
            var content = ""
            var quote: Character?
            index += 1
            while index < characters.count {
                let inner = characters[index]
                if let open = quote {
                    if inner == open { quote = nil }
                } else if inner == "\"" || inner == "'" {
                    quote = inner
                } else if inner == "]" {
                    break
                }
                content.append(inner)
                index += 1
            }
            index += 1
            addFilter(content, to: &result)
        } else if character.isLetter {
            // A bare element, `Map`: no layer of the map's points.
            result.layers.append("element:" + identifier())
        } else {
            fail("cannot read the selector \(text)")
        }
    }
    return result
}

func addFilter(_ content: String, to selector: inout Selector) {
    let range = NSRange(content.startIndex..., in: content)
    guard let match = filterPattern.firstMatch(in: content, range: range),
          let keyRange = Range(match.range(at: 1), in: content),
          let operationRange = Range(match.range(at: 2), in: content),
          let valueRange = Range(match.range(at: 3), in: content)
    else { fail("cannot read the filter [\(content)]") }
    var key = String(content[keyRange])
    if key.first == "\"" || key.first == "'" { key = String(key.dropFirst().dropLast()) }
    let operation = String(content[operationRange])
    let value = literal(String(content[valueRange]))
    selector.weight += 1
    guard key == "zoom" else {
        selector.conditions.append(Condition(key: key, operation: operation, value: value))
        return
    }
    guard case let .number(number) = value else { fail("a zoom that is not a number: [\(content)]") }
    let zoom = Int(number)
    switch operation {
    case ">=": selector.minimumZoom = max(selector.minimumZoom, zoom)
    case ">": selector.minimumZoom = max(selector.minimumZoom, zoom + 1)
    case "<=": selector.maximumZoom = min(selector.maximumZoom, zoom)
    case "<": selector.maximumZoom = min(selector.maximumZoom, zoom - 1)
    case "=":
        selector.minimumZoom = max(selector.minimumZoom, zoom)
        selector.maximumZoom = min(selector.maximumZoom, zoom)
    default: fail("cannot read the zoom [\(content)]")
    }
}

// MARK: - Rules

struct Rule {
    let attachment: String
    let instance: String
    let property: String
    let value: String
    let selector: Selector
    let index: Int
}

var rules: [Rule] = []
var variableSources: [String: String] = [:]
var declarationIndex = 0

func flatten(_ statements: [Statement], under parents: [Selector], topLevel: Bool) {
    for statement in statements {
        switch statement {
        case let .declaration(property, value):
            if topLevel, property.hasPrefix("@") {
                variableSources[property] = value
                continue
            }
            let slash = property.firstIndex(of: "/")
            let instance = slash.map { String(property[..<$0]) } ?? ""
            let name = slash.map { String(property[property.index(after: $0)...]) } ?? property
            for parent in parents {
                rules.append(Rule(
                    attachment: parent.attachment,
                    instance: instance,
                    property: name,
                    value: value,
                    selector: parent,
                    index: declarationIndex
                ))
            }
            declarationIndex += 1
        case let .block(text, body):
            let children = topLevelParts(text).map(selector)
            flatten(body, under: parents.flatMap { parent in children.map(parent.nested) }, topLevel: false)
        }
    }
}

let styleFolder = cartoRoot.appending(path: "style")
let styleFiles = (try? FileManager.default.contentsOfDirectory(atPath: styleFolder.path))?
    .filter { $0.hasSuffix(".mss") }
    .sorted() ?? []
let pointFiles: Set = ["amenity-points.mss", "stations.mss"]
let missingPointFiles = pointFiles.subtracting(styleFiles)
guard missingPointFiles.isEmpty else {
    fail("no style/\(missingPointFiles.sorted().joined(separator: " or style/")) in \(cartoRoot.path)")
}
for file in styleFiles {
    var reader = StatementReader(read("style/\(file)"))
    let statements = reader.statements()
    // Every file's variables are read, because the points' colors are named
    // after the land's; only the points' own rules are evaluated.
    let parents = [Selector()]
    if pointFiles.contains(file) {
        flatten(statements, under: parents, topLevel: true)
    } else {
        for case let .declaration(property, value) in statements where property.hasPrefix("@") {
            variableSources[property] = value
        }
    }
}

// MARK: - Values

struct Color: Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    var hex: String {
        let channels = [red, green, blue].map { Int(max(0, min(255, $0)).rounded()) }
        let opaque = channels.map { String(format: "%02X", $0) }.joined()
        guard alpha < 1 else { return "#" + opaque }
        return "#" + opaque + String(format: "%02X", Int((max(0, min(1, alpha)) * 255).rounded()))
    }

    /// Hue in degrees, saturation and lightness as shares, as less.js reads a color.
    var hsl: (hue: Double, saturation: Double, lightness: Double) {
        let red = red / 255, green = green / 255, blue = blue / 255
        let maximum = max(red, green, blue), minimum = min(red, green, blue)
        let lightness = (maximum + minimum) / 2
        guard maximum != minimum else { return (0, 0, lightness) }
        let delta = maximum - minimum
        let saturation = lightness > 0.5 ? delta / (2 - maximum - minimum) : delta / (maximum + minimum)
        let hue: Double = switch maximum {
        case red: (green - blue) / delta + (green < blue ? 6 : 0)
        case green: (blue - red) / delta + 2
        default: (red - green) / delta + 4
        }
        return (hue * 60, saturation, lightness)
    }

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(hue: Double, saturation: Double, lightness: Double, alpha: Double) {
        let hue = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        let saturation = max(0, min(1, saturation)), lightness = max(0, min(1, lightness))
        let upper = lightness <= 0.5 ? lightness * (saturation + 1) : lightness + saturation - lightness * saturation
        let lower = lightness * 2 - upper
        func channel(_ shade: Double) -> Double {
            let shade = shade < 0 ? shade + 1 : shade > 1 ? shade - 1 : shade
            if shade * 6 < 1 { return lower + (upper - lower) * shade * 6 }
            if shade * 2 < 1 { return upper }
            if shade * 3 < 2 { return lower + (upper - lower) * (2 / 3 - shade) * 6 }
            return lower
        }
        self.init(
            red: channel(hue + 1 / 3) * 255,
            green: channel(hue) * 255,
            blue: channel(hue - 1 / 3) * 255,
            alpha: alpha
        )
    }
}

enum Value: Equatable {
    case number(Double)
    case color(Color)
    case text(String)
    case url(String)
    case keyword(String)
    case list([Value])
}

let namedColors: [String: Color] = [
    "white": Color(red: 255, green: 255, blue: 255),
    "black": Color(red: 0, green: 0, blue: 0),
    "grey": Color(red: 128, green: 128, blue: 128),
    "gray": Color(red: 128, green: 128, blue: 128),
    "red": Color(red: 255, green: 0, blue: 0),
    "green": Color(red: 0, green: 128, blue: 0),
    "blue": Color(red: 0, green: 0, blue: 255),
    "transparent": Color(red: 0, green: 0, blue: 0, alpha: 0),
]

var variableValues: [String: Value] = [:]
var evaluating: Set<String> = []

func variable(_ name: String) -> Value {
    if let value = variableValues[name] { return value }
    guard let source = variableSources[name] else { fail("no variable \(name)") }
    guard evaluating.insert(name).inserted else { fail("\(name) refers to itself") }
    let value = evaluate(source)
    evaluating.remove(name)
    variableValues[name] = value
    return value
}

func evaluate(_ text: String) -> Value {
    let parts = topLevelParts(text)
    if parts.count > 1 { return .list(parts.map(evaluate)) }
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    // Arithmetic on numbers, the weaker operators split first.
    for operators in [[" + ", " - "], [" * ", " / "]] {
        if let (left, operation, right) = lastTopLevel(operators, in: text) {
            let lhs = number(evaluate(left), in: text)
            let rhs = number(evaluate(right), in: text)
            let result: Double = switch operation {
            case " + ": lhs + rhs
            case " - ": lhs - rhs
            case " * ": lhs * rhs
            default: lhs / rhs
            }
            return .number(result)
        }
    }
    if text.hasPrefix("@") { return variable(text) }
    if text.hasPrefix("#") { return .color(hexColor(text)) }
    if let first = text.first, first == "'" || first == "\"", text.last == first {
        return .text(String(text.dropFirst().dropLast()))
    }
    // An attribute named bare, as a subway entrance's `text-name: [ref]`, is
    // the text `"[ref]"` is.
    if text.hasPrefix("["), text.hasSuffix("]") { return .text(text) }
    if let open = text.firstIndex(of: "("), text.hasSuffix(")") {
        let name = String(text[..<open])
        let inner = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
        return function(name, topLevelParts(inner))
    }
    if let number = Double(text.hasSuffix("%") ? String(text.dropLast()) : text) { return .number(number) }
    if let color = namedColors[text] { return .color(color) }
    if text.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "_" }) { return .keyword(text) }
    fail("cannot evaluate \(text)")
}

/// The last of `operators` in `text` that is not quoted or bracketed, with
/// what stands either side of it.
func lastTopLevel(_ operators: [String], in text: String) -> (String, String, String)? {
    var depth = 0
    var quote: Character?
    var found: (String.Index, String)?
    var index = text.startIndex
    while index < text.endIndex {
        let character = text[index]
        if let open = quote {
            if character == open { quote = nil }
        } else if character == "\"" || character == "'" {
            quote = character
        } else if character == "(" || character == "[" {
            depth += 1
        } else if character == ")" || character == "]" {
            depth -= 1
        } else if depth == 0, let operation = operators.first(where: { text[index...].hasPrefix($0) }) {
            found = (index, operation)
        }
        index = text.index(after: index)
    }
    guard let (at, operation) = found else { return nil }
    return (String(text[..<at]), operation, String(text[text.index(at, offsetBy: operation.count)...]))
}

func hexColor(_ text: String) -> Color {
    var digits = String(text.dropFirst())
    if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
    guard digits.count == 6, let value = Int(digits, radix: 16) else { fail("cannot read the color \(text)") }
    return Color(red: Double(value >> 16 & 0xFF), green: Double(value >> 8 & 0xFF), blue: Double(value & 0xFF))
}

func color(_ value: Value, in context: String) -> Color {
    switch value {
    case let .color(color): return color
    case let .keyword(name):
        guard let named = namedColors[name] else { fail("no color \(name) in \(context)") }
        return named
    default:
        fail("\(context) is not a color")
    }
}

func number(_ value: Value, in context: String) -> Double {
    guard case let .number(number) = value else { fail("\(context) is not a number") }
    return number
}

func function(_ name: String, _ arguments: [String]) -> Value {
    let values = arguments.map(evaluate)
    let context = "\(name)(\(arguments.joined(separator: ", ")))"
    switch name {
    case "rgb", "rgba":
        let channels = values.map { number($0, in: context) }
        guard channels.count >= 3 else { fail("\(context) has too few channels") }
        return .color(Color(red: channels[0], green: channels[1], blue: channels[2], alpha: channels.count > 3 ? channels[3] : 1))
    case "url":
        guard case let .text(path)? = values.first else { fail("\(context) names no file") }
        return .url(path)
    case "darken", "lighten", "saturate", "desaturate":
        let base = color(values[0], in: context)
        let amount = number(values[1], in: context) / 100
        var (hue, saturation, lightness) = base.hsl
        switch name {
        case "darken": lightness -= amount
        case "lighten": lightness += amount
        case "saturate": saturation += amount
        default: saturation -= amount
        }
        return .color(Color(hue: hue, saturation: saturation, lightness: lightness, alpha: base.alpha))
    case "fade", "fadeout":
        var base = color(values[0], in: context)
        let amount = number(values[1], in: context) / 100
        base.alpha = name == "fade" ? amount : base.alpha - amount
        return .color(base)
    case "mix":
        // less.js's mix, which weighs by alpha as well as by `weight`.
        let first = color(values[0], in: context)
        let second = color(values[1], in: context)
        let share = values.count > 2 ? number(values[2], in: context) / 100 : 0.5
        let scaled = share * 2 - 1
        let alphaDifference = first.alpha - second.alpha
        let firstWeight = ((scaled * alphaDifference == -1
                ? scaled
                : (scaled + alphaDifference) / (1 + scaled * alphaDifference)) + 1) / 2
        let secondWeight = 1 - firstWeight
        return .color(Color(
            red: first.red * firstWeight + second.red * secondWeight,
            green: first.green * firstWeight + second.green * secondWeight,
            blue: first.blue * firstWeight + second.blue * secondWeight,
            alpha: first.alpha * share + second.alpha * (1 - share)
        ))
    default:
        fail("no function \(name)")
    }
}

// MARK: - Evaluating

struct Point {
    let layer: String
    var attributes: [String: Literal]
}

func equal(_ lhs: Literal, _ rhs: Literal) -> Bool {
    switch (lhs, rhs) {
    case (.null, .null): true
    case let (.text(left), .text(right)): left == right
    case let (.number(left), .number(right)): left == right
    case let (.text(left), .number(right)): Double(left) == right
    case let (.number(left), .text(right)): left == Double(right)
    default: false
    }
}

/// Whether `condition` holds for `value`, as Mapnik reads a filter: a
/// missing value equals only `null`, and is never greater or smaller.
func holds(_ condition: Condition, for value: Literal) -> Bool {
    switch condition.operation {
    case "=": return equal(value, condition.value)
    case "!=": return !equal(value, condition.value)
    case "=~":
        guard case let .text(text) = value, case let .text(pattern) = condition.value,
              let expression = try? NSRegularExpression(pattern: "^(?:\(pattern))$")
        else { return false }
        return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    default:
        let number: Double? = switch value {
        case let .number(number): number
        case let .text(text): Double(text)
        case .null: nil
        }
        guard let number, case let .number(bound) = condition.value else { return false }
        return switch condition.operation {
        case ">": number > bound
        case ">=": number >= bound
        case "<": number < bound
        default: number <= bound
        }
    }
}

let rulesByLayer = rules.reduce(into: [String: [Rule]]()) { result, rule in
    for layer in rule.selector.layers { result[layer, default: []].append(rule) }
}

/// A symbolizer's declarations: its attachment and instance, then its properties.
struct Symbolizer {
    let key: String
    let order: Int
    var properties: [String: String]
}

/// What `point` is drawn with at `zoom`: for each attachment, instance and
/// property, the most specific declaration that matches, and the later of
/// two as specific.
func symbolizers(for point: Point, at zoom: Int) -> [Symbolizer] {
    var winners: [String: Rule] = [:]
    for rule in rulesByLayer[point.layer] ?? []
    where rule.selector.minimumZoom <= zoom && zoom <= rule.selector.maximumZoom
        && rule.selector.conditions.allSatisfy({ holds($0, for: point.attributes[$0.key] ?? .null) }) {
        let key = "\(rule.attachment)|\(rule.instance)|\(rule.property)"
        if let current = winners[key],
           (current.selector.weight, current.index) > (rule.selector.weight, rule.index) {
            continue
        }
        winners[key] = rule
    }
    var groups: [String: Symbolizer] = [:]
    for rule in winners.values {
        let key = "\(rule.attachment)|\(rule.instance)"
        var group = groups[key] ?? Symbolizer(key: key, order: rule.index, properties: [:])
        group.properties[rule.property] = rule.value
        groups[key] = Symbolizer(key: key, order: min(group.order, rule.index), properties: group.properties)
    }
    return groups.values.sorted { $0.order < $1.order }
}

// MARK: - The table

struct Icon: Codable, Equatable {
    /// The icon's asset, or none for Mapnik's own ellipse.
    var asset: String?
    /// None for an icon drawn in its own colors.
    var fill: String?
    var width: Double
    var height: Double
    var opacity: Double?
    var lineWidth: Double?
    var lineColor: String?
    var allowOverlap: Bool?
    var ignorePlacement: Bool?
}

struct Text: Codable, Equatable {
    /// The attribute the text is: `name`, `ref` or `operator`.
    var field: String
    var size: Double
    var fill: String
    var halo: String
    var haloRadius: Double
    var dy: Double
    var wrapWidth: Double
    var lineSpacing: Double
    var face: String
    var opacity: Double?
    var margin: Double?
}

struct Band: Codable, Equatable {
    var from: Int
    var to: Int
    var icons: [Icon]
    var text: Text?
}

/// How an area is drawn once its size, in pixels, is past `above`, until
/// the next range's.
struct AreaBands: Codable, Equatable {
    var above: Double
    var bands: [Band]
}

struct Entry: Codable {
    var kind: String
    var detail: String?
    var named: Bool?
    var feature: String
    var lowPriority: Bool
    /// Where one of Carto's stations stands in the order of the layer of
    /// their own that places them, right after the names of places.
    var station: Int?
    var elevation: Bool?
    /// The bands Carto draws the point with when its access is one of the
    /// table's `restrictedAccess`, where they are not `bands`.
    var restricted: [Band]?
    var bands: [Band]
    /// How an area of the kind is drawn, by its size, where Carto's rules
    /// look at the size.
    var areas: [AreaBands]?
    /// The same where its access is restricted, where they are not `areas`:
    /// empty where a restricted area is drawn as its point is at any size,
    /// because a table without them reads `areas` here.
    var restrictedAreas: [AreaBands]?
}

struct Table: Codable {
    var source: String
    /// The `access` values Carto counts as restricted.
    var restrictedAccess: [String]
    /// The largest area, in pixels, drawn at a point.
    var areaLimit: Double
    var entries: [Entry]
}

var usedIcons: [String: (source: String, width: Double, height: Double)] = [:]

func svgSize(_ path: String) -> (width: Double, height: Double) {
    let text = read(path)
    func attribute(_ name: String) -> Double? {
        guard let range = text.range(of: #"\b\#(name)="([0-9.]+)(px)?""#, options: .regularExpression) else {
            return nil
        }
        let match = String(text[range])
        return Double(match.split(separator: "\"")[1].replacingOccurrences(of: "px", with: ""))
    }
    guard let width = attribute("width"), let height = attribute("height") else { fail("\(path) has no size") }
    return (width, height)
}

func assetName(_ path: String) -> String {
    "carto-" + path.replacingOccurrences(of: "symbols/", with: "")
        .replacingOccurrences(of: ".svg", with: "")
        .replacingOccurrences(of: "/", with: "-")
}

func icon(_ properties: [String: String]) -> Icon {
    func value(_ name: String) -> Value? { properties[name].map(evaluate) }
    var width = value("marker-width").map { number($0, in: "marker-width") }
    var height = value("marker-height").map { number($0, in: "marker-height") }
    var asset: String?
    if case let .url(path)? = value("marker-file") {
        let size = svgSize(path)
        // A width or a height alone keeps the icon's shape.
        switch (width, height) {
        case (nil, nil): (width, height) = (size.width, size.height)
        case let (given?, nil): height = given * size.height / size.width
        case let (nil, given?): width = given * size.width / size.height
        default: break
        }
        let name = assetName(path)
        usedIcons[name] = (path, size.width, size.height)
        asset = name
    } else {
        // Mapnik's ellipse: ten pixels, or as wide as it is tall.
        width = width ?? height ?? 10
        height = height ?? width
    }
    let isTrue = { (name: String) in value(name) == .keyword("true") ? true : nil }
    return Icon(
        asset: asset,
        // An icon with no fill keeps its own colors, as Carto's bus station
        // does for its white background; Mapnik's ellipse is blue.
        fill: value("marker-fill").map { color($0, in: "marker-fill").hex } ?? (asset == nil ? "#0000FF" : nil),
        width: width ?? 10,
        height: height ?? 10,
        opacity: value("marker-opacity").map { number($0, in: "marker-opacity") },
        lineWidth: asset == nil ? (value("marker-line-width").map { number($0, in: "marker-line-width") } ?? 0.5) : nil,
        lineColor: asset == nil ? (value("marker-line-color").map { color($0, in: "marker-line-color").hex } ?? "#000000")
            : nil,
        allowOverlap: isTrue("marker-allow-overlap"),
        ignorePlacement: isTrue("marker-ignore-placement")
    )
}

func text(_ properties: [String: String]) -> Text? {
    guard let name = properties["text-name"],
          properties["text-placement"].map({ evaluate($0) != .keyword("line") }) ?? true
    else { return nil }
    guard case let .text(expression) = evaluate(name),
          let field = expression.firstMatch(of: #/^\[([a-z_]+)\]$/#)?.1
    else { fail("cannot read the text \(name)") }
    func value(_ name: String) -> Value? { properties[name].map(evaluate) }
    func numberValue(_ name: String, _ fallback: Double) -> Double {
        value(name).map { number($0, in: name) } ?? fallback
    }
    let fonts: String = switch value("text-face-name") {
    case let .text(font)?: font
    case let .list(list)?: list.compactMap { if case let .text(font) = $0 { font } else { nil } }.joined(separator: ",")
    default: ""
    }
    return Text(
        field: String(field),
        size: numberValue("text-size", 10),
        fill: value("text-fill").map { color($0, in: "text-fill").hex } ?? "#000000",
        halo: value("text-halo-fill").map { color($0, in: "text-halo-fill").hex } ?? "#FFFFFF",
        haloRadius: numberValue("text-halo-radius", 0),
        dy: numberValue("text-dy", 0),
        wrapWidth: numberValue("text-wrap-width", 0),
        lineSpacing: numberValue("text-line-spacing", 0),
        face: fonts.contains("Italic") ? "italic" : fonts.contains("Bold") ? "bold" : "regular",
        opacity: value("text-opacity").map { number($0, in: "text-opacity") },
        margin: value("text-margin").map { number($0, in: "text-margin") }
    )
}

// MARK: - What the archive can name

let project = read("project.mml")

/// One layer's SQL, from its id to the next layer's.
func layerSource(_ id: String) -> String {
    guard let start = project.range(of: "  - id: \(id)\n") else { fail("no layer \(id) in project.mml") }
    let rest = project[start.upperBound...]
    let end = rest.range(of: "\n  - id: ")?.lowerBound ?? rest.endIndex
    return String(rest[..<end])
}

func minimumZoom(of id: String) -> Int {
    guard let match = layerSource(id).firstMatch(of: #/\n\s+minzoom: (\d+)/#) else { return 0 }
    return Int(match.1) ?? 0
}

/// The `access` values a layer's SQL turns into `int_access = 'restricted'`.
func restrictedAccessValues(in id: String) -> [String] {
    let pattern = #/CASE WHEN access IN \(([^)]*)\) THEN 'restricted' ELSE 'yes' END AS int_access/#
    guard let match = layerSource(id).firstMatch(of: pattern) else { fail("no int_access in \(id)'s SQL") }
    return match.1.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " '")) }
}

/// The access Carto's points count as restricted, which its rules draw
/// faded, or later, or not at all. The text layers read the same SQL as the
/// icon layers they name.
let restrictedAccess: [String] = {
    let values = restrictedAccessValues(in: "amenity-points")
    guard !values.isEmpty, restrictedAccessValues(in: "amenity-low-priority") == values else {
        fail("the point layers count different access as restricted")
    }
    return values
}()

/// A feature a layer's SQL builds: `'amenity_' || CASE WHEN amenity IN
/// (...) THEN amenity`.
struct SQLFeature {
    let key: String
    let value: String
    /// The further tag the feature asks for, and the values it must take:
    /// `... AND tags->'vending' IN (...)`. The vector extras carry it as the
    /// point's `kind_detail`.
    let requires: (key: String, values: [String])?
}

/// The features a layer's SQL builds, in the order its COALESCE tries them.
func features(of id: String) -> [SQLFeature] {
    let source = layerSource(id)
    // The condition runs from the list to THEN, across lines where it must,
    // and never past an END into the next CASE.
    let pattern = #/'([a-z_]+)_' *\|\| *CASE WHEN *\(?(?:"?([a-z_]+)"?|tags->'([a-z_:]+)') +IN *\(([^)]*)\)((?:(?!END).)*?)THEN *(?:"?([a-z_]+)"?|tags->'([a-z_:]+)') +END/#
    var result: [SQLFeature] = []
    for match in source.matches(of: pattern.dotMatchesNewlines()) {
        let column = match.2.map(String.init) ?? match.3.map(String.init) ?? ""
        let then = match.6.map(String.init) ?? match.7.map(String.init) ?? ""
        // `'diplomatic_' || CASE WHEN tags->'office' IN ('diplomatic') ...
        // THEN tags->'diplomatic'` names a value from another tag.
        guard then == column else { continue }
        let condition = String(match.5)
        // An `OR` outside brackets widens a feature rather than narrowing it.
        var outside = condition
        while let bracket = outside.firstMatch(of: #/\([^()]*\)/#) { outside.removeSubrange(bracket.range) }
        let required = outside.contains(" OR ")
            ? nil
            : condition.firstMatch(of: #/AND +tags->'([a-z_:]+)' +IN *\(([^)]*)\)/#)
        let requires = required.map { match in
            (key: String(match.1), values: match.2.matches(of: #/'([^']+)'/#).map { String($0.1) })
        }
        for value in match.4.matches(of: #/'([^']+)'/#) {
            result.append(SQLFeature(key: String(match.1), value: String(value.1), requires: requires))
        }
        // `OR (boundary = 'protected_area' AND tags->'protect_class' IN
        // (...))`: one more value, drawn only with the further tag.
        let alternative = #/OR +\("?([a-z_]+)"? *= *'([a-z_]+)' +AND +tags->'([a-z_:]+)' +IN *\(([^)]*)\)\)/#
        for other in condition.matches(of: alternative) where String(other.1) == column {
            result.append(SQLFeature(
                key: String(match.1),
                value: String(other.2),
                requires: (key: String(other.3), values: other.4.matches(of: #/'([^']+)'/#).map { String($0.1) })
            ))
        }
    }
    return result
}

let mainFeatures = features(of: "amenity-points")
let lowFeatures = features(of: "amenity-low-priority")
guard !mainFeatures.isEmpty, !lowFeatures.isEmpty else { fail("no features read from project.mml") }

/// The shop values Carto draws an icon of its own for; any other shop it
/// draws is `other`.
let iconShops: Set<String> = {
    guard let list = layerSource("amenity-points").firstMatch(of: #/CASE WHEN shop IN \(([^)]*)\) THEN shop/#) else {
        fail("no list of shops in project.mml")
    }
    return Set(list.1.matches(of: #/'([^']+)'/#).map { String($0.1) })
}()

/// Every shop value Carto draws at all.
let drawnShops = read("common-values.sql").matches(of: #/\('shop', '([^']+)'\)/#).map { String($0.1) }

/// The values a condition tests `key` against, which are worth a variant.
func testedValues(_ key: String) -> [String] {
    var values: Set<String> = []
    for rule in rules {
        for condition in rule.selector.conditions where condition.key == key {
            if case let .text(text) = condition.value { values.insert(text) }
        }
    }
    return values.sorted()
}

/// The tags the archive keeps as a point's `kind_detail` that Carto's rules
/// test, each with the features it is kept for where not every one: a place
/// of worship's religion and a pitch's sport, which the basemap keeps, and a
/// car park's `parking`, which the vector extras keep. Carto also tests a
/// bicycle or a motorcycle parking's `parking`, which neither keeps.
let testedDetails: [(key: String, features: Set<String>?)] = [
    ("religion", nil),
    ("sport", nil),
    ("parking", ["amenity_parking"]),
]

/// Whether any rule that can draw `feature` tests `key`.
func rules(of feature: String, shop: String?, test key: String) -> Bool {
    rules.contains { rule in
        rule.selector.conditions.contains { $0.key == key } && rule.selector.conditions.allSatisfy { condition in
            switch (condition.key, condition.operation) {
            case ("feature", "="): equal(.text(feature), condition.value)
            case ("shop", "="): shop.map { equal(.text($0), condition.value) } ?? false
            default: true
            }
        }
    }
}

/// The features whose names Carto writes with the height under them, or
/// alone where there is no name (`project.mml`'s amenity-points query).
let featuresWithElevation: Set<String> = [
    "natural_peak", "natural_volcano", "natural_saddle", "tourism_alpine_hut", "tourism_wilderness_hut",
    "amenity_shelter", "mountain_pass",
]

/// Whether Carto writes the height of `feature` with `detail`: of the
/// information points, only a guidepost's.
func writesElevation(feature: String, detail: String?) -> Bool {
    feature == "tourism_information" ? detail == "guidepost" : featuresWithElevation.contains(feature)
}

/// The kinds the map names by other means: the water layer's and the
/// glaciers' names.
let namedElsewhere: Set<String> = ["water", "glacier"]

var entries: [Entry] = []
var seenKinds: Set<String> = []

/// The icons and the text Carto draws at each zoom, run together where they
/// stay the same.
func bands(_ look: (Int) -> (icons: [Icon], text: Text?)) -> [Band] {
    var bands: [Band] = []
    for zoom in zooms {
        let (icons, label) = look(zoom)
        guard !icons.isEmpty || label != nil else { continue }
        if var last = bands.last, last.to == zoom - 1, last.icons == icons, last.text == label {
            last.to = zoom
            bands[bands.count - 1] = last
        } else {
            bands.append(Band(from: zoom, to: zoom, icons: icons, text: label))
        }
    }
    return bands
}

func icons(of point: Point, at zoom: Int) -> [Icon] {
    symbolizers(for: point, at: zoom)
        .filter { $0.properties.keys.contains { $0.hasPrefix("marker-") } }
        .map { icon($0.properties) }
}

func label(of point: Point, at zoom: Int) -> Text? {
    symbolizers(for: point, at: zoom).lazy.compactMap { text($0.properties) }.first
}

func bands(of point: Point, textLayer: String, iconLayerZoom: Int, textLayerZoom: Int) -> [Band] {
    bands { zoom in
        let textPoint = Point(layer: textLayer, attributes: point.attributes)
        return (
            zoom < iconLayerZoom ? [] : icons(of: point, at: zoom),
            zoom < textLayerZoom ? nil : label(of: textPoint, at: zoom)
        )
    }
}

// MARK: - Areas

// An area is drawn at a point inside it, by the same rules as a point, but
// those rules also test its size on the screen, `way_pixels`: the area in
// the square pixels of a 256-pixel tile at the zoom drawn. A larger forest
// is named from a wider zoom and in a larger size. The vector extras carry
// each area's size, and the table gives each kind its bands for each range
// of sizes the rules tell apart.

/// The bounds a layer's SQL puts on the areas it reads, in pixels:
/// `way_area > 100*POW(...)` and `way_area < 768000*POW(...)`.
func areaBounds(of id: String) -> (above: Double?, below: Double?) {
    let source = layerSource(id)
    let bound = { (operation: String) -> Double? in
        let pattern = try! Regex(#"way_area \#(operation) (\d+)\*POW\(!scale_denominator!"#)
        return source.firstMatch(of: pattern).flatMap { ($0.output[1].substring).flatMap { Double($0) } }
    }
    return (bound(">"), bound("<"))
}

/// The layer Carto names areas in below the zoom its points begin at, and
/// the features it names there.
let lowZoomTextLayer = "text-poly-low-zoom"
let lowZoomTextFeatures = Set(features(of: lowZoomTextLayer).map { "\($0.key)_\($0.value)" })
let lowZoomTextZooms: ClosedRange<Int> = {
    let source = layerSource(lowZoomTextLayer)
    guard let match = source.firstMatch(of: #/\n\s+minzoom: (\d+)\n\s+maxzoom: (\d+)/#),
          let lowest = Int(match.1), let highest = Int(match.2)
    else { fail("no zooms for \(lowZoomTextLayer) in project.mml") }
    return lowest...highest
}()
let lowZoomTextBounds = areaBounds(of: lowZoomTextLayer)

/// The largest area, in pixels, Carto names or marks at a point: past it
/// Carto names only a protected area, along its edge.
let areaLimit: Double = {
    let limits = ["amenity-points", "amenity-low-priority"].map { areaBounds(of: $0).below }
    guard let limit = limits.first ?? nil, limits.allSatisfy({ $0 == limit }),
          lowZoomTextBounds.below == limit, lowZoomTextBounds.above != nil
    else { fail("the point layers bound their areas differently") }
    return limit
}()

/// Every size the rules tell apart, smallest first: the area thresholds of
/// the rules and of the SQL.
let areaThresholds: [Double] = {
    var thresholds: Set<Double> = [lowZoomTextBounds.above].compactMap { $0 }.reduce(into: []) { $0.insert($1) }
    for rule in rules {
        for condition in rule.selector.conditions where condition.key == "way_pixels" {
            if case let .number(number) = condition.value, number > 0, number < areaLimit { thresholds.insert(number) }
        }
    }
    return thresholds.sorted()
}()

/// The ranges of size an area can fall in, by their lower bound, which a
/// size must exceed; each with a size inside it to evaluate the rules at.
let areaRanges: [(above: Double, sample: Double)] = zip([0] + areaThresholds, areaThresholds + [areaLimit])
    .map { (above: $0, sample: ($0 + $1) / 2) }

/// How an area of `feature` with `attributes` and `pixels` in size is
/// drawn at each zoom: below the points' first zoom only in the low-zoom
/// layer, and then only for the features and sizes its SQL reads.
func areaBands(of attributes: [String: Literal], feature: String, pixels: Double) -> [Band] {
    var area = attributes
    area["way_pixels"] = .number(pixels)
    let iconLayer = Point(layer: "amenity-points", attributes: area)
    let textLayer = Point(layer: "text-point", attributes: area)
    let lowZoomText = Point(layer: lowZoomTextLayer, attributes: area)
    let pointsZoom = minimumZoom(of: "amenity-points")
    let textZoom = minimumZoom(of: "text-point")
    let namedAtLowZoom = lowZoomTextFeatures.contains(feature) && pixels > (lowZoomTextBounds.above ?? 0)
    return bands { zoom in
        let text = zoom >= textZoom ? label(of: textLayer, at: zoom)
            : namedAtLowZoom && lowZoomTextZooms.contains(zoom) ? label(of: lowZoomText, at: zoom)
            : nil
        return (zoom < pointsZoom ? [] : icons(of: iconLayer, at: zoom), text)
    }
}

/// Whether the table gives a kind its bands by size. The low-priority layer
/// marks points alone. A shop's or an office's size tells Carto only to name
/// a large one a zoom early, and the extras carry neither's, so the table
/// leaves out ranges no tile could reach; a mall is named as land is.
func drawnBySize(feature: String, shop: String?, lowPriority: Bool) -> Bool {
    !lowPriority && feature != "office" && (shop == nil || shop == "mall")
}

/// An area's bands for each range of size where they differ from the
/// range below, or `nil` where they are the point's at every size: the
/// rules for that kind do not look at the size. An area smaller than the
/// first range is drawn as the point is.
func areas(of attributes: [String: Literal], feature: String, point: [Band]) -> [AreaBands]? {
    var result: [AreaBands] = []
    for range in areaRanges {
        let bands = areaBands(of: attributes, feature: feature, pixels: range.sample)
        if (result.last?.bands ?? point) != bands { result.append(AreaBands(above: range.above, bands: bands)) }
    }
    return result.isEmpty ? nil : result
}

/// Everything an entry draws, to tell a detail that changes nothing.
struct Drawn: Equatable {
    let point: [Band]
    let restricted: [Band]
    let areas: [AreaBands]?
    let restrictedAreas: [AreaBands]?
}

func add(
    kind: String,
    feature: String,
    shop: String?,
    lowPriority: Bool,
    requires: (key: String, values: [String])? = nil
) {
    guard !namedElsewhere.contains(kind), seenKinds.insert(kind).inserted else { return }
    let iconLayer = lowPriority ? "amenity-low-priority" : "amenity-points"
    let textLayer = lowPriority ? "text-low-priority" : "text-point"
    var base: [String: Literal] = [
        "feature": .text(feature),
        "is_building": .text("no"),
        // A point has no area: the main layer counts that as nothing, the
        // low-priority one as missing.
        "way_pixels": lowPriority ? .null : .number(0),
    ]
    if let shop { base["shop"] = .text(iconShops.contains(shop) ? shop : "other") }
    let tested: [(key: String, value: String?)] = testedDetails
        .filter { $0.features?.contains(feature) ?? true }
        .map(\.key)
        .filter { rules(of: feature, shop: shop, test: $0) }
        .flatMap { key in testedValues(key).map { (key, Optional($0)) } }
    let required = requires.map { requires in requires.values.map { (key: requires.key, value: Optional($0)) } }
    let namings: [Bool?] = rules(of: feature, shop: shop, test: "name") ? [true, false] : [nil]
    // What the kind draws without a detail, named or not.
    var plainDrawn: [Bool?: Drawn] = [:]
    // A feature that asks for a further tag is drawn only with it.
    let plain: (key: String, value: String?) = ("", nil)
    for detail in required ?? [plain] + tested {
        for named in namings {
            var attributes = base
            attributes["name"] = named == false ? .null : .text("name")
            if let value = detail.value { attributes[detail.key] = .text(value) }
            let withAccess = { (access: String) -> (point: [Band], areas: [AreaBands]?) in
                attributes["int_access"] = .text(access)
                let point = bands(
                    of: Point(layer: iconLayer, attributes: attributes),
                    textLayer: textLayer,
                    iconLayerZoom: minimumZoom(of: iconLayer),
                    textLayerZoom: minimumZoom(of: textLayer)
                )
                let areas = drawnBySize(feature: feature, shop: shop, lowPriority: lowPriority)
                    ? areas(of: attributes, feature: feature, point: point)
                    : nil
                return (point, areas)
            }
            let (result, areas) = withAccess("yes")
            let (restricted, restrictedAreas) = withAccess("restricted")
            guard !result.isEmpty || areas != nil else { continue }
            let drawn = Drawn(point: result, restricted: restricted, areas: areas, restrictedAreas: restrictedAreas)
            if required == nil {
                // A detail that changes nothing is the plain kind's. Two
                // details drawn alike are each their own entry: a point
                // with either would find no entry of the other's and fall
                // back to the plain kind's.
                if detail.value == nil {
                    plainDrawn[named] = drawn
                } else if plainDrawn[named] == drawn {
                    continue
                }
            }
            entries.append(Entry(
                kind: kind,
                detail: detail.value,
                named: named,
                feature: feature,
                lowPriority: lowPriority,
                elevation: writesElevation(feature: feature, detail: detail.value) ? true : nil,
                restricted: restricted == result ? nil : restricted,
                bands: result,
                areas: areas,
                restrictedAreas: restrictedAreas == areas ? nil : restrictedAreas ?? []
            ))
        }
    }
}

/// The stops Carto draws in its `stations` layer, by the `railway` value the
/// archive files each under, and where the layer's `ORDER BY CASE railway`
/// places each: stations first, subway entrances last. The basemap keeps no
/// `station` tag, so its station is drawn as one that is not a subway's; the
/// vector extras keep it as the `kind_detail`, and bring a lift's station as
/// a `station` whose detail is `aerialway`. Neither keeps a `ref`, which
/// Carto writes by an entrance from zoom 19.
let stationOrders: [(kind: String, order: Int)] = {
    let source = layerSource("stations")
    let kinds = source.matches(of: #/railway (?:IN \(([^)]*)\)|= '([a-z_]+)')/#).flatMap { match in
        match.1.map { $0.matches(of: #/'([^']+)'/#).map { String($0.1) } } ?? match.2.map { [String($0)] } ?? []
    }
    guard !kinds.isEmpty,
          let order = source.firstMatch(of: #/CASE railway((?:\s+WHEN '[a-z_]+' THEN \d+)+)\s+ELSE (\d+)\s+END/#),
          let otherwise = Int(order.2)
    else { fail("no stations and their order in project.mml") }
    let ranks = Dictionary(uniqueKeysWithValues: order.1.matches(of: #/WHEN '([a-z_]+)' THEN (\d+)/#).map { match in
        (String(match.1), Int(match.2) ?? otherwise)
    })
    return kinds.map { (kind: $0, order: ranks[$0] ?? otherwise) }
}()

// The stations go first, ahead of the keys the amenity points share values
// across: their layer comes before the amenity points' in Carto too.
let stationsZoom = minimumZoom(of: "stations")
for (kind, order) in stationOrders {
    guard seenKinds.insert(kind).inserted else { fail("\(kind) is named twice") }
    let point = Point(layer: "stations", attributes: ["railway": .text(kind), "name": .text("name")])
    let result = bands(of: point, textLayer: "stations", iconLayerZoom: stationsZoom, textLayerZoom: stationsZoom)
    guard !result.isEmpty else { fail("stations.mss draws no \(kind)") }
    entries.append(Entry(kind: kind, feature: "railway_\(kind)", lowPriority: false, station: order, bands: result))
}
// A subway's station, which Carto holds back a zoom, and a lift's, which it
// draws from a zoom of its own and names in a lighter face: both a `station`
// to the archive, told apart by the detail the vector extras give.
let stationVariants: [(detail: String, feature: String, attributes: [String: Literal])] = [
    ("subway", "railway_station", ["railway": .text("station"), "station": .text("subway")]),
    ("aerialway", "aerialway_station", ["aerialway": .text("station")]),
]
for variant in stationVariants {
    guard let order = stationOrders.first(where: { $0.kind == "station" })?.order else { fail("no station's order") }
    let attributes = variant.attributes.merging(["name": .text("name")]) { own, _ in own }
    let point = Point(layer: "stations", attributes: attributes)
    let result = bands(of: point, textLayer: "stations", iconLayerZoom: stationsZoom, textLayerZoom: stationsZoom)
    guard !result.isEmpty else { fail("stations.mss draws no \(variant.feature) of \(variant.detail)") }
    entries.append(Entry(
        kind: "station",
        detail: variant.detail,
        feature: variant.feature,
        lowPriority: false,
        // A lift's station is none of the layer's three railway stops, which
        // its order places with the halts.
        station: variant.detail == "aerialway" ? order + 1 : order,
        bands: result
    ))
}
// A level crossing, which Carto draws in a layer of its own with no name:
// the kind the basemap files a `railway=level_crossing` under.
let crossingsZoom = minimumZoom(of: "railway-crossings")
let crossing = Point(
    layer: "railway-crossings",
    attributes: ["railway": .text("level_crossing"), "int_isminor": .text("no")]
)
let crossingBands = bands { zoom in (zoom < crossingsZoom ? [] : icons(of: crossing, at: zoom), nil) }
guard !crossingBands.isEmpty, seenKinds.insert("level_crossing").inserted else {
    fail("amenity-points.mss draws no level crossing")
}
entries.append(Entry(kind: "level_crossing", feature: "railway_level_crossing", lowPriority: false, bands: crossingBands))
// Where two keys share a value, the first here wins. The low-priority
// layer's go first, because the vector extras bring barriers, and a `gate`
// on a path is far likelier than an airport's; then Carto's own order of keys.
for feature in lowFeatures {
    let name = "\(feature.key)_\(feature.value)"
    add(kind: feature.value, feature: name, shop: nil, lowPriority: true, requires: feature.requires)
}
for feature in mainFeatures {
    let name = "\(feature.key)_\(feature.value)"
    add(kind: feature.value, feature: name, shop: nil, lowPriority: false, requires: feature.requires)
}
// The vector extras file every office as `office`, as Carto draws them all
// alike, ahead of the `shop=office` Carto also knows; a pass marked on a road
// as `mountain_pass`, the name Carto's query gives one; and a ford on a path
// as `ford`.
add(kind: "office", feature: "office", shop: nil, lowPriority: false)
add(kind: "mountain_pass", feature: "mountain_pass", shop: nil, lowPriority: false)
add(kind: "ford", feature: "highway_ford", shop: nil, lowPriority: false)
for shop in drawnShops {
    add(kind: shop, feature: "shop", shop: shop, lowPriority: false)
}

// MARK: - Patterns

/// One of Carto's pattern pictures: a square of symbols it fills an area
/// with, or lays along a line, over and over.
struct Pattern {
    /// Its name in the catalog: `carto-pattern-` and the file's own name.
    let asset: String
    /// `svg` or `png`.
    let kind: String
    /// The files, by the scale each is drawn for: Carto keeps a picture
    /// twice the size beside some of its bitmaps.
    let sources: [(scale: Int, path: String)]
}

/// The patterns the map draws nothing with: a flowerbed's, a prison's and a
/// salt marsh's dots, whose areas the tiles have no kind for, and a cliff's
/// and an embankment's teeth, which it draws along the line itself.
let undrawnPatterns: Set<String> = [
    "flowerbed_mid_zoom", "flowerbed_high_zoom", "grey_vertical_hatch", "salt-dots-2",
    "cliff", "cliff2", "embankment",
]

/// Every picture `landcover.mss` and `water.mss` fill an area with or lay
/// along a line, less the ``undrawnPatterns``.
let patterns: [Pattern] = {
    var found: [String: Pattern] = [:]
    for sheet in ["landcover.mss", "water.mss"] {
        let text = uncommented(read("style/\(sheet)"))
        for part in text.components(separatedBy: "-pattern-file:").dropFirst() {
            guard let open = part.range(of: "url('"), let close = part.range(of: "')") else {
                fail("\(sheet) names a pattern this does not read: \(part.prefix(60))")
            }
            let path = String(part[open.upperBound..<close.lowerBound])
            let file = path.split(separator: "/").last.map(String.init) ?? path
            guard let dot = file.lastIndex(of: ".") else { fail("\(sheet) names a pattern with no type: \(path)") }
            let name = String(file[..<dot])
            let kind = String(file[file.index(after: dot)...])
            guard !undrawnPatterns.contains(name), found[name] == nil else { continue }
            guard FileManager.default.fileExists(atPath: cartoRoot.appending(path: path).path) else {
                fail("\(sheet) names \(path), which the release does not have")
            }
            var sources = [(scale: 1, path: path)]
            // Carto generates its bitmaps from drawings it keeps beside them,
            // some at twice the size too; the plain wetland's is named apart.
            let doubled = "symbols/generating_patterns/\(name == "wetland" ? "wetland_generic" : name)@2x.png"
            if kind == "png", FileManager.default.fileExists(atPath: cartoRoot.appending(path: doubled).path) {
                sources.append((scale: 2, path: doubled))
            }
            found[name] = Pattern(asset: "carto-pattern-\(name)", kind: kind, sources: sources)
        }
    }
    guard !found.isEmpty else { fail("landcover.mss names no pattern") }
    return found.values.sorted { $0.asset < $1.asset }
}()

// MARK: - Writing

// The release, which `Scripts/carto-points.sh` names: a tarball has no tag.
let version = ProcessInfo.processInfo.environment["CARTO_VERSION"] ?? "unknown"
let table = Table(
    source: "openstreetmap-carto \(version)",
    restrictedAccess: restrictedAccess,
    areaLimit: areaLimit,
    entries: entries
)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
do {
    try encoder.encode(table).write(to: tableURL)
} catch {
    fail("cannot write \(tableURL.path): \(error)")
}

let fileManager = FileManager.default
try? fileManager.removeItem(at: catalogURL)
do {
    try fileManager.createDirectory(at: catalogURL, withIntermediateDirectories: true)
    let info = #"{"info":{"author":"xcode","version":1}}"#
    try Data((info + "\n").utf8).write(to: catalogURL.appending(path: "Contents.json"))
    for (name, icon) in usedIcons.sorted(by: { $0.key < $1.key }) {
        let set = catalogURL.appending(path: "\(name).imageset")
        try fileManager.createDirectory(at: set, withIntermediateDirectories: true)
        let file = "\(name).svg"
        try fileManager.copyItem(at: cartoRoot.appending(path: icon.source), to: set.appending(path: file))
        let contents = """
        {"images":[{"filename":"\(file)","idiom":"universal"}],"info":{"author":"xcode","version":1},\
        "properties":{"preserves-vector-representation":true,"template-rendering-intent":"template"}}

        """
        try Data(contents.utf8).write(to: set.appending(path: "Contents.json"))
    }
    for pattern in patterns {
        let set = catalogURL.appending(path: "\(pattern.asset).imageset")
        try fileManager.createDirectory(at: set, withIntermediateDirectories: true)
        var images: [String] = []
        for (scale, source) in pattern.sources {
            let file = "\(pattern.asset)\(scale == 1 ? "" : "@\(scale)x").\(pattern.kind)"
            try fileManager.copyItem(at: cartoRoot.appending(path: source), to: set.appending(path: file))
            // A bitmap is for one scale; a drawing is for them all.
            let drawnFor = pattern.kind == "svg" ? "" : #","scale":"\#(scale)x""#
            images.append(#"{"filename":"\#(file)","idiom":"universal"\#(drawnFor)}"#)
        }
        let vector = pattern.kind == "svg" ? #","properties":{"preserves-vector-representation":true}"# : ""
        let contents = #"{"images":[\#(images.joined(separator: ","))],"info":{"author":"xcode","version":1}\#(vector)}"#
        try Data((contents + "\n").utf8).write(to: set.appending(path: "Contents.json"))
    }
} catch {
    fail("cannot write \(catalogURL.path): \(error)")
}

let areaKinds = Set(entries.filter { $0.areas != nil }.map(\.kind)).sorted()
print(
    "carto-points: \(entries.count) kinds of point, \(usedIcons.count) icons, \(patterns.count) patterns, "
        + "from \(table.source)"
)
print("carto-points: drawn by their size: \(areaKinds.joined(separator: " "))")
