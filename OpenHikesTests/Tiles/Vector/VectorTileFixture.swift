//
//  VectorTileFixture.swift
//  OpenHikesTests
//
//  Mapbox Vector Tiles written in code, so a suite states the tile it reads
//  rather than shipping a binary one: layers of features with properties and
//  geometry, encoded the way the tile server's tiles are, features before the
//  keys and values their tags index.
//

import CoreGraphics
import Foundation
@testable import OpenHikes

nonisolated enum VectorTileFixture {
    /// A property value as it goes on the wire, including the kinds the reader
    /// folds into a number.
    enum Value: Equatable {
        case bool(Bool)
        case double(Double)
        case float(Float)
        case int(Int64)
        case sint(Int64)
        case string(String)
        case uint(UInt64)
    }

    struct Feature {
        var type: MapboxVectorTile.GeometryType
        var properties: [String: Value] = [:]
        var geometry: [UInt32]
    }

    struct Layer {
        var name: String
        var extent = MapboxVectorTile.defaultExtent
        var features: [Feature]
    }

    static let grid = MapboxVectorTile.defaultExtent

    static func data(_ layers: [Layer]) -> Data {
        var tile = ProtobufWriter()
        for layer in layers { tile.message(3, encode(layer)) }
        return Data(tile.bytes)
    }

    /// Every layer and property the rasterizer reads, as it reads them for a
    /// reader of `language`.
    static func decoded(_ layers: [Layer], language: String = "en") throws -> MapboxVectorTile {
        try MapboxVectorTile(
            data: data(layers),
            layerNames: VectorTileRasterizer.layerNames,
            propertyKeys: VectorTileRasterizer.propertyKeys(language: language)
        )
    }

    /// A height as a test reads one, the same in every locale.
    static func height(_ meters: Double) -> String {
        "\(Int(meters.rounded())) m"
    }

    /// `layers`, decoded, drawn as `target` from the archive tile `source`.
    static func image(
        _ layers: [Layer],
        from source: VectorTileAddress,
        drawing target: VectorTileAddress
    ) throws -> CGImage? {
        VectorTileRasterizer.image(
            of: try decoded(layers),
            from: source,
            drawing: target,
            language: "en",
            height: height
        )
    }

    /// Whether any pixel of `image` is `hex`, give or take `tolerance` in
    /// each channel: by default the rounding a color picks up between color
    /// spaces, and more for the ink of a letter, which may cover no pixel
    /// whole.
    static func image(_ image: CGImage, has hex: String, tolerance: Int = 3) -> Bool {
        let value = Int(hex.dropFirst(), radix: 16) ?? 0
        let wanted = [(value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF]
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: buffer.baseAddress,
                      width: image.width,
                      height: image.height,
                      bitsPerComponent: 8,
                      bytesPerRow: image.width * 4,
                      space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return stride(from: 0, to: pixels.count, by: 4).contains { index in
            (0..<3).allSatisfy { abs(Int(pixels[index + $0]) - wanted[$0]) <= tolerance }
        }
    }

    // MARK: Geometry

    /// A rectangle as one clockwise ring, an exterior ring in the tile's
    /// downward grid.
    static func rectangle(x: ClosedRange<Int>, y: ClosedRange<Int>) -> [UInt32] {
        polygon([
            (x.lowerBound, y.lowerBound),
            (x.upperBound, y.lowerBound),
            (x.upperBound, y.upperBound),
            (x.lowerBound, y.upperBound),
        ])
    }

    /// One ring, without its closing point, which `ClosePath` supplies.
    static func polygon(_ ring: [(Int, Int)]) -> [UInt32] {
        steps(ring, firstCommand: moveTo, thenCommand: lineTo) + [command(closePath, count: 1)]
    }

    static func line(_ points: [(Int, Int)]) -> [UInt32] {
        steps(points, firstCommand: moveTo, thenCommand: lineTo)
    }

    /// Several points under one `MoveTo`, as a multipoint is encoded.
    static func points(_ points: [(Int, Int)]) -> [UInt32] {
        var encoded = [command(moveTo, count: points.count)]
        var cursor = (0, 0)
        for point in points {
            encoded += [zigZag(point.0 - cursor.0), zigZag(point.1 - cursor.1)]
            cursor = point
        }
        return encoded
    }

    private static let moveTo: UInt32 = 1
    private static let lineTo: UInt32 = 2
    private static let closePath: UInt32 = 7

    private static func steps(_ points: [(Int, Int)], firstCommand: UInt32, thenCommand: UInt32) -> [UInt32] {
        guard let first = points.first else { return [] }
        var encoded = [command(firstCommand, count: 1), zigZag(first.0), zigZag(first.1)]
        encoded.append(command(thenCommand, count: points.count - 1))
        var cursor = first
        for point in points.dropFirst() {
            encoded += [zigZag(point.0 - cursor.0), zigZag(point.1 - cursor.1)]
            cursor = point
        }
        return encoded
    }

    private static func command(_ id: UInt32, count: Int) -> UInt32 {
        id | UInt32(count) << 3
    }

    private static func zigZag(_ value: Int) -> UInt32 {
        UInt32(truncatingIfNeeded: (value << 1) ^ (value >> (Int.bitWidth - 1)))
    }

    // MARK: Encoding

    private static func encode(_ layer: Layer) -> [UInt8] {
        var keys: [String] = []
        var values: [Value] = []
        var writer = ProtobufWriter()
        writer.varint(15, 2)
        writer.string(1, layer.name)
        for feature in layer.features {
            var tags: [UInt32] = []
            for (key, value) in feature.properties.sorted(by: { $0.key < $1.key }) {
                if !keys.contains(key) { keys.append(key) }
                if !values.contains(value) { values.append(value) }
                tags += [UInt32(keys.firstIndex(of: key) ?? 0), UInt32(values.firstIndex(of: value) ?? 0)]
            }
            var encoded = ProtobufWriter()
            encoded.packed(2, tags)
            encoded.varint(3, feature.type.rawValue)
            encoded.packed(4, feature.geometry)
            writer.message(2, encoded.bytes)
        }
        for key in keys { writer.string(3, key) }
        for value in values { writer.message(4, encode(value)) }
        writer.varint(5, UInt64(layer.extent))
        return writer.bytes
    }

    private static func encode(_ value: Value) -> [UInt8] {
        var writer = ProtobufWriter()
        switch value {
        case let .string(string): writer.string(1, string)
        case let .float(float): writer.fixed32(2, float.bitPattern)
        case let .double(double): writer.fixed64(3, double.bitPattern)
        case let .int(int): writer.varint(4, UInt64(bitPattern: int))
        case let .uint(uint): writer.varint(5, uint)
        case let .sint(sint): writer.varint(6, UInt64(bitPattern: (sint << 1) ^ (sint >> (Int64.bitWidth - 1))))
        case let .bool(bool): writer.varint(7, bool ? 1 : 0)
        }
        return writer.bytes
    }
}

/// The protobuf wire format, written.
nonisolated struct ProtobufWriter {
    private(set) var bytes: [UInt8] = []

    mutating func varint(_ field: Int, _ value: UInt64) {
        key(field, wireType: 0)
        append(value)
    }

    mutating func string(_ field: Int, _ value: String) {
        message(field, Array(value.utf8))
    }

    mutating func message(_ field: Int, _ value: [UInt8]) {
        key(field, wireType: 2)
        append(UInt64(value.count))
        bytes += value
    }

    mutating func packed(_ field: Int, _ values: [UInt32]) {
        var packed = Self()
        for value in values { packed.append(UInt64(value)) }
        message(field, packed.bytes)
    }

    mutating func fixed32(_ field: Int, _ value: UInt32) {
        key(field, wireType: 5)
        for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }

    mutating func fixed64(_ field: Int, _ value: UInt64) {
        key(field, wireType: 1)
        for shift in stride(from: 0, to: 64, by: 8) { bytes.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }

    private mutating func key(_ field: Int, wireType: UInt64) {
        append(UInt64(field) << 3 | wireType)
    }

    /// The bit that says another byte of the varint follows.
    private static let continues: UInt8 = 0x80

    private mutating func append(_ value: UInt64) {
        var rest = value
        while rest >= UInt64(Self.continues) {
            bytes.append(UInt8(truncatingIfNeeded: rest) | Self.continues)
            rest >>= 7
        }
        bytes.append(UInt8(rest))
    }
}
