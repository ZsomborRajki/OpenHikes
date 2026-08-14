//
//  SharedStore.swift
//  OpenHikesShared
//
//  Reads/writes the current SharedTrailSnapshot to the App Group container.
//  The same code runs unmodified in OpenHikes and OpenWidgetExtension, which
//  resolve the same device-local App Group container.
//

import Foundation

public enum SharedStore {
    public static let appGroupID = "group.tappium.com.OpenHikes"
    private static let fileName = "trail-snapshot.json"
    private static let recordingFileName = "recording-snapshot.json"
    private static let basemapSetFileName = "trail-basemaps.json"
    private static let basemapDirectoryName = "basemaps"

    private static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// The shared container root for app-owned cross-process files that do not
    /// belong inside the trail snapshot itself.
    public static func appGroupContainerURL() -> URL? {
        containerURL
    }

    private static var fileURL: URL? {
        containerURL?.appendingPathComponent(fileName)
    }

    private static var recordingFileURL: URL? {
        containerURL?.appendingPathComponent(recordingFileName)
    }

    private static var pendingRecordingFixStore: PendingRecordingFixStore? {
        containerURL.map(PendingRecordingFixStore.init(directory:))
    }

    /// The current snapshot, or `nil` if none has ever been written, the App
    /// Group capability isn't wired up on this target yet, or the file can't
    /// be read/decoded.
    public static func load() -> SharedTrailSnapshot? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SharedTrailSnapshot.self, from: data)
    }

    /// Writes the snapshot. No-ops rather than crashing if the App Group
    /// container can't be resolved.
    public static func save(_ snapshot: SharedTrailSnapshot) {
        guard let fileURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Removes the stored snapshot and any rendered basemaps — used when the
    /// tracked hike is deselected or deleted, so a stale trail doesn't linger
    /// in the widget.
    public static func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
        clearBasemaps()
    }

    // MARK: Live recording

    public static func loadRecording() -> SharedRecordingSnapshot? {
        guard let recordingFileURL,
              let data = try? Data(contentsOf: recordingFileURL)
        else { return nil }
        return try? JSONDecoder().decode(
            SharedRecordingSnapshot.self,
            from: data
        )
    }

    public static func saveRecording(
        _ snapshot: SharedRecordingSnapshot
    ) throws {
        guard let recordingFileURL, let pendingRecordingFixStore else {
            throw SharedRecordingStoreError.containerUnavailable
        }
        try pendingRecordingFixStore.saveRecording(
            snapshot,
            to: recordingFileURL
        )
    }

    public static func clearRecording(sessionID: UUID? = nil) throws {
        guard let recordingFileURL, let pendingRecordingFixStore else {
            throw SharedRecordingStoreError.containerUnavailable
        }
        try pendingRecordingFixStore.clearRecordingState(
            recordingURL: recordingFileURL,
            sessionID: sessionID
        )
    }

    @discardableResult public static func appendPendingRecordingFix(
        _ fix: SharedRecordingFix
    ) throws -> Bool {
        guard let pendingRecordingFixStore, let recordingFileURL else {
            throw SharedRecordingStoreError.containerUnavailable
        }
        return try pendingRecordingFixStore.append(
            fix,
            validatingRecordingAt: recordingFileURL
        )
    }

    public static func loadPendingRecordingFixes() throws
        -> [SharedRecordingFix] {
        guard let pendingRecordingFixStore else {
            throw SharedRecordingStoreError.containerUnavailable
        }
        return try pendingRecordingFixStore.load()
    }

    public static func removePendingRecordingFixes(
        ids: Set<UUID>
    ) throws {
        guard let pendingRecordingFixStore else {
            throw SharedRecordingStoreError.containerUnavailable
        }
        try pendingRecordingFixStore.remove(ids: ids)
    }

    public static func claimRecordingWidgetSample(
        sessionID: UUID,
        minimumInterval: TimeInterval,
        at date: Date = .now
    ) throws -> Bool {
        guard let pendingRecordingFixStore else {
            throw SharedRecordingStoreError.containerUnavailable
        }
        return try pendingRecordingFixStore.claimSample(
            sessionID: sessionID,
            at: date,
            minimumInterval: minimumInterval
        )
    }

    public static func clearPendingRecordingFixes(
        sessionID: UUID? = nil
    ) throws {
        guard let pendingRecordingFixStore else {
            throw SharedRecordingStoreError.containerUnavailable
        }
        try pendingRecordingFixStore.clear(sessionID: sessionID)
    }

    // MARK: Basemaps

    // Kept in files of their own rather than inside the snapshot: the
    // snapshot is small and rewritten on every live fix, while these are
    // hundreds of KB and rewritten only when the trail's geometry changes.

    private static var basemapSetURL: URL? {
        containerURL?.appendingPathComponent(basemapSetFileName)
    }

    private static var basemapDirectoryURL: URL? {
        containerURL?.appendingPathComponent(basemapDirectoryName, isDirectory: true)
    }

    /// The rendered basemaps for `hikeID`, or `nil` if none have been
    /// rendered, they belong to a different hike, or they can't be read. The
    /// hike check is the caller's protection against a set that outlived the
    /// snapshot it was rendered alongside.
    public static func loadBasemapSet(for hikeID: UUID) -> TrailBasemapSet? {
        guard let basemapSetURL, let data = try? Data(contentsOf: basemapSetURL),
              let set = try? JSONDecoder().decode(TrailBasemapSet.self, from: data),
              set.hikeID == hikeID
        else { return nil }
        return set
    }

    public static func saveBasemapSet(_ set: TrailBasemapSet) {
        guard let basemapSetURL, let data = try? JSONEncoder().encode(set) else { return }
        try? data.write(to: basemapSetURL, options: .atomic)
    }

    /// Raw image bytes for a ``TrailBasemap/fileName``, or `nil` if the file
    /// is gone — in which case the drawing side falls back to the line-only
    /// glyph rather than showing a gap.
    public static func basemapImageData(named fileName: String) -> Data? {
        guard let url = basemapDirectoryURL?.appendingPathComponent(fileName) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Whether every image a set advertises is actually still on disk. The
    /// producing side checks this before deciding its work is already done,
    /// so a manifest that outlived its images gets re-rendered instead of
    /// being trusted forever.
    public static func hasAllBasemapImages(in set: TrailBasemapSet) -> Bool {
        guard let directory = basemapDirectoryURL, !set.images.isEmpty else { return false }
        return set.images.allSatisfy { image in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(image.fileName).path)
        }
    }

    /// Writes one rendered image, creating the basemap directory on first use.
    /// Returns whether it landed, so a partial render doesn't get advertised
    /// in the set.
    @discardableResult public static func writeBasemapImage(_ data: Data, named fileName: String) -> Bool {
        guard let directory = basemapDirectoryURL else { return false }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
            return true
        } catch { return false }
    }

    /// Deletes every basemap image except `fileNames`. Called after a render
    /// so the previous trail's images (and any half-written leftovers) don't
    /// accumulate in the container.
    public static func pruneBasemapImages(keeping fileNames: Set<String>) {
        guard let directory = basemapDirectoryURL,
              let contents = try? FileManager.default
                  .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        for url in contents where !fileNames.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Deletes exactly `fileNames`, for a render that wrote images and then
    /// abandoned them. The counterpart to ``pruneBasemapImages(keeping:)``:
    /// naming what to remove rather than what to keep is what makes it safe to
    /// call while another render may be writing files of its own.
    public static func removeBasemapImages(named fileNames: Set<String>) {
        guard let directory = basemapDirectoryURL else { return }
        for imageName in fileNames {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(imageName))
        }
    }

    public static func clearBasemaps() {
        if let url = basemapSetURL { try? FileManager.default.removeItem(at: url) }
        if let dir = basemapDirectoryURL { try? FileManager.default.removeItem(at: dir) }
    }
}
