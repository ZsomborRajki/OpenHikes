//
//  MapboxVectorTile.swift
//  OpenHikes
//
//  A reader for Mapbox Vector Tiles, version 2.1 of the spec
//  (github.com/mapbox/vector-tile-spec), the format the tile server serves:
//  a tile is layers, a layer is features, and a feature is a point, a line or
//  a polygon in the tile's own grid, with properties.
//
//  Written out rather than generated from the spec's .proto, because it reads
//  four messages and the app links no protobuf runtime. Only what the
//  rasterizer asks for is kept: the layers it draws and, of their
//  properties, the keys it reads. A street-level tile carries a thousand
//  points of interest with a dozen tags each that nothing here draws.
//

import Foundation

nonisolated struct MapboxVectorTile: Sendable {
    enum GeometryType: UInt64, Sendable {
        case unknown = 0
        case point = 1
        case line = 2
        case polygon = 3
    }

    enum Value: Equatable, Sendable {
        case string(String)
        case number(Double)
        case bool(Bool)
    }

    struct Feature: Sendable {
        let type: GeometryType
        let properties: [String: Value]
        /// The geometry's command integers as encoded; ``VectorTileGeometry``
        /// reads them.
        let geometry: [UInt32]
        /// Whether the vector extras gave it, rather than the basemap: the
        /// two name their layers and kinds alike, and where both have a
        /// point for one thing the extras' is the one filed as Carto files
        /// it (``VectorTilePoints``).
        var isFromExtras = false

        func string(_ key: String) -> String? {
            guard case let .string(value) = properties[key] else { return nil }
            return value
        }

        func number(_ key: String) -> Double? {
            guard case let .number(value) = properties[key] else { return nil }
            return value
        }

        /// A boolean property, which some encoders write as a number.
        func flag(_ key: String) -> Bool {
            switch properties[key] {
            case let .bool(value): value
            case let .number(value): value != 0
            default: false
            }
        }
    }

    struct Layer: Sendable {
        let name: String
        /// The side of the tile's grid, 4096 unless the layer says otherwise.
        let extent: Int
        let features: [Feature]
    }

    enum DecodingError: Error {
        case truncated
        case malformed
    }

    let layers: [String: Layer]

    /// The side of a layer's grid when the layer does not say.
    static let defaultExtent = 4096

    /// This tile, the basemap's, with the vector extras' tile `other` added
    /// to it, each of its features marked as the extras': a layer both hold
    /// keeps this tile's features and then `other`'s, where the two lay them
    /// on the same grid, and a layer only `other` holds is taken whole.
    func merging(_ other: Self) -> Self {
        let extras = other.layers.mapValues { layer in
            Layer(name: layer.name, extent: layer.extent, features: layer.features.map { feature in
                var marked = feature
                marked.isFromExtras = true
                return marked
            })
        }
        return Self(layers: layers.merging(extras) { own, added in
            guard own.extent == added.extent else { return own }
            return Layer(name: own.name, extent: own.extent, features: own.features + added.features)
        })
    }

    private init(layers: [String: Layer]) {
        self.layers = layers
    }

    /// - Parameters:
    ///   - layerNames: the layers to keep. Every other layer is passed over
    ///     without its features being read.
    ///   - propertyKeys: the property keys to keep on each feature.
    init(data: Data, layerNames: Set<String>, propertyKeys: Set<String>) throws {
        var reader = ProtobufReader(bytes: [UInt8](data))
        var decoded: [String: Layer] = [:]
        while let field = try reader.nextField() {
            guard field.number == 3, field.wireType == .lengthDelimited else {
                try reader.skip(field.wireType)
                continue
            }
            let message = reader.reader(for: try reader.lengthDelimited())
            if let layer = try Self.layer(message, layerNames: layerNames, propertyKeys: propertyKeys) {
                decoded[layer.name] = layer
            }
        }
        layers = decoded
    }

    /// One layer, or `nil` for a layer not in `layerNames`. Its features come
    /// before the keys and values their tags index in the usual encoding, so
    /// they are read once the whole message has been walked.
    private static func layer(
        _ message: ProtobufReader,
        layerNames: Set<String>,
        propertyKeys: Set<String>
    ) throws -> Layer? {
        var reader = message
        var name = ""
        var extent = defaultExtent
        var keys: [String] = []
        var valueRanges: [Range<Int>] = []
        var featureRanges: [Range<Int>] = []
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .lengthDelimited): name = try reader.string()
            case (2, .lengthDelimited): featureRanges.append(try reader.lengthDelimited())
            case (3, .lengthDelimited): keys.append(try reader.string())
            case (4, .lengthDelimited): valueRanges.append(try reader.lengthDelimited())
            case (5, .varint): extent = Int(clamping: try reader.varint())
            default: try reader.skip(field.wireType)
            }
        }
        guard layerNames.contains(name) else { return nil }
        guard extent > 0 else { throw DecodingError.malformed }

        let values = try valueRanges.map { try value(reader.reader(for: $0)) }
        let kept = keys.map(propertyKeys.contains)
        let features = try featureRanges.map { range in
            try feature(reader.reader(for: range), keys: keys, values: values, kept: kept)
        }
        return Layer(name: name, extent: extent, features: features)
    }

    private static func feature(
        _ message: ProtobufReader,
        keys: [String],
        values: [Value?],
        kept: [Bool]
    ) throws -> Feature {
        var reader = message
        var type = GeometryType.unknown
        var tags: [UInt32] = []
        var geometry: [UInt32] = []
        while let field = try reader.nextField() {
            switch field.number {
            case 2: try reader.appendVarints(to: &tags, wireType: field.wireType)
            case 3: type = GeometryType(rawValue: try reader.varint()) ?? .unknown
            case 4: try reader.appendVarints(to: &geometry, wireType: field.wireType)
            default: try reader.skip(field.wireType)
            }
        }
        guard tags.count.isMultiple(of: 2) else { throw DecodingError.malformed }
        var properties: [String: Value] = [:]
        for pair in stride(from: 0, to: tags.count, by: 2) {
            let key = Int(tags[pair])
            let value = Int(tags[pair + 1])
            guard key < keys.count, value < values.count else { throw DecodingError.malformed }
            guard kept[key], let decoded = values[value] else { continue }
            properties[keys[key]] = decoded
        }
        return Feature(type: type, properties: properties, geometry: geometry)
    }

    /// A value message, or `nil` for one of a kind this reader does not keep.
    private static func value(_ message: ProtobufReader) throws -> Value? {
        var reader = message
        var value: Value?
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .lengthDelimited): value = .string(try reader.string())
            case (2, .fixed32): value = .number(Double(Float(bitPattern: try reader.fixed32())))
            case (3, .fixed64): value = .number(Double(bitPattern: try reader.fixed64()))
            case (4, .varint): value = .number(Double(Int64(bitPattern: try reader.varint())))
            case (5, .varint): value = .number(Double(try reader.varint()))
            case (6, .varint): value = .number(Double(ProtobufReader.zigZag(try reader.varint())))
            case (7, .varint): value = .bool(try reader.varint() != 0)
            default: try reader.skip(field.wireType)
            }
        }
        return value
    }
}

/// The protobuf wire format, as far as a vector tile uses it.
nonisolated struct ProtobufReader {
    enum WireType: UInt64 {
        case varint = 0
        case fixed64 = 1
        case lengthDelimited = 2
        case fixed32 = 5
    }

    let bytes: [UInt8]
    private var position: Int
    private let end: Int

    init(bytes: [UInt8]) {
        self.init(bytes: bytes, range: bytes.indices)
    }

    private init(bytes: [UInt8], range: Range<Int>) {
        self.bytes = bytes
        position = range.lowerBound
        end = range.upperBound
    }

    /// A field key's low bits name its wire type, and the rest its number.
    private static let wireTypeBits: UInt64 = 3
    /// Each byte of a varint carries seven bits, and says in its eighth
    /// whether another follows.
    private static let varintPayload: UInt8 = 0x7F
    private static let varintContinues: UInt8 = 0x80
    private static let varintBitsPerByte: UInt64 = 7
    private static let maximumVarintBits: UInt64 = 64

    /// A reader over a nested message, sharing these bytes.
    func reader(for range: Range<Int>) -> Self {
        Self(bytes: bytes, range: range)
    }

    mutating func nextField() throws -> (number: UInt64, wireType: WireType)? {
        guard position < end else { return nil }
        let key = try varint()
        let typeMask: UInt64 = (1 << Self.wireTypeBits) - 1
        guard let wireType = WireType(rawValue: key & typeMask) else { throw MapboxVectorTile.DecodingError.malformed }
        return (key >> Self.wireTypeBits, wireType)
    }

    mutating func varint() throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while position < end, shift < Self.maximumVarintBits {
            let byte = bytes[position]
            position += 1
            value |= UInt64(byte & Self.varintPayload) << shift
            if byte & Self.varintContinues == 0 { return value }
            shift += Self.varintBitsPerByte
        }
        throw MapboxVectorTile.DecodingError.truncated
    }

    mutating func lengthDelimited() throws -> Range<Int> {
        let length = try varint()
        guard length <= UInt64(end - position) else { throw MapboxVectorTile.DecodingError.truncated }
        let range = position..<(position + Int(length))
        position = range.upperBound
        return range
    }

    mutating func string() throws -> String {
        guard let string = String(bytes: bytes[try lengthDelimited()], encoding: .utf8) else {
            throw MapboxVectorTile.DecodingError.malformed
        }
        return string
    }

    mutating func fixed32() throws -> UInt32 {
        UInt32(truncatingIfNeeded: try littleEndian(byteCount: 4))
    }

    mutating func fixed64() throws -> UInt64 {
        try littleEndian(byteCount: 8)
    }

    /// A repeated `uint32`, packed (the usual encoding) or one value per field.
    mutating func appendVarints(to values: inout [UInt32], wireType: WireType) throws {
        switch wireType {
        case .varint:
            values.append(UInt32(truncatingIfNeeded: try varint()))
        case .lengthDelimited:
            var packed = reader(for: try lengthDelimited())
            while packed.position < packed.end {
                values.append(UInt32(truncatingIfNeeded: try packed.varint()))
            }
        default:
            throw MapboxVectorTile.DecodingError.malformed
        }
    }

    mutating func skip(_ wireType: WireType) throws {
        switch wireType {
        case .varint: _ = try varint()
        case .fixed64: _ = try littleEndian(byteCount: 8)
        case .lengthDelimited: _ = try lengthDelimited()
        case .fixed32: _ = try littleEndian(byteCount: 4)
        }
    }

    static func zigZag(_ value: UInt64) -> Int64 {
        Int64(bitPattern: value >> 1) ^ -Int64(bitPattern: value & 1)
    }

    private mutating func littleEndian(byteCount: Int) throws -> UInt64 {
        guard end - position >= byteCount else { throw MapboxVectorTile.DecodingError.truncated }
        var value: UInt64 = 0
        for index in 0..<byteCount {
            value |= UInt64(bytes[position + index]) << (8 * UInt64(index))
        }
        position += byteCount
        return value
    }
}
