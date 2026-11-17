//
//  AutoPauseEvidenceFile.swift
//  OpenHikes
//
//  Where a `DEBUG` build writes down what its recordings were shown: one
//  line for every fix delivered and every change of motion, in
//  ``AutoPauseEvidence``'s format.
//
//  Auto-Pause's radius and minutes are a first guess (#1470). A few real
//  stops recorded with a debug build, read here and replayed through
//  ``AutoPauseEvidence/replay(_:policy:)``, are what they are to be settled
//  from. The file stays on the device, in Application Support, where the
//  app's container can be downloaded from Xcode's Devices window; nothing
//  sends it anywhere, and a release build has none.
//

#if DEBUG
import Foundation
import OpenHikesShared
import os

nonisolated final class AutoPauseEvidenceFile: Sendable {
    private static let logger = Logger(subsystem: "OpenHikes", category: "AutoPauseEvidence")
    private static let directoryName = "AutoPauseEvidence"

    private let url: URL
    /// Appends in the order the records were handed over, off the main
    /// thread: the recorder calls from its fix path.
    private let queue = SerialAsyncQueue()

    /// One file a launch, named for when the launch began. `nil` when the
    /// directory cannot be made, which costs a debug build its evidence and
    /// nothing else.
    init?(
        applicationSupport: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
        now: Date = .now
    ) {
        guard let applicationSupport else { return nil }
        let directory = applicationSupport.appendingPathComponent(Self.directoryName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let name = Int(now.timeIntervalSince1970)
        url = directory.appendingPathComponent("evidence-\(name).csv")
    }

    func append(_ record: AutoPauseEvidence.Record) {
        let line = AutoPauseEvidence.line(for: record) + "\n"
        let file = url
        queue.enqueue {
            do {
                if !FileManager.default.fileExists(atPath: file.path) {
                    try Data().write(to: file)
                }
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } catch {
                Self.logger.error(
                    "Auto-pause evidence could not be written: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
#endif
