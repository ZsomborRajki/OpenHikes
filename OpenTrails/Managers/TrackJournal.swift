//
//  TrackJournal.swift
//  OpenTrails
//
//  Append-only recording storage. The fixed-width tail can be truncated after
//  a crash without losing any complete point before it.
//

import Foundation

nonisolated enum TrackJournalError: Error, Equatable, Sendable {
    case invalidHeader
    case unsupportedVersion(UInt16)
    case io(String)
}

nonisolated struct RecordingPauseInterval: Codable, Equatable, Sendable {
    var startedAt: Date
    var endedAt: Date?
}

nonisolated struct TrackJournalMetadata: Codable, Equatable, Sendable {
    var sessionID: UUID
    var startedAt: Date
    var endedAt: Date?
    var lastUpdatedAt: Date
    var pausedIntervals: [RecordingPauseInterval]
    var title: String?
    var recordingOptions: RecordingSessionOptions?
}

nonisolated struct TrackJournalSession: Equatable, Sendable {
    var metadata: TrackJournalMetadata
    var points: [RecordingPoint]
}

actor TrackJournal {
    static let headerByteCount = 64
    // The documented fields total 44 bytes: three Doubles, four Floats and
    // one UInt32. Keeping every field is more valuable than pretending this is
    // 40 bytes and silently dropping reported speed.
    static let recordByteCount = 44

    nonisolated let directory: URL
    nonisolated let journalURL: URL
    nonisolated let metadataURL: URL

    private static let magic = Data([0x4F, 0x54, 0x52, 0x4B]) // OTRK
    private static let version: UInt16 = 1
    private static let batchSize = 10
    private static let maximumFlushInterval: TimeInterval = 5

    private let clock: @Sendable () -> Date
    private var fileHandle: FileHandle?
    private var pending: [RecordingPoint] = []
    private var metadata: TrackJournalMetadata?
    private var lastFlushAt: Date?

    init(
        directory: URL,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.journalURL = directory.appendingPathComponent("recording.otrk")
        self.metadataURL = directory.appendingPathComponent("recording.json")
        self.clock = clock
    }

    deinit {
        try? fileHandle?.close()
    }

    func start(
        sessionID: UUID,
        startedAt: Date,
        title: String? = nil,
        recordingOptions: RecordingSessionOptions? = nil
    ) throws {
        assertOffMainThread("Track journal creation must stay off the main thread")
        try closeHandle()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            for url in [journalURL, metadataURL]
            where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }

            try Self.header(sessionID: sessionID, startedAt: startedAt)
                .write(to: journalURL, options: .atomic)
            fileHandle = try FileHandle(forWritingTo: journalURL)
            try fileHandle?.seekToEnd()
            let metadata = TrackJournalMetadata(
                sessionID: sessionID,
                startedAt: startedAt,
                endedAt: nil,
                lastUpdatedAt: clock(),
                pausedIntervals: [],
                title: title,
                recordingOptions: recordingOptions
            )
            self.metadata = metadata
            pending = []
            lastFlushAt = clock()
            try writeMetadata(metadata)
        } catch let error as TrackJournalError {
            throw error
        } catch {
            throw TrackJournalError.io(error.localizedDescription)
        }
    }

    func append(_ point: RecordingPoint) throws {
        pending.append(point)
        let now = clock()
        let elapsed = lastFlushAt.map { now.timeIntervalSince($0) } ?? .infinity
        if pending.count >= Self.batchSize || elapsed >= Self.maximumFlushInterval {
            try flush()
        }
    }

    @discardableResult
    func mergeWidgetFixes(
        _ points: [RecordingPoint],
        duplicateInterval: TimeInterval = 5
    ) throws -> Int {
        assertOffMainThread(
            "Widget fix journal merges must stay off the main thread"
        )
        guard !points.isEmpty else { return 0 }
        try flush()
        guard fileHandle != nil else {
            throw TrackJournalError.io("The recording journal is closed.")
        }

        let data: Data
        do {
            data = try Data(contentsOf: journalURL)
        } catch {
            throw TrackJournalError.io(error.localizedDescription)
        }
        var timestamps = Self.decodeRecords(data).map(\.timestamp)
        var accepted: [RecordingPoint] = []
        for point in points.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard !timestamps.contains(where: {
                abs($0.timeIntervalSince(point.timestamp))
                    <= duplicateInterval
            }) else {
                continue
            }
            accepted.append(point)
            timestamps.append(point.timestamp)
        }
        pending.append(contentsOf: accepted)
        if !accepted.isEmpty {
            try flush()
        }
        return accepted.count
    }

    func pause(at date: Date) throws {
        try flush()
        guard var metadata else {
            throw TrackJournalError.io("No recording session is open.")
        }
        if metadata.pausedIntervals.last?.endedAt != nil || metadata.pausedIntervals.isEmpty {
            metadata.pausedIntervals.append(
                RecordingPauseInterval(startedAt: date, endedAt: nil)
            )
        }
        metadata.lastUpdatedAt = clock()
        self.metadata = metadata
        try writeMetadata(metadata)
    }

    func resume(at date: Date) throws {
        try flush()
        guard var metadata else {
            throw TrackJournalError.io("No recording session is open.")
        }
        if let index = metadata.pausedIntervals.indices.last,
           metadata.pausedIntervals[index].endedAt == nil {
            metadata.pausedIntervals[index].endedAt = date
        }
        metadata.endedAt = nil
        metadata.lastUpdatedAt = clock()
        self.metadata = metadata
        try writeMetadata(metadata)
    }

    func finish(at date: Date) throws {
        try flush()
        guard var metadata else {
            throw TrackJournalError.io("No recording session is open.")
        }
        if let index = metadata.pausedIntervals.indices.last,
           metadata.pausedIntervals[index].endedAt == nil {
            metadata.pausedIntervals[index].endedAt = date
        }
        metadata.endedAt = date
        metadata.lastUpdatedAt = clock()
        self.metadata = metadata
        try writeMetadata(metadata)
        try closeHandle()
    }

    func flush() throws {
        assertOffMainThread("Track journal writes must stay off the main thread")
        guard !pending.isEmpty else { return }
        guard let fileHandle else {
            throw TrackJournalError.io("The recording journal is closed.")
        }

        do {
            var bytes = Data()
            bytes.reserveCapacity(pending.count * Self.recordByteCount)
            for point in pending {
                bytes.append(Self.encode(point))
            }
            try fileHandle.write(contentsOf: bytes)
            try fileHandle.synchronize()
            pending.removeAll(keepingCapacity: true)
            lastFlushAt = clock()
            if var metadata {
                metadata.lastUpdatedAt = lastFlushAt ?? clock()
                self.metadata = metadata
                try writeMetadata(metadata)
            }
        } catch let error as TrackJournalError {
            throw error
        } catch {
            throw TrackJournalError.io(error.localizedDescription)
        }
    }

    func loadSession() throws -> TrackJournalSession? {
        assertOffMainThread("Track journal recovery must stay off the main thread")
        if fileHandle != nil {
            try flush()
        }
        guard FileManager.default.fileExists(atPath: journalURL.path),
              FileManager.default.fileExists(atPath: metadataURL.path)
        else {
            return nil
        }

        do {
            let metadataData = try Data(contentsOf: metadataURL)
            let metadata = try JSONDecoder().decode(
                TrackJournalMetadata.self,
                from: metadataData
            )
            let data = try Data(contentsOf: journalURL)
            let header = try Self.decodeHeader(data)
            guard header.sessionID == metadata.sessionID,
                  abs(
                    header.startedAt.timeIntervalSince(
                        metadata.startedAt
                    )
                  ) < 0.001
            else {
                throw TrackJournalError.invalidHeader
            }
            return TrackJournalSession(
                metadata: metadata,
                points: Self.decodeRecords(data)
            )
        } catch let error as TrackJournalError {
            throw error
        } catch {
            throw TrackJournalError.io(error.localizedDescription)
        }
    }

    func reopenForAppending() throws {
        assertOffMainThread("Track journal recovery must stay off the main thread")
        guard fileHandle == nil else { return }
        do {
            fileHandle = try FileHandle(forWritingTo: journalURL)
            let size = try fileHandle?.seekToEnd() ?? 0
            let completeSize = UInt64(
                Self.headerByteCount
                    + Self.pointCount(fileSize: Int64(size))
                        * Self.recordByteCount
            )
            if size != completeSize {
                try fileHandle?.truncate(atOffset: completeSize)
            }
            try fileHandle?.seekToEnd()
            let metadataData = try Data(contentsOf: metadataURL)
            metadata = try JSONDecoder().decode(
                TrackJournalMetadata.self,
                from: metadataData
            )
            lastFlushAt = clock()
        } catch {
            try? fileHandle?.close()
            fileHandle = nil
            throw TrackJournalError.io(error.localizedDescription)
        }
    }

    func discard() throws {
        assertOffMainThread("Track journal deletion must stay off the main thread")
        try closeHandle()
        do {
            if FileManager.default.fileExists(atPath: journalURL.path) {
                try FileManager.default.removeItem(at: journalURL)
            }
            if FileManager.default.fileExists(atPath: metadataURL.path) {
                try FileManager.default.removeItem(at: metadataURL)
            }
            pending = []
            metadata = nil
            lastFlushAt = nil
        } catch {
            throw TrackJournalError.io(error.localizedDescription)
        }
    }

    /// Closes the active handle without changing session metadata. Production
    /// process termination does this implicitly; recovery tests use it to
    /// model a fresh launch against the same open journal.
    func close() throws {
        try flush()
        try closeHandle()
    }

    nonisolated static func pointCount(fileSize: Int64) -> Int {
        guard fileSize >= Int64(headerByteCount) else { return 0 }
        return Int((fileSize - Int64(headerByteCount)) / Int64(recordByteCount))
    }

    private func closeHandle() throws {
        do {
            try fileHandle?.close()
            fileHandle = nil
        } catch {
            throw TrackJournalError.io(error.localizedDescription)
        }
    }

    private func writeMetadata(_ metadata: TrackJournalMetadata) throws {
        do {
            let data = try JSONEncoder().encode(metadata)
            try data.write(to: metadataURL, options: .atomic)
        } catch {
            throw TrackJournalError.io(error.localizedDescription)
        }
    }

    private nonisolated static func header(
        sessionID: UUID,
        startedAt: Date
    ) -> Data {
        var data = Data()
        data.reserveCapacity(headerByteCount)
        data.append(magic)
        data.appendLittleEndian(version)
        data.appendLittleEndian(UInt16(0))

        var uuid = sessionID.uuid
        withUnsafeBytes(of: &uuid) { data.append(contentsOf: $0) }
        data.appendLittleEndian(startedAt.timeIntervalSince1970.bitPattern)
        data.append(Data(repeating: 0, count: headerByteCount - data.count))
        return data
    }

    private nonisolated static func decodeHeader(
        _ data: Data
    ) throws(TrackJournalError) -> (sessionID: UUID, startedAt: Date) {
        guard data.count >= headerByteCount,
              data.prefix(magic.count) == magic
        else {
            throw .invalidHeader
        }

        let version: UInt16 = data.littleEndianValue(at: 4)
        guard version == self.version else { throw .unsupportedVersion(version) }
        let uuidBytes = Array(data[8..<24])
        let sessionID = UUID(uuid: (
            uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
            uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
            uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
            uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
        ))
        let startedBits: UInt64 = data.littleEndianValue(at: 24)
        return (
            sessionID,
            Date(timeIntervalSince1970: Double(bitPattern: startedBits))
        )
    }

    private nonisolated static func encode(_ point: RecordingPoint) -> Data {
        var data = Data()
        data.reserveCapacity(recordByteCount)
        data.appendLittleEndian(point.latitude.bitPattern)
        data.appendLittleEndian(point.longitude.bitPattern)
        data.appendLittleEndian(point.timestamp.timeIntervalSince1970.bitPattern)
        data.appendLittleEndian(Float(point.elevation ?? .nan).bitPattern)
        data.appendLittleEndian(Float(point.horizontalAccuracy).bitPattern)
        data.appendLittleEndian(Float(point.course ?? .nan).bitPattern)
        data.appendLittleEndian(Float(point.speed ?? .nan).bitPattern)
        data.appendLittleEndian(point.flags.rawValue)
        return data
    }

    private nonisolated static func decodeRecords(_ data: Data) -> [RecordingPoint] {
        let count = pointCount(fileSize: Int64(data.count))
        var points: [RecordingPoint] = []
        points.reserveCapacity(count)

        for index in 0..<count {
            let offset = headerByteCount + index * recordByteCount
            let latitude = Double(
                bitPattern: data.littleEndianValue(at: offset)
            )
            let longitude = Double(
                bitPattern: data.littleEndianValue(at: offset + 8)
            )
            let timestamp = Double(
                bitPattern: data.littleEndianValue(at: offset + 16)
            )
            let elevation = Float(
                bitPattern: data.littleEndianValue(at: offset + 24)
            )
            let accuracy = Float(
                bitPattern: data.littleEndianValue(at: offset + 28)
            )
            let course = Float(
                bitPattern: data.littleEndianValue(at: offset + 32)
            )
            let speed = Float(
                bitPattern: data.littleEndianValue(at: offset + 36)
            )
            let flags: UInt32 = data.littleEndianValue(at: offset + 40)

            points.append(
                RecordingPoint(
                    latitude: latitude,
                    longitude: longitude,
                    timestamp: Date(timeIntervalSince1970: timestamp),
                    elevation: elevation.isNaN ? nil : Double(elevation),
                    horizontalAccuracy: Double(accuracy),
                    course: course.isNaN ? nil : Double(course),
                    speed: speed.isNaN ? nil : Double(speed),
                    flags: RecordingPointFlags(rawValue: flags)
                )
            )
        }
        return points
    }
}

private nonisolated extension Data {
    mutating func appendLittleEndian<Value: FixedWidthInteger>(_ value: Value) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    func littleEndianValue<Value: FixedWidthInteger>(at offset: Int) -> Value {
        let value: Value = withUnsafeBytes { bytes in
            bytes.loadUnaligned(fromByteOffset: offset, as: Value.self)
        }
        return Value(littleEndian: value)
    }
}
