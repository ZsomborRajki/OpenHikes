//
//  PackedBytes.swift
//  OpenHikes
//
//  The byte format the pre-built squares share: an envelope that says which
//  file it is and how its body is packed, and a body of unsigned LEB128
//  integers, zigzag steps and numbered strings.
//
//  Two files are written in it — ``TrailCellFile``, OpenStreetMap's day hikes
//  by square, and ``RouteSquareFile``, the hiking-routes layer by square — and
//  both are compiled into the tool that writes them as well as into the app
//  that reads them. So this file imports Foundation and Compression and
//  nothing of the app's, and says `nonisolated` on every declaration.
//
//  Everything a reader takes is checked on the way in — a count against the
//  bytes that are left, an index against the strings — because what arrives
//  here came over a network and is drawn on a map.
//

import Compression
import Foundation

/// Why some bytes are not a file of the format asked for.
nonisolated enum PackedFileError: Error, Equatable {
    /// The body says something no writer of this format would.
    case corrupt
    /// The bytes stop before the file does.
    case truncated
    case unsupportedCompression(UInt8)
    case unsupportedVersion(UInt8)
    /// The first four bytes are not this format's.
    case wrongFormat
}

// MARK: - The envelope

/// Four letters, a version, how the body is packed and how long it is
/// unpacked — then the body.
nonisolated enum PackedEnvelope {
    /// How the body is packed.
    enum Method: UInt8 {
        /// Raw DEFLATE, RFC 1951 — what the system's `COMPRESSION_ZLIB` reads
        /// and writes, and what any zlib does with no header asked for.
        case deflate = 1
        /// As it is. What a body too small to shrink is written as.
        case stored = 0
    }

    /// The largest body a reader will unpack: far past any square, and small
    /// enough that a file lying about its length cannot ask for the phone's
    /// memory.
    static let maximumBodyBytes = 64 * 1024 * 1024

    /// The file: the envelope and `body`, packed when that makes it smaller.
    static func file(magic: [UInt8], version: UInt8, body: Data) -> Data {
        let packed = PackedDeflate.compressed(body)
        var file = Data(magic)
        file.append(version)
        file.append((packed == nil ? Method.stored : .deflate).rawValue)
        file.append(contentsOf: PackedVarint.bytes(of: UInt64(body.count)))
        file.append(packed ?? body)
        return file
    }

    /// The body of a file ``file(magic:version:body:)`` wrote with the same
    /// four letters and version, unpacked.
    static func body(of file: Data, magic: [UInt8], version expected: UInt8) throws -> [UInt8] {
        var envelope = PackedReader(bytes: Array(file))
        guard try envelope.readBytes(magic.count) == magic else { throw PackedFileError.wrongFormat }
        let version = try envelope.readByte()
        guard version == expected else { throw PackedFileError.unsupportedVersion(version) }
        let methodByte = try envelope.readByte()
        guard let method = Method(rawValue: methodByte) else {
            throw PackedFileError.unsupportedCompression(methodByte)
        }
        let length = try envelope.readCount(atMost: maximumBodyBytes)
        let packed = envelope.remainder
        switch method {
        case .deflate:
            return try PackedDeflate.decompressed(packed, count: length)

        case .stored:
            guard packed.count == length else { throw PackedFileError.truncated }
            return packed
        }
    }
}

// MARK: - Integers and strings

nonisolated enum PackedVarint {
    static let payloadBits = 7
    static let payloadMask: UInt64 = 0x7F
    static let continuation: UInt8 = 0x80
    /// A 64-bit value is ten groups of seven bits at most.
    static let maximumBytes = 10

    static func bytes(of value: UInt64) -> [UInt8] {
        var remaining = value
        var bytes: [UInt8] = []
        while remaining > payloadMask {
            bytes.append(UInt8(remaining & payloadMask) | continuation)
            remaining >>= UInt64(payloadBits)
        }
        bytes.append(UInt8(remaining))
        return bytes
    }
}

nonisolated struct PackedWriter {
    var bytes: [UInt8] = []

    mutating func write(_ value: UInt64) {
        bytes.append(contentsOf: PackedVarint.bytes(of: value))
    }

    /// A signed step, zigzag-encoded: 0, −1, 1, −2 … become 0, 1, 2, 3 …
    mutating func write(step: Int64) {
        write(UInt64(bitPattern: (step << 1) ^ (step >> (Int64.bitWidth - 1))))
    }

    /// Every string of `table`, counted, each as its length and its UTF-8.
    mutating func write(strings table: PackedStringTable) {
        write(UInt64(table.all.count))
        for string in table.all {
            let text = Array(string.utf8)
            write(UInt64(text.count))
            bytes.append(contentsOf: text)
        }
    }
}

/// Numbers each distinct string in the order it is first met.
nonisolated struct PackedStringTable {
    private(set) var all: [String] = []
    private var indices: [String: UInt64] = [:]

    mutating func index(of string: String) -> UInt64 {
        if let known = indices[string] { return known }
        let index = UInt64(all.count)
        all.append(string)
        indices[string] = index
        return index
    }
}

nonisolated struct PackedReader {
    let bytes: [UInt8]
    private(set) var offset = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    var isAtEnd: Bool { offset == bytes.count }
    var remainder: [UInt8] { Array(bytes[offset...]) }

    mutating func readByte() throws -> UInt8 {
        guard offset < bytes.count else { throw PackedFileError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count <= bytes.count - offset else { throw PackedFileError.truncated }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }

    mutating func readVarint() throws -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<PackedVarint.maximumBytes {
            let byte = try readByte()
            value |= (UInt64(byte) & PackedVarint.payloadMask) << UInt64(index * PackedVarint.payloadBits)
            if byte & PackedVarint.continuation == 0 { return value }
        }
        throw PackedFileError.corrupt
    }

    mutating func readStep() throws -> Int64 {
        let zigzag = try readVarint()
        return Int64(bitPattern: zigzag >> 1) ^ -Int64(bitPattern: zigzag & 1)
    }

    /// A count of things that follow, each of which is at least one byte —
    /// so a count past what is left is a lie, told before anything is
    /// allocated for it.
    mutating func readCount(atMost limit: Int? = nil) throws -> Int {
        let count = try readVarint()
        guard count <= UInt64(limit ?? bytes.count - offset) else { throw PackedFileError.corrupt }
        return Int(count)
    }

    mutating func readString() throws -> String {
        let text = try readBytes(readCount())
        guard let string = String(bytes: text, encoding: .utf8) else { throw PackedFileError.corrupt }
        return string
    }

    /// The strings ``PackedWriter/write(strings:)`` wrote.
    mutating func readStrings() throws -> [String] {
        try (0..<readCount()).map { _ in try readString() }
    }

    mutating func readIndexedString(_ strings: [String]) throws -> String {
        let index = try readVarint()
        guard index < UInt64(strings.count) else { throw PackedFileError.corrupt }
        return strings[Int(index)]
    }
}

// MARK: - Packing

/// Raw DEFLATE through the system's Compression framework.
nonisolated enum PackedDeflate {
    /// `body` packed, or `nil` when packing does not make it smaller — the
    /// encoder answers nothing for a result that does not fit a buffer one
    /// byte shorter than what it was given.
    static func compressed(_ body: Data) -> Data? {
        guard body.count > 1 else { return nil }
        var packed = [UInt8](repeating: 0, count: body.count - 1)
        let written = body.withUnsafeBytes { source -> Int in
            guard let input = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return packed.withUnsafeMutableBufferPointer { buffer in
                guard let output = buffer.baseAddress else { return 0 }
                return compression_encode_buffer(output, buffer.count, input, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        return written > 0 ? Data(packed.prefix(written)) : nil
    }

    /// `packed` unpacked to exactly `count` bytes, which is what the envelope
    /// said it would be. Anything else is not a body this format wrote.
    static func decompressed(_ packed: [UInt8], count: Int) throws -> [UInt8] {
        guard count > 0, !packed.isEmpty else { throw PackedFileError.corrupt }
        var body = [UInt8](repeating: 0, count: count)
        let written = packed.withUnsafeBufferPointer { source -> Int in
            guard let input = source.baseAddress else { return 0 }
            return body.withUnsafeMutableBufferPointer { buffer in
                guard let output = buffer.baseAddress else { return 0 }
                return compression_decode_buffer(output, buffer.count, input, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == count else { throw PackedFileError.corrupt }
        return body
    }
}
