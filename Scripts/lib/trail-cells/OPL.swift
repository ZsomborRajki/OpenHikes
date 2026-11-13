//
//  OPL.swift
//  trail-cells
//
//  Reading osmium's OPL text: one OpenStreetMap object a line.
//
//  `Scripts/trail-cells.sh` has osmium do the part that is hard — finding the
//  hiking relations in a planet file and putting every node's position on the
//  ways that use it — and write the result as OPL, which is the one format of
//  OpenStreetMap data that is read with a loop over bytes. A relation is
//
//      r49583 Tname=P%20%(Írott-kő),route=hiking Mw353807034@,w99376544@forward
//
//  and a way, once `osmium add-locations-to-ways` has run, is
//
//      w3427032 Thighway=path Nn15722546x18.1503587y46.1449026,n15722543x18.15y46.14
//
//  Fields are separated by one space and named by their first letter, so the
//  ones osmium adds when metadata is left on are skipped rather than counted.
//  Inside a field, a space, a comma, `=`, `@`, `%` and anything unprintable is
//  written `%` hex code point `%`.
//

import Foundation

/// One relation line.
struct OPLRelation {
    struct Member {
        /// `n`, `w` or `r`.
        var kind: UInt8
        var ref: Int64
        var role: String
    }

    var id: Int64
    var tags: [String: String]
    var members: [Member]
}

/// One way line: its id, and its points when every node had a position.
struct OPLWay {
    var id: Int64
    /// `nil` for a way with a node whose position the extract did not hold —
    /// a way that crosses out of a regional extract, which no line can be
    /// drawn from honestly.
    var points: [TrailCellFile.Point]?
}

enum OPLError: Error, CustomStringConvertible {
    case malformed(line: String)

    var description: String {
        switch self {
        case .malformed(let line):
            "this is not an OPL line the tool reads: \(line.prefix(120))"
        }
    }
}

/// A file of OPL, mapped into memory rather than read into it: the ways of a
/// whole planet's hiking routes are gigabytes, and each line is looked at
/// once.
struct OPLFile {
    private let data: Data

    init(path: String) throws {
        data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
    }

    /// Calls `body` with each line that is not empty, without its newline.
    func forEachLine(_ body: (UnsafeBufferPointer<UInt8>) throws -> Void) throws {
        try data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard let base = bytes.baseAddress else { return }
            var start = 0
            while start < bytes.count {
                let found = memchr(base + start, Int32(ASCII.newline), bytes.count - start)
                let end = found.map { base.distance(to: $0.assumingMemoryBound(to: UInt8.self)) } ?? bytes.count
                if end > start {
                    try body(UnsafeBufferPointer(rebasing: bytes[start..<end]))
                }
                start = end + 1
            }
        }
    }
}

enum ASCII {
    static let newline = UInt8(ascii: "\n")
    static let space = UInt8(ascii: " ")
    static let comma = UInt8(ascii: ",")
    static let equals = UInt8(ascii: "=")
    static let at = UInt8(ascii: "@")
    static let percent = UInt8(ascii: "%")
    static let minus = UInt8(ascii: "-")
    static let period = UInt8(ascii: ".")
    static let zero = UInt8(ascii: "0")
    static let nine = UInt8(ascii: "9")
}

enum OPL {
    /// The coordinate units OpenStreetMap itself keeps: ten-millionths of a
    /// degree. What a position is parsed into before it is rounded to a
    /// square's own scale.
    static let sourceScale: Int64 = 10_000_000

    /// A relation line, or `nil` for a line that is some other object.
    static func relation(_ line: UnsafeBufferPointer<UInt8>) throws -> OPLRelation? {
        guard line.first == UInt8(ascii: "r") else { return nil }
        var fields = line.split(separator: ASCII.space, omittingEmptySubsequences: true).makeIterator()
        guard let head = fields.next(), let id = integer(head.dropFirst()) else {
            throw OPLError.malformed(line: text(line))
        }
        var relation = OPLRelation(id: id, tags: [:], members: [])
        while let field = fields.next() {
            switch field.first {
            case UInt8(ascii: "T"):
                relation.tags = tags(field.dropFirst())
            case UInt8(ascii: "M"):
                relation.members = try members(field.dropFirst(), line: line)
            default:
                continue
            }
        }
        return relation
    }

    /// A way line, or `nil` for a line that is some other object.
    ///
    /// - Parameter scale: The coordinate units in a degree the points are
    ///   rounded to.
    static func way(_ line: UnsafeBufferPointer<UInt8>, scale: Int32) throws -> OPLWay? {
        guard line.first == UInt8(ascii: "w") else { return nil }
        var fields = line.split(separator: ASCII.space, omittingEmptySubsequences: true).makeIterator()
        guard let head = fields.next(), let id = integer(head.dropFirst()) else {
            throw OPLError.malformed(line: text(line))
        }
        var way = OPLWay(id: id, points: [])
        while let field = fields.next() {
            guard field.first == UInt8(ascii: "N") else { continue }
            way.points = try points(field.dropFirst(), scale: Int64(scale), line: line)
        }
        return way
    }

    /// The id a way line carries, without reading the rest of it — which is
    /// most of the file, and most ways are not ones a kept relation names.
    static func wayID(_ line: UnsafeBufferPointer<UInt8>) -> Int64? {
        guard line.first == UInt8(ascii: "w") else { return nil }
        let end = line.firstIndex(of: ASCII.space) ?? line.endIndex
        return integer(line[1..<end])
    }
}

// MARK: - Fields

private extension OPL {
    typealias Bytes = Slice<UnsafeBufferPointer<UInt8>>

    static func tags(_ field: Bytes) -> [String: String] {
        var tags: [String: String] = [:]
        for pair in field.split(separator: ASCII.comma) {
            guard let separator = pair.firstIndex(of: ASCII.equals) else { continue }
            tags[unescaped(pair[..<separator])] = unescaped(pair[pair.index(after: separator)...])
        }
        return tags
    }

    static func members(_ field: Bytes, line: UnsafeBufferPointer<UInt8>) throws -> [OPLRelation.Member] {
        try field.split(separator: ASCII.comma).map { member in
            guard let kind = member.first,
                  let separator = member.firstIndex(of: ASCII.at),
                  let ref = integer(member[member.index(after: member.startIndex)..<separator])
            else { throw OPLError.malformed(line: text(line)) }
            return OPLRelation.Member(
                kind: kind,
                ref: ref,
                role: unescaped(member[member.index(after: separator)...])
            )
        }
    }

    /// A way's points, or `nil` when one of its nodes has no position.
    static func points(
        _ field: Bytes,
        scale: Int64,
        line: UnsafeBufferPointer<UInt8>
    ) throws -> [TrailCellFile.Point]? {
        var points: [TrailCellFile.Point] = []
        for node in field.split(separator: ASCII.comma) {
            guard let xMark = node.firstIndex(of: UInt8(ascii: "x")),
                  let yMark = node[xMark...].firstIndex(of: UInt8(ascii: "y"))
            else { return nil }
            let longitudeText = node[node.index(after: xMark)..<yMark]
            let latitudeText = node[node.index(after: yMark)...]
            // A node the extract held no position for is written with the
            // marks and nothing after them.
            if longitudeText.isEmpty || latitudeText.isEmpty { return nil }
            guard let longitude = coordinate(longitudeText, scale: scale),
                  let latitude = coordinate(latitudeText, scale: scale)
            else { throw OPLError.malformed(line: text(line)) }
            points.append(TrailCellFile.Point(latitude: latitude, longitude: longitude))
        }
        return points
    }
}

// MARK: - Numbers and text

private extension OPL {
    static func integer(_ bytes: Bytes) -> Int64? {
        guard !bytes.isEmpty else { return nil }
        var value: Int64 = 0
        for byte in bytes {
            guard byte >= ASCII.zero, byte <= ASCII.nine else { return nil }
            let (scaled, overflowed) = value.multipliedReportingOverflow(by: 10)
            guard !overflowed else { return nil }
            value = scaled + Int64(byte - ASCII.zero)
        }
        return value
    }

    /// A decimal number of degrees as whole coordinate units, rounded half
    /// away from zero.
    ///
    /// Read digit by digit rather than through `Double`, so the number a
    /// square stores is the one OpenStreetMap printed, rounded once — two
    /// ways that share a node get the same units for it whatever a
    /// floating-point parse would have made of each.
    static func coordinate(_ bytes: Bytes, scale: Int64) -> Int32? {
        var digits = bytes
        let isNegative = digits.first == ASCII.minus
        if isNegative { digits = digits.dropFirst() }
        let point = digits.firstIndex(of: ASCII.period) ?? digits.endIndex
        guard let whole = integer(digits[..<point]) else { return nil }
        var fraction: Int64 = 0
        var places: Int64 = 1
        if point < digits.endIndex {
            for byte in digits[digits.index(after: point)...] {
                guard byte >= ASCII.zero, byte <= ASCII.nine else { return nil }
                // Past OpenStreetMap's own seven places there is nothing to
                // read; a longer number is cut rather than refused.
                guard places < sourceScale else { break }
                fraction = fraction * 10 + Int64(byte - ASCII.zero)
                places *= 10
            }
        }
        let source = whole * sourceScale + fraction * (sourceScale / places)
        let divisor = sourceScale / scale
        let rounded = divisor > 1 ? (source + divisor / 2) / divisor : source * (scale / sourceScale)
        return Int32(exactly: isNegative ? -rounded : rounded)
    }

    /// `bytes` with every `%` hex `%` escape replaced by the character it
    /// names.
    static func unescaped(_ bytes: Bytes) -> String {
        guard bytes.contains(ASCII.percent) else {
            return String(decoding: bytes, as: UTF8.self)
        }
        var text: [UInt8] = []
        text.reserveCapacity(bytes.count)
        var index = bytes.startIndex
        while index < bytes.endIndex {
            guard bytes[index] == ASCII.percent,
                  let close = bytes[bytes.index(after: index)...].firstIndex(of: ASCII.percent),
                  let code = UInt32(String(decoding: bytes[bytes.index(after: index)..<close], as: UTF8.self), radix: 16),
                  let scalar = Unicode.Scalar(code)
            else {
                text.append(bytes[index])
                index = bytes.index(after: index)
                continue
            }
            text.append(contentsOf: Array(String(scalar).utf8))
            index = bytes.index(after: close)
        }
        return String(decoding: text, as: UTF8.self)
    }

    static func text(_ line: UnsafeBufferPointer<UInt8>) -> String {
        String(decoding: line, as: UTF8.self)
    }
}
