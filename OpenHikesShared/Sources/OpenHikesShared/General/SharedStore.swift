//
//  SharedStore.swift
//  OpenHikesShared
//
//  Reads and writes everything the app and the widget share through the App
//  Group container: the trail snapshot, the live recording snapshot and its
//  pending widget fixes, and the rendered basemaps.
//  The same code runs unmodified in OpenHikes and OpenWidgetExtension, which
//  resolve the same device-local App Group container.
//

import Foundation

public enum SharedStore {
    public static let appGroupID = "group.tappium.com.OpenHikes"
    private static let fileName = "trail-snapshot.json"
    private static let catalogueFileName = "hike-catalogue.json"
    /// The directory the per-hike snapshots live in, one file each.
    ///
    /// A directory rather than more names beside ``fileName``, because the set
    /// is unbounded and has to be sweepable: ``pruneTrailSnapshots(keeping:)``
    /// is what keeps a hiker with three hundred walks from accumulating three
    /// hundred snapshots, and it can only do that if it can list them.
    private static let trailSnapshotDirectoryName = "trail-snapshots"
    private static let recordingFileName = "recording-snapshot.json"
    private static let basemapSetFileName = "trail-basemaps.json"
    private static let basemapDirectoryName = "basemaps"

    /// Resolves the container root every path below is built from — a
    /// deliberate test seam, in the same spirit as the injectable clocks,
    /// transports and directories elsewhere in this project. The app and the
    /// widget never bind it and pay one task-local read against a
    /// `FileManager` container lookup.
    ///
    /// It is necessary rather than convenient. `swift test` runs this package
    /// as an unsigned macOS process, where
    /// `containerURL(forSecurityApplicationGroupIdentifier:)` does not fail:
    /// it hands back a real path under the developer's own
    /// `~/Library/Group Containers`. A suite exercising these functions
    /// without a seam would write into — and through ``clear()`` delete from
    /// — the container a locally installed build is using.
    ///
    /// A closure rather than a `URL?`, because a plain optional cannot tell
    /// "not overridden" from "overridden to no container at all", and the
    /// second is the branch worth testing hardest: it is what every
    /// ``SharedRecordingStoreError/containerUnavailable`` throw below is for.
    ///
    /// Task-local rather than a settable static, because a binding is scoped
    /// to the work that made it. It cannot outlive a test or leak into a suite
    /// running beside it, which a process-global `static var` on an all-static
    /// type would do under Swift Testing's parallel execution.
    ///
    /// The closure is wrapped in a struct rather than being the task-local's
    /// own type. A *function*-typed `@TaskLocal` value segfaults inside
    /// `swift_task_localValuePushImpl` when the binding is compiled with
    /// optimisation — reproducible in twenty lines on Swift 6.2 / Xcode 26.6,
    /// and the reason `swift test --configuration release` crashed on every
    /// suite that bound one while the same suites passed in debug. A struct
    /// holding the same closure is not miscompiled, so the wrapper is load
    /// bearing: do not "simplify" it back to a bare closure without re-running
    /// the release configuration.
    struct ContainerOverride: Sendable {
        let resolve: @Sendable () -> URL?

        // periphery:ignore - exercised by `OpenHikesShared/Tests`, a SwiftPM
        // target the Xcode scheme this scan builds does not contain.
        init(_ resolve: @escaping @Sendable () -> URL?) {
            self.resolve = resolve
        }
    }

    @TaskLocal static var containerOverride: ContainerOverride?

    private static var containerURL: URL? {
        if let containerOverride { return containerOverride.resolve() }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// The shared container root for app-owned cross-process files that do not
    /// belong inside the trail snapshot itself.
    public static func appGroupContainerURL() -> URL? {
        containerURL
    }

    private static var fileURL: URL? {
        containerURL?.appendingPathComponent(fileName)
    }

    private static var catalogueURL: URL? {
        containerURL?.appendingPathComponent(catalogueFileName)
    }

    private static var trailSnapshotDirectoryURL: URL? {
        containerURL?.appendingPathComponent(trailSnapshotDirectoryName, isDirectory: true)
    }

    private static func trailSnapshotURL(for hikeID: UUID) -> URL? {
        trailSnapshotDirectoryURL?.appendingPathComponent("\(hikeID.uuidString).json")
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
    ///
    /// `nil` still means "nothing usable here" — the widget's fallback is the
    /// right drawing for every one of those causes, and giving callers a
    /// `Result` to switch on would spread a decision none of them can act on.
    /// What changed is that the last cause now announces itself through
    /// ``SharedStoreDiagnostic`` instead of being indistinguishable from the
    /// first.
    public static func load() -> SharedTrailSnapshot? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return decode(SharedTrailSnapshot.self, from: data, named: fileName)
    }

    /// Writes the snapshot. No-ops rather than crashing if the App Group
    /// container can't be resolved.
    ///
    /// **Mirrored into the per-hike store as well**, and here rather than at
    /// the call sites, because that is what makes the two impossible to
    /// disagree. The selected trail is by far the most-written snapshot, and a
    /// widget pinned to the hike that also happens to be selected must not see
    /// a staler copy of it than the unconfigured widget beside it does.
    public static func save(_ snapshot: SharedTrailSnapshot) {
        saveTrailSnapshot(snapshot)
        guard let fileURL else { return }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Removes the stored snapshot and any rendered basemaps — used when the
    /// tracked hike is deselected or deleted, so a stale trail doesn't linger
    /// in the widget.
    /// **The per-hike snapshots are deliberately left alone.** This is
    /// deselection, and a widget pinned to a trail is not following the
    /// selection — taking its route away because the hiker looked at
    /// something else is the bug #468 was filed about, in a new place. What
    /// bounds that set is ``pruneTrailSnapshots(keeping:)``, which is driven
    /// by what is on a screen rather than by what is selected.
    public static func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
        clearBasemaps()
    }

    // MARK: The hike catalogue

    /// Every saved hike, for a process that has no store to ask — see
    /// ``SharedHikeCatalogue``.
    ///
    /// ``SharedHikeCatalogue/empty`` rather than `nil` for a container that
    /// cannot be resolved or a file that has never been written. Every caller
    /// is a picker, and a picker with nothing to offer is the same drawing
    /// either way; handing them an optional would spread a decision none of
    /// them can act on, which is the argument ``load()`` already makes.
    public static func loadHikeCatalogue() -> SharedHikeCatalogue {
        guard let catalogueURL, let data = try? Data(contentsOf: catalogueURL) else {
            return .empty
        }
        return decodeUnversioned(
            SharedHikeCatalogue.self,
            from: data,
            named: catalogueFileName
        ) ?? .empty
    }

    /// Unversioned, like the basemap manifest and unlike the snapshots, and
    /// for the same reason: this is **derived state**. A catalogue this build
    /// cannot decode reads as empty, the app rewrites it on its next change,
    /// and the cost in between is a picker with no rows — where the same
    /// failure in a snapshot would be a blank widget with nothing to rebuild
    /// it from.
    public static func saveHikeCatalogue(_ catalogue: SharedHikeCatalogue) {
        guard let catalogueURL, let data = try? JSONEncoder().encode(catalogue) else { return }
        try? data.write(to: catalogueURL, options: .atomic)
    }

    // MARK: Per-hike trail snapshots

    /// The snapshot for one hike, for a widget pinned to a trail that is not
    /// the selected one.
    ///
    /// `nil` means **this hike has no snapshot on this device**, which is an
    /// ordinary state rather than a failure: the app only keeps snapshots for
    /// the trails something is actually showing — see
    /// ``pruneTrailSnapshots(keeping:)`` — so a widget configured for a hike
    /// the app has not published yet draws its empty state until it has.
    public static func loadTrailSnapshot(for hikeID: UUID) -> SharedTrailSnapshot? {
        guard let url = trailSnapshotURL(for: hikeID),
              let data = try? Data(contentsOf: url) else { return nil }
        let snapshot = decode(
            SharedTrailSnapshot.self,
            from: data,
            named: url.lastPathComponent
        )
        // Guarded rather than trusted, the same way ``loadBasemapSet(for:)``
        // checks its manifest's `hikeID`: the file name is a claim about the
        // contents and a mismatched pair is a stale write, not a trail to
        // draw for somebody.
        return snapshot?.hikeID == hikeID ? snapshot : nil
    }

    public static func saveTrailSnapshot(_ snapshot: SharedTrailSnapshot) {
        guard let directory = trailSnapshotDirectoryURL,
              let url = trailSnapshotURL(for: snapshot.hikeID),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    /// Deletes every per-hike snapshot except these, which is what keeps the
    /// set bounded by *what is on a screen* rather than by the library.
    ///
    /// Writing a snapshot for every hike in a library of three hundred is not
    /// the design; writing one for each hike a placed widget asks for, plus
    /// the selected one, is. The app learns that set from
    /// `WidgetCenter.getCurrentConfigurations` and hands it here.
    public static func pruneTrailSnapshots(keeping hikeIDs: Set<UUID>) {
        guard let directory = trailSnapshotDirectoryURL,
              let contents = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: nil
              ) else { return }
        let kept = Set(hikeIDs.map { "\($0.uuidString).json" })
        for url in contents where !kept.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Removes one hike's snapshot — what a deleted hike leaves behind.
    public static func clearTrailSnapshot(for hikeID: UUID) {
        guard let url = trailSnapshotURL(for: hikeID) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Live recording

    public static func loadRecording() -> SharedRecordingSnapshot? {
        guard let recordingFileURL,
              let data = try? Data(contentsOf: recordingFileURL)
        else { return nil }
        return decode(SharedRecordingSnapshot.self, from: data, named: recordingFileName)
    }

    public static func saveRecording(
        _ snapshot: SharedRecordingSnapshot
    ) throws {
        guard let recordingFileURL, let pendingRecordingFixStore
        else { throw SharedRecordingStoreError.containerUnavailable }
        try pendingRecordingFixStore.saveRecording(
            snapshot,
            to: recordingFileURL
        )
    }

    public static func clearRecording(sessionID: UUID? = nil) throws {
        guard let recordingFileURL, let pendingRecordingFixStore
        else { throw SharedRecordingStoreError.containerUnavailable }
        try pendingRecordingFixStore.clearRecordingState(
            recordingURL: recordingFileURL,
            sessionID: sessionID
        )
    }

    @discardableResult public static func appendPendingRecordingFix(
        _ fix: SharedRecordingFix
    ) throws -> Bool {
        guard let pendingRecordingFixStore, let recordingFileURL
        else { throw SharedRecordingStoreError.containerUnavailable }
        return try pendingRecordingFixStore.append(
            fix,
            validatingRecordingAt: recordingFileURL
        )
    }

    public static func loadPendingRecordingFixes() throws
        -> [SharedRecordingFix] {
        guard let pendingRecordingFixStore else { throw SharedRecordingStoreError.containerUnavailable }
        return try pendingRecordingFixStore.load()
    }

    public static func removePendingRecordingFixes(
        ids: Set<UUID>
    ) throws {
        guard let pendingRecordingFixStore else { throw SharedRecordingStoreError.containerUnavailable }
        try pendingRecordingFixStore.remove(ids: ids)
    }

    public static func claimRecordingWidgetSample(
        sessionID: UUID,
        minimumInterval: TimeInterval,
        at date: Date = .now
    ) throws -> Bool {
        guard let pendingRecordingFixStore else { throw SharedRecordingStoreError.containerUnavailable }
        return try pendingRecordingFixStore.claimSample(
            sessionID: sessionID,
            at: date,
            minimumInterval: minimumInterval
        )
    }

    public static func clearPendingRecordingFixes(
        sessionID: UUID? = nil
    ) throws {
        guard let pendingRecordingFixStore else { throw SharedRecordingStoreError.containerUnavailable }
        try pendingRecordingFixStore.clear(sessionID: sessionID)
    }

    // MARK: Decoding

    /// Reads only the current format, reporting version and decoding failures.
    private static func decode<Payload: SharedPayload>(
        _ type: Payload.Type,
        from data: Data,
        named file: String
    ) -> Payload? {
        let announced = (try? JSONDecoder().decode(SharedPayloadVersionPeek.self, from: data))?.schemaVersion
        if let announced, announced != Payload.currentSchemaVersion {
            SharedStoreDiagnostics.report(
                .unsupportedSchemaVersion(
                    file: file,
                    found: announced,
                    supported: Payload.currentSchemaVersion
                )
            )
            return nil
        }
        return decodeUnversioned(type, from: data, named: file)
    }

    /// The decode half on its own, for payloads that carry no version.
    private static func decodeUnversioned<Payload: Decodable>(
        _ type: Payload.Type,
        from data: Data,
        named file: String
    ) -> Payload? {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            SharedStoreDiagnostics.report(
                .decodeFailed(file: file, detail: SharedStoreDiagnostics.describe(error))
            )
            return nil
        }
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
    ///
    /// Carries no ``SharedPayload/schemaVersion``, and does not need one. This
    /// manifest is derived state, not a record of the walk: the renderer
    /// already treats a `nil` here and a missing image identically, and
    /// re-renders. A schema change costs one render, and the next read is
    /// correct — where the same change to a snapshot costs a blank widget
    /// until the app next publishes. It is still routed through the
    /// diagnostic, because a manifest that can never be decoded is re-rendered
    /// on every timeline reload forever, and a battery cost that presents as
    /// nothing at all is worth being able to see.
    public static func loadBasemapSet(for hikeID: UUID) -> TrailBasemapSet? {
        guard let basemapSetURL, let data = try? Data(contentsOf: basemapSetURL),
              let set = decodeUnversioned(TrailBasemapSet.self, from: data, named: basemapSetFileName),
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
