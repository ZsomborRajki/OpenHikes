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
//  a way, once `osmium add-locations-to-ways` has run, is
//
//      w3427032 Thighway=path Nn15722546x18.1503587y46.1449026,n15722543x18.15y46.14
//
//  and a node, which the places' build reads, is
//
//      n26863613 Tele=2713,name=Hoher%20%Göll,natural=peak x13.0670457 y47.5937383
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
    /// Read only when asked for: the routes' builds have no use for them, and
    /// they read millions of ways.
    var tags: [String: String] = [:]
    /// The way's node ids, in order, read only when asked for: the trail
    /// graph joins its ways at them.
    var nodeIDs: [Int64] = []
}

/// One node line: its id, its tags and its position.
struct OPLNode {
    var id: Int64
    var tags: [String: String]
    /// `nil` for a node written without a position.
    var point: TrailCellFile.Point?
}

enum OPLError: Error, CustomStringConvertible {
    case malformed(line: String)
    case lineTooLong(bytes: Int)
    case unreadable(errno: Int32)

    var description: String {
        switch self {
        case .malformed(let line):
            "this is not an OPL line the tool reads: \(line.prefix(120))"
        case .lineTooLong(let bytes):
            "a line of the input runs past \(bytes) bytes without ending"
        case .unreadable(let code):
            "the input could not be read: \(String(cString: strerror(code)))"
        }
    }
}

/// A file of OPL, mapped into memory rather than read into it: the ways of a
/// whole planet's hiking routes are gigabytes, and each line is looked at
/// once. Or, for the path `-`, standard input, read as it comes: the trail
/// maker's ways, roads and all, are a hundred gigabytes of text, which
/// osmium writes into a pipe rather than onto the disk.
struct OPLFile {
    private enum Source {
        case mapped(Data)
        case standardInput
    }

    /// The longest line standard input may hold. A way is two thousand nodes
    /// at most, each some forty bytes of OPL.
    static let streamBufferBytes = 64 << 20

    private let source: Source

    init(path: String) throws {
        source = path == "-"
            ? .standardInput
            : .mapped(try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped))
    }

    /// Calls `body` with each line that is not empty, without its newline.
    func forEachLine(_ body: (UnsafeBufferPointer<UInt8>) throws -> Void) throws {
        switch source {
        case .mapped(let data):
            try data.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                guard let base = bytes.baseAddress else { return }
                try Self.forEachLine(in: base, count: bytes.count, body)
            }
        case .standardInput:
            try Self.forEachLine(of: FileHandle.standardInput.fileDescriptor, body)
        }
    }

    /// The lines of `count` bytes at `base`, and the offset after the last
    /// newline: what is past it is a line still being written.
    @discardableResult
    private static func forEachLine(
        in base: UnsafePointer<UInt8>,
        count: Int,
        endingInNewline: Bool = false,
        _ body: (UnsafeBufferPointer<UInt8>) throws -> Void
    ) throws -> Int {
        var start = 0
        while start < count {
            let found = memchr(base + start, Int32(ASCII.newline), count - start)
            guard let found else {
                if !endingInNewline {
                    try body(UnsafeBufferPointer(start: base + start, count: count - start))
                    return count
                }
                return start
            }
            let end = base.distance(to: found.assumingMemoryBound(to: UInt8.self))
            if end > start {
                try body(UnsafeBufferPointer(start: base + start, count: end - start))
            }
            start = end + 1
        }
        return start
    }

    /// Every line of what `descriptor` reads until its end, through one
    /// buffer: a line cut at the buffer's end is moved to its start and
    /// read on.
    private static func forEachLine(
        of descriptor: Int32,
        _ body: (UnsafeBufferPointer<UInt8>) throws -> Void
    ) throws {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: streamBufferBytes)
        defer { buffer.deallocate() }
        var filled = 0
        while true {
            guard filled < streamBufferBytes else { throw OPLError.lineTooLong(bytes: streamBufferBytes) }
            let count = read(descriptor, buffer + filled, streamBufferBytes - filled)
            if count < 0 {
                guard errno == EINTR else { throw OPLError.unreadable(errno: errno) }
                continue
            }
            guard count > 0 else {
                try forEachLine(in: buffer, count: filled, body)
                return
            }
            filled += count
            let consumed = try forEachLine(in: buffer, count: filled, endingInNewline: true, body)
            if consumed > 0 {
                memmove(buffer, buffer + consumed, filled - consumed)
                filled -= consumed
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
    /// - Parameters:
    ///   - scale: The coordinate units in a degree the points are rounded to.
    ///   - readsTags: Whether the way's tags are read as well as its points.
    ///   - readsNodeIDs: Whether its nodes' ids are read as well.
    static func way(
        _ line: UnsafeBufferPointer<UInt8>,
        scale: Int32,
        readsTags: Bool = false,
        readsNodeIDs: Bool = false
    ) throws -> OPLWay? {
        guard line.first == UInt8(ascii: "w") else { return nil }
        var fields = line.split(separator: ASCII.space, omittingEmptySubsequences: true).makeIterator()
        guard let head = fields.next(), let id = integer(head.dropFirst()) else {
            throw OPLError.malformed(line: text(line))
        }
        var way = OPLWay(id: id, points: [])
        while let field = fields.next() {
            switch field.first {
            case UInt8(ascii: "N"):
                way.points = try points(field.dropFirst(), scale: Int64(scale), line: line)
                if readsNodeIDs {
                    way.nodeIDs = try nodeIDs(field.dropFirst(), line: line)
                }
            case UInt8(ascii: "T") where readsTags:
                way.tags = tags(field.dropFirst())
            default:
                continue
            }
        }
        return way
    }

    /// A node line, or `nil` for a line that is some other object.
    ///
    /// - Parameter scale: The coordinate units in a degree the position is
    ///   rounded to.
    static func node(_ line: UnsafeBufferPointer<UInt8>, scale: Int32) throws -> OPLNode? {
        guard line.first == UInt8(ascii: "n") else { return nil }
        var fields = line.split(separator: ASCII.space, omittingEmptySubsequences: true).makeIterator()
        guard let head = fields.next(), let id = integer(head.dropFirst()) else {
            throw OPLError.malformed(line: text(line))
        }
        var node = OPLNode(id: id, tags: [:], point: nil)
        var longitude: Int32?
        var latitude: Int32?
        while let field = fields.next() {
            switch field.first {
            case UInt8(ascii: "T"):
                node.tags = tags(field.dropFirst())
            case UInt8(ascii: "x"):
                longitude = try position(field.dropFirst(), scale: Int64(scale), line: line)
            case UInt8(ascii: "y"):
                latitude = try position(field.dropFirst(), scale: Int64(scale), line: line)
            default:
                continue
            }
        }
        if let latitude, let longitude {
            node.point = TrailCellFile.Point(latitude: latitude, longitude: longitude)
        }
        return node
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

    /// One of a node's two coordinates, or `nil` for a node written without
    /// a position, which is the mark with nothing after it.
    static func position(_ field: Bytes, scale: Int64, line: UnsafeBufferPointer<UInt8>) throws -> Int32? {
        guard !field.isEmpty else { return nil }
        guard let value = coordinate(field, scale: scale) else { throw OPLError.malformed(line: text(line)) }
        return value
    }

    /// A way's node ids: the number after each `n`, up to its position.
    static func nodeIDs(_ field: Bytes, line: UnsafeBufferPointer<UInt8>) throws -> [Int64] {
        try field.split(separator: ASCII.comma).map { node in
            let end = node.firstIndex(of: UInt8(ascii: "x")) ?? node.endIndex
            guard node.first == UInt8(ascii: "n"), let id = integer(node[node.index(after: node.startIndex)..<end]) else {
                throw OPLError.malformed(line: text(line))
            }
            return id
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
