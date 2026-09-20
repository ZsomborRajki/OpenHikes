//
//  WatchLink.swift
//  OpenHikesShared
//
//  The envelope every message between the phone and the watch travels in, and
//  the one place either side encodes or decodes one.
//
//  ## Why an envelope at all
//
//  `WCSession` hands both sides a `[String: Any]` of property-list types and
//  says nothing about what is in it. Left at that, each screen that sends
//  something invents a key, and each handler guesses at what it received —
//  which is the same drift `SharedStore` exists to prevent across the App
//  Group, in a place with one more process and no file to look at afterwards.
//
//  So a message is exactly two keys: a ``WatchMessageKind`` naming what it is,
//  and the payload's bytes. The bytes are JSON rather than a nested
//  dictionary because the payloads are already `Codable` for the App Group,
//  and because `WCSession` accepts `Data` as a property-list type — so a
//  payload crosses the link and lands in the container in the same encoding,
//  and nothing has to describe it twice.
//
//  ## Version checking is the link's job, not the receiver's
//
//  The two sides of this link are different binaries that a hiker updates
//  independently: a watch can sit on last month's build for weeks. So every
//  decode peeks at ``SharedPayload/schemaVersion`` before a field is
//  interpreted, exactly as `SharedStore.decode` does, and a payload from a
//  version this build does not know is refused as one rather than half-read.
//  ``WatchLinkFailure/unsupportedVersion(_:found:supported:)`` is what a
//  caller shows or logs; there is nothing else useful it can do.
//

import Foundation

/// What a message is. A `String` raw value for the reason every other wire
/// enum here has one: legible in a log, and stable if the cases are reordered.
public enum WatchMessageKind: String, Codable, Sendable, CaseIterable {
    /// Phone → watch, as the *reply* to a command. What the phone did about
    /// it, and the state that resulted either way.
    case commandOutcome = "commandOutcome"
    /// Phone → watch. The hiker's trails, as a list to choose from.
    case libraryDigest = "libraryDigest"
    /// Watch → phone. "Send me the list again."
    ///
    /// The pull half of the library. The push half is an application context,
    /// which is the right transport for it and still leaves one case
    /// uncovered: a watch app *installed while the phone app was already
    /// running* has no context waiting for it and no change coming, so it sat
    /// on an empty list telling the hiker to open an app that was open. This
    /// is the watch saying so itself.
    case libraryRequest = "libraryRequest"
    /// Phone → watch. What the phone's own recorder is doing, so the watch
    /// can show it and drive it. See ``WatchPhoneRecording``.
    case phoneRecording = "phoneRecording"
    /// Watch → phone. A finished recording, to be kept as a hike.
    case recordedWalk = "recordedWalk"
    /// Watch → phone. A button on the watch, for the phone's recorder.
    case recordingCommand = "recordingCommand"
    /// Phone → watch. The trail's geometry, answering a request.
    case trailPackage = "trailPackage"
    /// Watch → phone. "Send me this trail's line."
    case trailRequest = "trailRequest"
    /// Phone → watch. "That walk is saved; you can let it go."
    case walkReceipt = "walkReceipt"
}

/// Why a message could not be read.
public enum WatchLinkFailure: LocalizedError, Equatable, Sendable {
    /// The bytes were the right format and the wrong shape.
    case malformed(WatchMessageKind, detail: String)
    /// The kind was known and the bytes were missing.
    case missingBody(WatchMessageKind)
    /// The dictionary carried no kind, or one this build does not know. Not an
    /// error worth showing anybody — a newer build on the other wrist is the
    /// likeliest cause — but it is worth being able to see in a log.
    case unrecognizedKind(String?)
    /// The payload announced a format this build does not read.
    case unsupportedVersion(WatchMessageKind, found: Int, supported: Int)

    public var errorDescription: String? {
        switch self {
        case let .malformed(kind, detail):
            "A \(kind.rawValue) message could not be read: \(detail)"
        case let .missingBody(kind):
            "A \(kind.rawValue) message arrived with nothing in it."
        case let .unrecognizedKind(raw):
            "The other device sent a message this version doesn't recognize (\(raw ?? "no kind"))."
        case let .unsupportedVersion(kind, found, supported):
            "A \(kind.rawValue) message is in format \(found); this version reads \(supported)."
        }
    }
}

/// Encoding and decoding the one envelope, shared by both sides.
public enum WatchLink {
    static let kindKey = "kind"
    static let bodyKey = "body"

    /// Reads a versioned payload back out, refusing a format this build does
    /// not know before any field is interpreted.
    ///
    /// Internal, and the typed accessors below are the way in. That is not
    /// access-level tidiness: a generic pair of `encode`/`decode` lets a
    /// caller put a ``WatchTrailRequest`` in an envelope labelled
    /// ``WatchMessageKind/recordedWalk``, and the receiver would then fail to
    /// decode a message that was never wrong on the wire — the hardest kind of
    /// bug to find across two binaries with no shared log. Pairing each kind
    /// with exactly one type in one place makes that unspellable. It is also
    /// what keeps ``SharedPayload`` internal, which is where it belongs: it
    /// describes how this package versions its own files, not something a
    /// consumer conforms to.
    static func payload<Payload: SharedPayload>(
        _ type: Payload.Type,
        of kind: WatchMessageKind,
        from message: [String: Any]
    ) throws(WatchLinkFailure) -> Payload {
        guard let data = message[bodyKey] as? Data else { throw .missingBody(kind) }
        let announced = (
            try? JSONDecoder().decode(SharedPayloadVersionPeek.self, from: data)
        )?.schemaVersion
        if let announced, announced != Payload.currentSchemaVersion {
            throw .unsupportedVersion(
                kind,
                found: announced,
                supported: Payload.currentSchemaVersion
            )
        }
        do {
            return try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw .malformed(kind, detail: SharedStoreDiagnostics.describe(error))
        }
    }

    /// Wraps a payload for `WCSession`.
    ///
    /// Throws only what `JSONEncoder` throws, which for these payloads means a
    /// non-finite `Double` — a latitude that is `nan` because a receiver gave
    /// one. Worth propagating rather than swallowing: the alternative is a
    /// message that silently never goes.
    static func message(
        _ kind: WatchMessageKind,
        _ payload: some Encodable & Sendable
    ) throws -> [String: Any] {
        [kindKey: kind.rawValue, bodyKey: try JSONEncoder().encode(payload)]
    }

    /// What kind of message this is, without reading its body.
    ///
    /// `nil` rather than a throw, because the first thing either side does
    /// with a delivery is switch on this, and a message from a build that
    /// knows a kind this one does not is an ordinary thing rather than a
    /// failure.
    public static func kind(of message: [String: Any]) -> WatchMessageKind? {
        (message[kindKey] as? String).flatMap(WatchMessageKind.init(rawValue:))
    }
}

// MARK: The five messages

/// One pair of functions per ``WatchMessageKind``, which is the whole
/// vocabulary of this link. Adding a kind without adding its pair here leaves
/// it unsendable and unreadable, which is the intended amount of friction.
public extension WatchLink {
    static func message(_ digest: WatchLibraryDigest) throws -> [String: Any] {
        try message(.libraryDigest, digest)
    }

    static func libraryDigest(from message: [String: Any]) throws(WatchLinkFailure) -> WatchLibraryDigest {
        try payload(WatchLibraryDigest.self, of: .libraryDigest, from: message)
    }

    static func message(_ request: WatchTrailRequest) throws -> [String: Any] {
        try message(.trailRequest, request)
    }

    static func trailRequest(from message: [String: Any]) throws(WatchLinkFailure) -> WatchTrailRequest {
        try payload(WatchTrailRequest.self, of: .trailRequest, from: message)
    }

    static func message(_ package: WatchTrailPackage) throws -> [String: Any] {
        try message(.trailPackage, package)
    }

    static func trailPackage(from message: [String: Any]) throws(WatchLinkFailure) -> WatchTrailPackage {
        try payload(WatchTrailPackage.self, of: .trailPackage, from: message)
    }

    static func message(_ walk: WatchRecordedWalk) throws -> [String: Any] {
        try message(.recordedWalk, walk)
    }

    static func recordedWalk(from message: [String: Any]) throws(WatchLinkFailure) -> WatchRecordedWalk {
        try payload(WatchRecordedWalk.self, of: .recordedWalk, from: message)
    }

    static func message(_ receipt: WatchWalkReceipt) throws -> [String: Any] {
        try message(.walkReceipt, receipt)
    }

    static func walkReceipt(from message: [String: Any]) throws(WatchLinkFailure) -> WatchWalkReceipt {
        try payload(WatchWalkReceipt.self, of: .walkReceipt, from: message)
    }

    /// Encoded but never decoded, which is why this kind has no reader beside
    /// it while every other one does.
    ///
    /// ``WatchLibraryRequest`` carries a schema version and nothing else: it
    /// is a watch with no list saying so. The phone answers the *kind* by
    /// sweeping its library — see ``WatchSessionCoordinator`` — and never asks
    /// what was in the message, because there is nothing in it to ask about.
    /// A decoder existed here for symmetry, and symmetry is not a caller.
    static func message(_ request: WatchLibraryRequest) throws -> [String: Any] {
        try message(.libraryRequest, request)
    }

    static func message(_ recording: WatchPhoneRecording) throws -> [String: Any] {
        try message(.phoneRecording, recording)
    }

    static func phoneRecording(from message: [String: Any]) throws(WatchLinkFailure) -> WatchPhoneRecording {
        try payload(WatchPhoneRecording.self, of: .phoneRecording, from: message)
    }

    static func message(_ command: WatchRecordingCommand) throws -> [String: Any] {
        try message(.recordingCommand, command)
    }

    static func recordingCommand(from message: [String: Any]) throws(WatchLinkFailure) -> WatchRecordingCommand {
        try payload(WatchRecordingCommand.self, of: .recordingCommand, from: message)
    }

    static func message(_ outcome: WatchCommandOutcome) throws -> [String: Any] {
        try message(.commandOutcome, outcome)
    }

    static func commandOutcome(from message: [String: Any]) throws(WatchLinkFailure) -> WatchCommandOutcome {
        try payload(WatchCommandOutcome.self, of: .commandOutcome, from: message)
    }
}
