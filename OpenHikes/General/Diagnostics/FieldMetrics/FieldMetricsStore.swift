//
//  FieldMetricsStore.swift
//  OpenHikes
//
//  Where MetricKit reports live once they arrive, which is on this device and
//  nowhere else.
//
//  `CODE_REVIEW.md` states the position this file implements: "For battery
//  telemetry, prefer native Instruments, signposts, and current MetricKit
//  reporting rather than an analytics SDK that adds its own network and
//  background cost." A hiking app that opens a connection to report on how
//  carefully it avoids opening connections would be a joke at its own expense,
//  so nothing here uploads anything. A report is written to Application
//  Support, shown in Settings, and leaves the device only if the walker picks
//  it up and shares it deliberately.
//
//  Two properties the design has to hold:
//
//  * **Bounded.** A payload arrives roughly daily, forever, and a diagnostic
//    payload carries call-stack trees that are not small. An unbounded log of
//    them is a disk leak with a slow fuse, and this app already has two
//    reclaim sweeps precisely because unowned files are how it has been bitten
//    before. ``retentionLimit`` and ``byteLimit`` are both enforced on write.
//  * **Off the main thread.** MetricKit delivers on a background queue and
//    this keeps it there. Nothing in this file hops to the main actor; the
//    view layer reads through an explicit async load.
//

import Foundation
import os

/// One stored report — either a metric payload's digest or the diagnostics
/// found in a diagnostic payload. The two arrive through different callbacks
/// and describe different things, but they share a list in the UI and a
/// retention budget on disk, so they share a type.
nonisolated struct FieldMetricsReport: Codable, Sendable, Equatable, Identifiable {
    enum Content: Codable, Sendable, Equatable {
        case metrics(FieldMetricsDigest)
        case diagnostics([FieldDiagnosticDigest])
    }

    var id: UUID
    /// When this process received the payload — not when the measured period
    /// happened. MetricKit delivers a day late, and conflating the two makes
    /// "yesterday's hike" impossible to find.
    var receivedAt: Date
    var periodStart: Date
    var periodEnd: Date
    var appVersion: String
    var appBuild: String?
    var osVersion: String?
    var deviceType: String?
    /// iOS 26 finally names which bundle a payload came from. This app embeds
    /// a widget extension, and an extension's metrics are not the app's — a
    /// figure attributed to the wrong one is worse than no figure.
    var bundleIdentifier: String?
    var isTestFlight: Bool
    var content: Content
    /// The framework's own JSON, kept verbatim so an exported report can be
    /// read by something that knows more about MetricKit than this app does.
    /// The digest above is a summary and deliberately lossy.
    var rawJSON: Data?

    init(
        receivedAt: Date,
        periodStart: Date,
        periodEnd: Date,
        appVersion: String,
        content: Content,
        id: UUID = UUID(),
        appBuild: String? = nil,
        osVersion: String? = nil,
        deviceType: String? = nil,
        bundleIdentifier: String? = nil,
        isTestFlight: Bool = false,
        rawJSON: Data? = nil
    ) {
        self.id = id
        self.receivedAt = receivedAt
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.osVersion = osVersion
        self.deviceType = deviceType
        self.bundleIdentifier = bundleIdentifier
        self.isTestFlight = isTestFlight
        self.content = content
        self.rawJSON = rawJSON
    }

    var digest: FieldMetricsDigest? {
        if case let .metrics(digest) = content { return digest }
        return nil
    }

    var diagnostics: [FieldDiagnosticDigest] {
        if case let .diagnostics(entries) = content { return entries }
        return []
    }
}

/// A bounded, on-device list of received reports, newest first.
///
/// An actor rather than a lock-guarded singleton because every operation here
/// is file I/O: there is no fast path worth protecting with a `Mutex`, and the
/// serialization an actor gives is exactly what stops a delivery and a delete
/// from interleaving on the same file.
actor FieldMetricsStore {
    /// Roughly a fortnight of daily payloads. Long enough that a walker can
    /// hike at the weekend and still find the report on the following one;
    /// short enough that the directory has a ceiling anyone can reason about.
    static let retentionLimit = 16
    /// A hard stop independent of the count, because a diagnostic payload full
    /// of call-stack trees is orders of magnitude larger than a metrics digest
    /// and sixteen of those is not the same amount of disk as sixteen of these.
    static let byteLimit = FieldMetricsStore.megabyteBudget * FieldMetricsStore.bytesPerMegabyte

    private static let logger = Logger(
        subsystem: "OpenHikes",
        category: "FieldMetrics"
    )
    private static let fileExtension = "json"
    private static let bytesPerMegabyte = 1_048_576
    private static let megabyteBudget = 4

    /// Reports live in Application Support, except under UI automation, which
    /// gets a directory of its own — a seeded report must not survive into the
    /// next scenario, and must never be mistaken for one a real device left
    /// behind. See ``AppLaunchEnvironment/fieldMetricsDirectory()``.
    static let shared = FieldMetricsStore(
        directory: AppLaunchEnvironment.fieldMetricsDirectory()
            ?? URL.applicationSupportDirectory
            .appending(path: "FieldMetrics", directoryHint: .isDirectory)
    )

    private let directory: URL
    private let retentionLimit: Int
    private let byteLimit: Int

    /// `directory` is injectable so a test gets its own, for the same reason
    /// `TileSandbox` exists: the singleton belongs to the app and suites run in
    /// parallel.
    init(
        directory: URL = URL.applicationSupportDirectory
            .appending(path: "FieldMetrics", directoryHint: .isDirectory),
        retentionLimit: Int = FieldMetricsStore.retentionLimit,
        byteLimit: Int = FieldMetricsStore.byteLimit
    ) {
        self.directory = directory
        self.retentionLimit = retentionLimit
        self.byteLimit = byteLimit
    }

    /// Newest first. A file that no longer decodes — written by an older shape
    /// of ``FieldMetricsReport`` — is skipped rather than thrown, because a
    /// diagnostics screen that fails to open is strictly worse than one
    /// missing a stale entry, and there is nothing here worth migrating.
    func reports() -> [FieldMetricsReport] {
        stored().map(\.report)
    }

    @discardableResult func save(_ report: FieldMetricsReport) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(report)
            let destination = directory.appending(
                path: "\(report.id.uuidString).\(Self.fileExtension)",
                directoryHint: .notDirectory
            )
            try data.write(to: destination, options: .atomic)
            enforceLimits()
            return true
        } catch {
            Self.logger.error(
                "Could not store field metrics report: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    func deleteAll() {
        for entry in stored() {
            try? FileManager.default.removeItem(at: entry.url)
        }
    }

    func delete(_ id: UUID) {
        guard let entry = stored().first(where: { entry in entry.report.id == id }) else { return }
        try? FileManager.default.removeItem(at: entry.url)
    }

    /// Writes every stored report to one JSON file in the caller's directory
    /// and returns it, for the share sheet. Returns `nil` when there is
    /// nothing to export — a share sheet offering an empty file is a bug
    /// report waiting to happen.
    func exportArchive(into directory: URL, named name: String) -> URL? {
        let reports = stored().map(\.report)
        guard !reports.isEmpty else { return nil }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(reports)
            let destination = directory.appending(
                path: "\(name).\(Self.fileExtension)",
                directoryHint: .notDirectory
            )
            try data.write(to: destination, options: .atomic)
            return destination
        } catch {
            Self.logger.error(
                "Could not export field metrics: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    // MARK: Private

    private struct Entry {
        let url: URL
        let report: FieldMetricsReport
        let byteCount: Int
    }

    private func stored() -> [Entry] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return urls
            .filter { $0.pathExtension == Self.fileExtension }
            .compactMap { url -> Entry? in
                guard let data = try? Data(contentsOf: url),
                      let report = try? decoder.decode(FieldMetricsReport.self, from: data)
                else { return nil }
                return Entry(url: url, report: report, byteCount: data.count)
            }
            .sorted { $0.report.receivedAt > $1.report.receivedAt }
    }

    /// Trims oldest-first against both budgets. Runs after every write rather
    /// than on a schedule: this directory only ever grows when something is
    /// added to it, so the moment of the write is the only moment it can
    /// exceed a limit.
    private func enforceLimits() {
        var entries = stored()
        while entries.count > retentionLimit, let oldest = entries.popLast() {
            try? FileManager.default.removeItem(at: oldest.url)
        }
        var total = entries.reduce(0) { $0 + $1.byteCount }
        // The newest report is kept even if it alone exceeds the budget: the
        // alternative is a delivery that silently discards itself, which looks
        // exactly like MetricKit never having reported at all.
        while total > byteLimit, entries.count > 1, let oldest = entries.popLast() {
            try? FileManager.default.removeItem(at: oldest.url)
            total -= oldest.byteCount
        }
    }
}
