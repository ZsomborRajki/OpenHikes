#!/usr/bin/env swift
//
//  carto-points.swift
//  Scripts/lib
//
//  Reads OpenStreetMap Carto's points — the icons and names its
//  `amenity-points.mss` draws, the style tile.openstreetmap.org is drawn in —
//  and writes them out as the table the vector map draws points from, with
//  every icon the table names copied into an asset catalog.
//
//  Carto is written in CartoCSS: nested blocks whose filters and zooms add
//  up, where the more specific of two declarations wins and the later one
//  breaks a tie. Carto's own compiler flattens that into Mapnik's rules; this
//  evaluates the same cascade for each kind of point the archive can name, at
//  each zoom, and keeps what a point read from the archive can meet: a point
//  rather than an area (`way_pixels` 0), open to everyone, not a building,
//  and with only the details the archive keeps — a place of worship's
//  religion and a pitch's sport, in `kind_detail`, and whether it has a name.
//
//  Only the CartoCSS these rules are written in is read: variables, nested
//  blocks, filters on attributes and on zoom, and the color functions darken,
//  lighten, saturate, desaturate, fade, fadeout and mix. Anything else stops
//  the script rather than being read as something it is not.
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
guard styleFiles.contains("amenity-points.mss") else { fail("no style/amenity-points.mss in \(cartoRoot.path)") }
for file in styleFiles {
    var reader = StatementReader(read("style/\(file)"))
    let statements = reader.statements()
    // Every file's variables are read, because the points' colors are named
    // after the land's; only the points' own rules are evaluated.
    let parents = [Selector()]
    if file == "amenity-points.mss" {
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

struct Entry: Codable {
    var kind: String
    var detail: String?
    var named: Bool?
    var feature: String
    var lowPriority: Bool
    var elevation: Bool?
    var bands: [Band]
}

struct Table: Codable {
    var source: String
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
    "amenity_shelter",
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

func bands(of point: Point, textLayer: String, iconLayerZoom: Int, textLayerZoom: Int) -> [Band] {
    var bands: [Band] = []
    for zoom in zooms {
        let icons = zoom < iconLayerZoom ? [] : symbolizers(for: point, at: zoom)
            .filter { $0.properties.keys.contains { $0.hasPrefix("marker-") } }
            .map { icon($0.properties) }
        let textPoint = Point(layer: textLayer, attributes: point.attributes)
        let label = zoom < textLayerZoom
            ? nil
            : symbolizers(for: textPoint, at: zoom).lazy.compactMap { text($0.properties) }.first
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
        "int_access": .text("yes"),
        "is_building": .text("no"),
        // A point has no area: the main layer counts that as nothing, the
        // low-priority one as missing.
        "way_pixels": lowPriority ? .null : .number(0),
    ]
    if let shop { base["shop"] = .text(iconShops.contains(shop) ? shop : "other") }
    let tested: [(key: String, value: String?)] = ["religion", "sport"]
        .filter { rules(of: feature, shop: shop, test: $0) }
        .flatMap { key in testedValues(key).map { (key, Optional($0)) } }
    let required = requires.map { requires in requires.values.map { (key: requires.key, value: Optional($0)) } }
    let namings: [Bool?] = rules(of: feature, shop: shop, test: "name") ? [true, false] : [nil]
    var produced: [[Band]] = []
    // A feature that asks for a further tag is drawn only with it.
    let plain: (key: String, value: String?) = ("", nil)
    for detail in required ?? [plain] + tested {
        for named in namings {
            var attributes = base
            attributes["name"] = named == false ? .null : .text("name")
            if let value = detail.value { attributes[detail.key] = .text(value) }
            let point = Point(layer: iconLayer, attributes: attributes)
            let result = bands(
                of: point,
                textLayer: textLayer,
                iconLayerZoom: minimumZoom(of: iconLayer),
                textLayerZoom: minimumZoom(of: textLayer)
            )
            guard !result.isEmpty else { continue }
            // A detail that changes nothing is the plain kind's.
            if required == nil, detail.value != nil, produced.contains(result) { continue }
            produced.append(result)
            entries.append(Entry(
                kind: kind,
                detail: detail.value,
                named: named,
                feature: feature,
                lowPriority: lowPriority,
                elevation: writesElevation(feature: feature, detail: detail.value) ? true : nil,
                bands: result
            ))
        }
    }
}

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
// alike, ahead of the `shop=office` Carto also knows.
add(kind: "office", feature: "office", shop: nil, lowPriority: false)
for shop in drawnShops {
    add(kind: shop, feature: "shop", shop: shop, lowPriority: false)
}

// MARK: - Writing

// The release, which `Scripts/carto-points.sh` names: a tarball has no tag.
let version = ProcessInfo.processInfo.environment["CARTO_VERSION"] ?? "unknown"
let table = Table(source: "openstreetmap-carto \(version)", entries: entries)
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
} catch {
    fail("cannot write \(catalogURL.path): \(error)")
}

print("carto-points: \(entries.count) kinds of point, \(usedIcons.count) icons, from \(table.source)")
