//
//  SharedRecordingFix.swift
//  OpenHikesShared
//
//  Widget-sourced location anchors. The widget owns pending-fixes.json; the
//  app consumes entries by id after they have landed safely in TrackJournal.
//

import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct SharedRecordingFix: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var sessionID: UUID
    public var latitude: Double
    public var longitude: Double
    public var timestamp: Date
    public var elevation: Double?
    public var horizontalAccuracy: Double
    public var course: Double?
    public var speed: Double?

    public init(
        sessionID: UUID,
        latitude: Double,
        longitude: Double,
        timestamp: Date,
        horizontalAccuracy: Double,
        id: UUID = UUID(),
        elevation: Double? = nil,
        course: Double? = nil,
        speed: Double? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
        self.elevation = elevation
        self.horizontalAccuracy = horizontalAccuracy
        self.course = course
        self.speed = speed
    }
}

enum SharedRecordingStoreError: LocalizedError, Sendable {
    case containerUnavailable
    case io(String)

    var errorDescription: String? {
        switch self {
        case .containerUnavailable: "The shared recording container is unavailable."
        case .io(let detail): detail
        }
    }
}

struct PendingRecordingFixStore: Sendable {
    static let maximumEntryCount = 200

    let directory: URL

    private var fileURL: URL {
        directory.appendingPathComponent("pending-fixes.json")
    }

    private var lockURL: URL {
        directory.appendingPathComponent("pending-fixes.lock")
    }

    private var samplingURL: URL {
        directory.appendingPathComponent("widget-sampling.json")
    }

    init(directory: URL) {
        self.directory = directory
    }

    // periphery:ignore - exercised by `OpenHikesShared/Tests`, a SwiftPM
    // target the Xcode-scheme scan does not index.
    func append(_ fix: SharedRecordingFix) throws {
        try withExclusiveLock {
            try appendUnlocked(fix)
        }
    }

    @discardableResult func append(
        _ fix: SharedRecordingFix,
        validatingRecordingAt recordingURL: URL
    ) throws -> Bool {
        try withExclusiveLock {
            guard let recording = try loadRecordingUnlocked(
                from: recordingURL
            ),
            recording.sessionID == fix.sessionID,
            recording.isCapturingFixes else { return false }
            try appendUnlocked(fix)
            return true
        }
    }

    func saveRecording(
        _ snapshot: SharedRecordingSnapshot,
        to recordingURL: URL
    ) throws {
        try withExclusiveLock {
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: recordingURL, options: .atomic)
            } catch {
                throw SharedRecordingStoreError.io(
                    error.localizedDescription
                )
            }
        }
    }

    func load() throws -> [SharedRecordingFix] {
        try withExclusiveLock {
            try loadUnlocked()
        }
    }

    func remove(ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        try withExclusiveLock {
            let remaining = try loadUnlocked().filter { fix in !ids.contains(fix.id) }
            try writeUnlocked(remaining)
        }
    }

    func claimSample(
        sessionID: UUID,
        at date: Date,
        minimumInterval: TimeInterval
    ) throws -> Bool {
        try withExclusiveLock {
            var samples = try loadSamplingUnlocked()
            let key = sessionID.uuidString
            if let previous = samples[key],
               date.timeIntervalSince(previous) < minimumInterval { return false }
            samples[key] = date
            try writeSamplingUnlocked(samples)
            return true
        }
    }

    func clear(sessionID: UUID? = nil) throws {
        try withExclusiveLock {
            try clearPendingUnlocked(sessionID: sessionID)
        }
    }

    func clearRecordingState(
        recordingURL: URL,
        sessionID: UUID? = nil
    ) throws {
        try withExclusiveLock {
            let removesSnapshot: Bool
            if let sessionID {
                // A snapshot that cannot be decoded names no session, so it
                // cannot claim to belong to a *different* recording and
                // survive this clear. Letting the decode failure propagate —
                // which is what this did — meant an unreadable snapshot
                // outlived the recording it described: this is the only clear
                // the stop path calls, so nothing else would ever remove it,
                // and every later `append(_:validatingRecordingAt:)` raised
                // against a file that had become permanent. Falling back to
                // removal reaches the same end state as the session-less
                // clear, which is the correct one for bytes that describe
                // nothing.
                if let existing = decodableRecordingUnlocked(from: recordingURL) {
                    removesSnapshot = existing.sessionID == sessionID
                } else {
                    removesSnapshot = true
                }
            } else {
                removesSnapshot = true
            }
            if removesSnapshot,
               FileManager.default.fileExists(atPath: recordingURL.path) {
                do {
                    try FileManager.default.removeItem(at: recordingURL)
                } catch {
                    throw SharedRecordingStoreError.io(
                        error.localizedDescription
                    )
                }
            }
            try clearPendingUnlocked(sessionID: sessionID)
        }
    }

    private func appendUnlocked(_ fix: SharedRecordingFix) throws {
        var fixes = try loadUnlocked()
        fixes.removeAll { $0.id == fix.id }
        fixes.append(fix)
        if fixes.count > Self.maximumEntryCount {
            fixes.removeFirst(fixes.count - Self.maximumEntryCount)
        }
        try writeUnlocked(fixes)
    }

    private func clearPendingUnlocked(sessionID: UUID?) throws {
        guard let sessionID else {
            do {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                }
                if FileManager.default.fileExists(atPath: samplingURL.path) {
                    try FileManager.default.removeItem(at: samplingURL)
                }
            } catch {
                throw SharedRecordingStoreError.io(
                    error.localizedDescription
                )
            }
            return
        }
        let remaining = try loadUnlocked().filter { fix in
            fix.sessionID != sessionID
        }
        try writeUnlocked(remaining)
        var samples = try loadSamplingUnlocked()
        samples.removeValue(forKey: sessionID.uuidString)
        try writeSamplingUnlocked(samples)
    }

    private func loadRecordingUnlocked(
        from recordingURL: URL
    ) throws -> SharedRecordingSnapshot? {
        guard FileManager.default.fileExists(atPath: recordingURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: recordingURL)
            return try JSONDecoder().decode(
                SharedRecordingSnapshot.self,
                from: data
            )
        } catch {
            // Still throws — the append path's caller has a fix in hand and
            // has to know it was not persisted — but says what broke on the
            // way out, so this stops being the only failure in the container
            // whose cause has to be guessed at.
            SharedStoreDiagnostics.report(
                .decodeFailed(
                    file: recordingURL.lastPathComponent,
                    detail: SharedStoreDiagnostics.describe(error)
                )
            )
            throw SharedRecordingStoreError.io(error.localizedDescription)
        }
    }

    /// ``loadRecordingUnlocked(from:)`` for the caller that cannot act on the
    /// difference between "no recording" and "a recording nobody can read":
    /// both mean there is no session here to match against.
    private func decodableRecordingUnlocked(
        from recordingURL: URL
    ) -> SharedRecordingSnapshot? {
        try? loadRecordingUnlocked(from: recordingURL)
    }

    private func loadUnlocked() throws -> [SharedRecordingFix] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode([SharedRecordingFix].self, from: data)
        } catch {
            throw SharedRecordingStoreError.io(error.localizedDescription)
        }
    }

    private func writeUnlocked(_ fixes: [SharedRecordingFix]) throws {
        do {
            if fixes.isEmpty {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                }
                return
            }
            let data = try JSONEncoder().encode(fixes)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw SharedRecordingStoreError.io(error.localizedDescription)
        }
    }

    private func loadSamplingUnlocked() throws -> [String: Date] {
        guard FileManager.default.fileExists(atPath: samplingURL.path) else { return [:] }
        do {
            let data = try Data(contentsOf: samplingURL)
            return try JSONDecoder().decode([String: Date].self, from: data)
        } catch {
            throw SharedRecordingStoreError.io(error.localizedDescription)
        }
    }

    private func writeSamplingUnlocked(_ samples: [String: Date]) throws {
        do {
            if samples.isEmpty {
                if FileManager.default.fileExists(atPath: samplingURL.path) {
                    try FileManager.default.removeItem(at: samplingURL)
                }
                return
            }
            let data = try JSONEncoder().encode(samples)
            try data.write(to: samplingURL, options: .atomic)
        } catch {
            throw SharedRecordingStoreError.io(error.localizedDescription)
        }
    }

    private func withExclusiveLock<Result>(
        _ operation: () throws -> Result
    ) throws -> Result {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw SharedRecordingStoreError.io(error.localizedDescription)
        }

        let descriptor = open(
            lockURL.path(percentEncoded: false),
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw SharedRecordingStoreError.io(
                String(cString: strerror(errno))
            )
        }
        defer { close(descriptor) }

        guard flock(descriptor, LOCK_EX) == 0 else {
            throw SharedRecordingStoreError.io(
                String(cString: strerror(errno))
            )
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }
}
