//
//  SharedStoreDiagnostics.swift
//  OpenHikesShared
//
//  Where a refused App Group payload says so.
//
//  Modelled on the tile network policy, which emits a marker naming the
//  purpose and the reason on every suppressed fetch precisely because a tile
//  that silently never loads is the hardest thing in that pipeline to debug.
//  A snapshot that silently never decodes is the same situation one process
//  further out: the widget draws its placeholder, the app believes it
//  published, and the two never compare notes.
//
//  Deliberately not `#if DEBUG`. A blank widget is a field symptom — it is
//  reported by someone running a Release build on a mountain, not by anyone
//  attached to a debugger — so the one place this could pay for itself is the
//  one place a debug-only log would not exist.
//

import Foundation
import OSLog

/// A payload `SharedStore` declined to hand back, and why.
public enum SharedStoreDiagnostic: Sendable, Equatable {
    /// The bytes are present but this build cannot read them — the signature
    /// of a renamed, retyped or removed non-optional key. `detail` names the
    /// key and its coding path.
    case decodeFailed(file: String, detail: String)
    /// The bytes announce a version this build does not understand.
    case unsupportedSchemaVersion(file: String, found: Int, supported: Int)

    public var summary: String {
        switch self {
        case let .decodeFailed(file, detail):
            "\(file) could not be decoded: \(detail)"
        case let .unsupportedSchemaVersion(file, found, supported):
            "\(file) was written by a newer build (schema v\(found); this build reads v\(supported))"
        }
    }
}

enum SharedStoreDiagnostics {
    /// A test seam of the same shape as ``SharedStore/containerOverride``, and
    /// for the same reason: `OSLogStore` cannot be read back from an unsigned
    /// SwiftPM test process, so without somewhere to observe them a suite could
    /// assert that a payload was refused but never that anyone was told.
    /// Bound work still logs — the sink is an additional listener, not a
    /// replacement, so a test cannot pass by silencing the thing it checks.
    ///
    /// Wrapped in a struct for the same reason as
    /// ``SharedStore/ContainerOverride``: a function-typed `@TaskLocal` value
    /// is miscompiled under optimisation and segfaults when bound.
    struct Sink: Sendable {
        let receive: @Sendable (SharedStoreDiagnostic) -> Void

        init(_ receive: @escaping @Sendable (SharedStoreDiagnostic) -> Void) {
            self.receive = receive
        }
    }

    @TaskLocal static var sink: Sink?

    private static let logger = Logger(subsystem: "OpenHikes", category: "SharedStore")

    static func report(_ diagnostic: SharedStoreDiagnostic) {
        // `.public` because the whole point is to be readable in Console on a
        // device that is not attached to Xcode, and because everything
        // interpolated here is a file name, a coding key or a type name —
        // never a coordinate, a title or anything else the walker owns.
        logger.error("\(diagnostic.summary, privacy: .public)")
        sink?.receive(diagnostic)
    }

    /// `DecodingError.localizedDescription` is "The data couldn't be read
    /// because it isn't in the correct format" for every one of its cases,
    /// which is exactly as useful as the silence it replaces. The point of
    /// this is to name the key, so the next person reads "missing key
    /// 'totalDistanceMeters' at root" and knows what was renamed.
    static func describe(_ error: any Error) -> String {
        guard let decoding = error as? DecodingError else { return "\(error)" }
        switch decoding {
        case let .dataCorrupted(context):
            return "malformed at \(path(context)): \(context.debugDescription)"
        case let .keyNotFound(key, context):
            return "missing key '\(key.stringValue)' at \(path(context))"
        case let .typeMismatch(type, context):
            return "wrong type at \(path(context)): expected \(type)"
        case let .valueNotFound(type, context):
            return "null where \(type) was required, at \(path(context))"
        @unknown default:
            return "\(decoding)"
        }
    }

    private static func path(_ context: DecodingError.Context) -> String {
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        return path.isEmpty ? "root" : path
    }
}
