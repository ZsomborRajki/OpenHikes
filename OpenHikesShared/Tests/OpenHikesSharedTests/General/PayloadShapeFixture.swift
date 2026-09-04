//
//  PayloadShapeFixture.swift
//  OpenHikesSharedTests
//
//  Fully-populated instances of every payload that crosses the App Group, and
//  the description of an encoded value that ``SharedPayloadShapeTests``
//  compares against its golden record.
//
//  Separate from ``SharedStoreSandbox``'s fixtures on purpose. Those are built
//  for readability — they leave `elevationLossMeters` and `liveFix` at their
//  defaults, because a test about atomicity does not care. These cannot: a
//  `nil` optional is encoded as no key at all, so a shape taken from one of
//  those would be missing exactly the keys most likely to be renamed without
//  anyone noticing. Every optional below is set, and every array holds an
//  element, so that the shape describes the whole contract rather than the
//  part of it a convenient fixture happened to exercise.
//

import Foundation
@testable import OpenHikesShared
import Testing

// swiftlint:disable no_magic_numbers

enum PayloadShapeFixture {
    /// A payload paired with the name its failure message should use.
    struct Named: Sendable, CustomTestStringConvertible {
        let name: String
        let value: any Encodable & Sendable

        var testDescription: String { name }
    }

    static let everyPayload: [Named] = [
        Named(name: "SharedTrailSnapshot", value: trailSnapshot),
        Named(name: "SharedRecordingSnapshot", value: recordingSnapshot),
        Named(name: "SharedRecordingFix", value: recordingFix),
        Named(name: "TrailBasemapSet", value: basemapSet),
    ]

    static let trailSnapshot = SharedTrailSnapshot(
        hikeID: UUID(uuidString: "11111111-1111-1111-1111-111111111111") ?? UUID(),
        title: "Thumsee Loop",
        tintHex: "#2E7D32",
        totalDistanceMeters: 8420.5,
        polyline: [
            SharedTrailSnapshot.CodableCoordinate(latitude: 47.6961, longitude: 12.8543),
            SharedTrailSnapshot.CodableCoordinate(latitude: 47.6972, longitude: 12.8559),
        ],
        elevationLowMeters: 610.5,
        elevationHighMeters: 1122.5,
        elevationGainMeters: 512.5,
        elevationLossMeters: 498.5,
        liveFix: SharedTrailSnapshot.LiveFix(
            coordinate: SharedTrailSnapshot.CodableCoordinate(
                latitude: 47.6965,
                longitude: 12.8551
            ),
            distanceAlongRouteMeters: 2140.5,
            offRouteMeters: 6.5,
            timestamp: Date(timeIntervalSince1970: 1_700_000_500),
            elevationMeters: 812.5
        ),
        walk: SharedTrailSnapshot.Walk(
            state: .paused,
            coveredFraction: 0.25,
            furthestDistanceMeters: 2140.5,
            activeSeconds: 1830.5,
            startedAt: Date(timeIntervalSince1970: 1_699_998_000)
        ),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    static let recordingSnapshot = SharedRecordingSnapshot(
        sessionID: UUID(uuidString: "22222222-2222-2222-2222-222222222222") ?? UUID(),
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        distanceMeters: 1240.5,
        pointCount: 96,
        polyline: [
            SharedTrailSnapshot.CodableCoordinate(latitude: 47.6961, longitude: 12.8543),
            SharedTrailSnapshot.CodableCoordinate(latitude: 47.6972, longitude: 12.8559),
        ],
        elevationGainMeters: 88.5,
        averageSpeedMetersPerSecond: 1.35,
        isCapturingFixes: true,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_600)
    )

    static let recordingFix = SharedRecordingFix(
        sessionID: UUID(uuidString: "33333333-3333-3333-3333-333333333333") ?? UUID(),
        latitude: 47.6965,
        longitude: 12.8551,
        timestamp: Date(timeIntervalSince1970: 1_700_000_700),
        horizontalAccuracy: 8.5,
        id: UUID(uuidString: "44444444-4444-4444-4444-444444444444") ?? UUID(),
        elevation: 812.5,
        course: 91.5,
        speed: 1.45
    )

    static let basemapSet = TrailBasemapSet(
        hikeID: UUID(uuidString: "55555555-5555-5555-5555-555555555555") ?? UUID(),
        coverage: UnitMercatorRect(originX: 0.51, originY: 0.32, width: 0.02, height: 0.015),
        images: [
            TrailBasemap(
                fileName: "basemap-square-light.png",
                variant: .square,
                appearance: .light,
                pixelWidth: 960,
                pixelHeight: 960,
                visibleRect: UnitMercatorRect(
                    originX: 0.51,
                    originY: 0.32,
                    width: 0.02,
                    height: 0.02
                )
            ),
        ],
        generatedAt: Date(timeIntervalSince1970: 1_700_000_800)
    )
}

// swiftlint:enable no_magic_numbers

/// One JSON value, as JSON itself distinguishes them.
///
/// Decoded through `JSONDecoder` rather than read out of
/// `JSONSerialization.jsonObject`, which answers in bridged Objective-C
/// reference types and loses the one distinction this file most needs:
/// `true` arrives as an `NSNumber`, so `as? Bool` also succeeds for `1` and a
/// flag becoming a count would go unnoticed. `JSONDecoder` refuses to read a
/// number as a `Bool`, which is the same strictness the real payloads are
/// decoded with — so this describes what a reader will actually accept.
private enum JSONValue: Decodable {
    case array([Self])
    case bool(Bool)
    case null
    case number(Double)
    case object([String: Self])
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([Self].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: Self].self))
        }
    }
}

/// Describes an encoded payload as a sorted list of `path: kind` entries.
///
/// Deliberately coarse. The kinds are the ones JSON actually distinguishes —
/// object, array, string, number, bool, null — because those are the
/// distinctions a decoder will refuse to cross. A finer description would have
/// to invent differences JSON does not carry (`Double(3)` and `Int(3)` are the
/// same single byte) and would then fail for reasons that are about the
/// fixture rather than about the contract.
enum PayloadShape {
    static func of(_ value: some Encodable) throws -> [String] {
        let root = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        var entries: [String] = []
        describe(root, at: "", into: &entries)
        return entries.sorted()
    }

    /// The keys the payload writes at its top level, which is what a stored
    /// property has to reach to be part of the contract at all.
    static func topLevelKeys(of value: some Encodable) throws -> Set<String> {
        let root = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        guard case let .object(fields) = root else { return [] }
        return Set(fields.keys)
    }

    private static func describe(
        _ value: JSONValue,
        at path: String,
        into entries: inout [String]
    ) {
        switch value {
        case let .object(fields):
            for (key, nested) in fields {
                describe(nested, at: path.isEmpty ? key : "\(path).\(key)", into: &entries)
            }
        case let .array(elements):
            // An empty array is recorded rather than skipped: a fixture that
            // stopped populating one would otherwise quietly drop every key
            // below it out of the golden record, and the record would still
            // match.
            guard let first = elements.first else {
                entries.append("\(path)[]: empty in the fixture, element shape unchecked")
                return
            }
            describe(first, at: "\(path)[]", into: &entries)
        case .bool:
            entries.append("\(path): bool")
        case .number:
            entries.append("\(path): number")
        case .string:
            entries.append("\(path): string")
        case .null:
            entries.append("\(path): null")
        }
    }
}

/// Compares a payload's encoded shape against its golden record, failing with
/// the reason the difference matters rather than with two sorted arrays.
func expectShape(
    of value: some Encodable,
    named typeName: String,
    versionedBy versionConstant: String?,
    matches expected: [String],
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let actual = try PayloadShape.of(value)
    let removed = expected.filter { !actual.contains($0) }
    let added = actual.filter { !expected.contains($0) }

    let remedy = if let versionConstant {
        """
        If the change is deliberate, bump \(versionConstant) in the same commit, so a \
        build that predates it refuses the new payload out loud instead of half-reading \
        it, and update the expected shape below.
        """
    } else {
        """
        \(typeName) carries no version field, so there is no way to make an older reader \
        refuse the new shape politely — it will simply fail to decode. Change it only if \
        you have accounted for what happens to the payload already sitting in the \
        container, then update the expected shape below.
        """
    }

    #expect(
        actual == expected,
        Comment(rawValue: """
        The on-disk shape of \(typeName) has changed.

        removed: \(removed.isEmpty ? "(nothing)" : removed.joined(separator: "\n                 "))
        added:   \(added.isEmpty ? "(nothing)" : added.joined(separator: "\n                 "))

        This payload crosses the App Group between OpenHikes and \
        OpenWidgetExtension. It is decoded with `try?`, so a renamed, retyped or \
        removed key is not backward compatible: the load returns nil, which is the \
        same answer a container that was never written to gives, and the widget \
        draws its placeholder.

        \(remedy)

        If the change is not deliberate, revert it. Adding an *optional* key is the \
        one change to these payloads that is safe in both directions and needs no \
        version bump at all.
        """),
        sourceLocation: sourceLocation
    )
}
