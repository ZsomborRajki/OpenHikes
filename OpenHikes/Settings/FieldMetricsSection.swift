//
//  FieldMetricsSection.swift
//  OpenHikes
//
//  The Settings section that shows what MetricKit reported, and lets the
//  walker do the only two things worth doing with it: read it, or hand it to
//  somebody.
//
//  This screen exists because of where the data is. Nothing uploads a report,
//  so unless it can be read on the phone that produced it, it may as well not
//  be collected — and the phones that produce the interesting numbers are
//  exactly the ones nobody has a debugger attached to: a walker's, six hours
//  into a hike, in a valley, on 4% battery.
//
//  Presentation rules it follows, both from this repository's conventions:
//
//  * Every row is *one* accessibility element with a label and a value, like
//    `HikeRow` and the storage rows above it. A screen of forty numbers read
//    out as eighty fragments is not a diagnostics screen, it is a punishment.
//  * A number MetricKit did not report is drawn as "Not reported" rather than
//    as a zero. The difference between "the GPS never stepped down" and "this
//    payload contained no location metrics" is the entire value of Finding
//    E1's follow-up, and a dash would erase it.
//

import SwiftUI

struct FieldMetricsSection: View {
    @State private var reports: [FieldMetricsReport] = []
    @State private var hasLoaded = false

    var body: some View {
        Section {
            if !hasLoaded {
                row(title: "Reports", value: "Loading…")
            } else if reports.isEmpty {
                row(title: "Reports", value: "None yet")
            } else {
                ForEach(reports) { report in
                    NavigationLink {
                        FieldMetricsReportView(report: report)
                    } label: {
                        reportRow(report)
                    }
                    .accessibilityIdentifier("field-metrics-report-row")
                }
                NavigationLink {
                    FieldMetricsExportView()
                } label: {
                    Label("Share Diagnostics", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("field-metrics-export-link")
            }
        } header: {
            Text("Device Reports")
        } footer: {
            Text(
                "iOS measures this app's battery, launch and reliability once a day and"
                + " reports it here. Nothing is uploaded — these stay on your iPhone until"
                + " you share them. The first report appears about a day after installing,"
                + " and only on a real device."
            )
        }
        .task {
            reports = await FieldMetricsStore.shared.reports()
            hasLoaded = true
        }
    }

    private func reportRow(_ report: FieldMetricsReport) -> some View {
        let title: String
        switch report.content {
        case .metrics:
            title = "Daily metrics"
        case let .diagnostics(entries):
            title = entries.count == 1
                ? entries[0].kind.title
                : "\(entries.count) diagnostics"
        }
        let subtitle = report.periodEnd.formatted(date: .abbreviated, time: .shortened)
        return VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(subtitle)
    }

    private func row(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

// MARK: - One report

struct FieldMetricsReportView: View {
    let report: FieldMetricsReport

    var body: some View {
        List {
            Section {
                MetricRow("Period", FieldMetricsFormat.period(report))
                MetricRow("Received", report.receivedAt.formatted(date: .abbreviated, time: .shortened))
                MetricRow("App version", FieldMetricsFormat.version(report))
                if let osVersion = report.osVersion {
                    MetricRow("iOS", osVersion)
                }
                if let deviceType = report.deviceType {
                    MetricRow("Device", deviceType)
                }
                // Only meaningful because this app embeds a widget: without it
                // an extension's numbers and the app's are indistinguishable.
                if let bundleIdentifier = report.bundleIdentifier {
                    MetricRow("Bundle", bundleIdentifier)
                }
            } header: {
                Text("Report")
            }

            switch report.content {
            case let .metrics(digest):
                metricsSections(digest)
            case let .diagnostics(entries):
                diagnosticsSection(entries)
            }
        }
        .navigationTitle("Report")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("field-metrics-report-screen")
    }

    @ViewBuilder
    private func metricsSections(_ digest: FieldMetricsDigest) -> some View {
        energySection(digest)
        accuracySection(digest)
        responsivenessSection(digest)
        exitSection(digest)
        storageSection(digest)
        signpostSection(digest)
    }

    @ViewBuilder
    private func energySection(_ digest: FieldMetricsDigest) -> some View {
        Section {
            MetricRow("Foreground", FieldMetricsFormat.duration(digest.foregroundSeconds))
            MetricRow("Background", FieldMetricsFormat.duration(digest.backgroundSeconds))
            MetricRow(
                "Background with GPS",
                FieldMetricsFormat.duration(digest.backgroundLocationSeconds)
            )
            MetricRow("CPU", FieldMetricsFormat.duration(digest.cpuSeconds))
            MetricRow(
                "CPU per active hour",
                FieldMetricsFormat.duration(digest.cpuSecondsPerActiveHour)
            )
            MetricRow(
                "Time in a pocket",
                FieldMetricsFormat.percentage(digest.backgroundLocationShare)
            )
        } header: {
            Text("Energy")
        } footer: {
            Text(
                "\"Background with GPS\" is the part of a hike spent with the screen off and"
                + " the recording running, which is where nearly all of a walk's battery goes."
                + " \"Time in a pocket\" compares it against the app's whole lifetime and is"
                + " capped at 100%: a location session that spans a suspension is charged in"
                + " full, while foreground and background time advance only while the app is"
                + " resident, so the two are measured on different clocks."
            )
        }

    }

    @ViewBuilder
    private func accuracySection(_ digest: FieldMetricsDigest) -> some View {
        if let accuracy = digest.locationAccuracy {
            Section {
                MetricRow("Best", FieldMetricsFormat.duration(accuracy.bestSeconds))
                MetricRow(
                    "Ten metres",
                    FieldMetricsFormat.duration(accuracy.nearestTenMetersSeconds)
                )
                MetricRow(
                    "Hundred metres",
                    FieldMetricsFormat.duration(accuracy.hundredMetersSeconds)
                )
                MetricRow(
                    "Spent conserving",
                    FieldMetricsFormat.percentage(accuracy.conservingShare)
                )
            } header: {
                Text("GPS Accuracy")
            } footer: {
                Text(
                    "OpenHikes drops to ten-metre accuracy in Low Power Mode, or when the"
                    + " iPhone is too warm. \"Spent conserving\" is how much of this period"
                    + " that actually saved."
                )
            }
        }

    }

    @ViewBuilder
    private func responsivenessSection(_ digest: FieldMetricsDigest) -> some View {
        Section {
            HistogramRow("Time to first draw", digest.timeToFirstDraw, unit: "ms")
            HistogramRow("Until the map appears", digest.extendedLaunch, unit: "ms")
            HistogramRow("Resume", digest.resumeTime, unit: "ms")
            HistogramRow("Hangs", digest.applicationHangTime, unit: "ms")
            MetricRow("Hitches", FieldMetricsFormat.ratio(digest.hitchTimeRatio))
            MetricRow("Scroll hitches", FieldMetricsFormat.ratio(digest.scrollHitchTimeRatio))
        } header: {
            Text("Responsiveness")
        }

    }

    @ViewBuilder
    private func exitSection(_ digest: FieldMetricsDigest) -> some View {
        if let exits = digest.exits {
            Section {
                MetricRow("Unexpected exits", "\(exits.unexpectedTotal)")
                MetricRow("Out of memory, backgrounded", "\(exits.backgroundMemoryLimitExits)")
                MetricRow("Memory pressure", "\(exits.backgroundMemoryPressureExits)")
                MetricRow("Background task timeout", "\(exits.backgroundTaskTimeoutExits)")
                MetricRow("Suspended holding a lock", "\(exits.backgroundLockedFileExits)")
                MetricRow("Watchdog, on screen", "\(exits.foregroundWatchdogExits)")
            } header: {
                Text("Terminations")
            } footer: {
                Text(
                    "A backgrounded recording that runs out of memory loses the hike."
                    + " Anything above zero here is worth reporting."
                )
            }
        }

    }

    @ViewBuilder
    private func storageSection(_ digest: FieldMetricsDigest) -> some View {
        Section {
            MetricRow("Peak memory", FieldMetricsFormat.bytes(digest.peakMemoryBytes))
            MetricRow(
                "Average suspended",
                FieldMetricsFormat.bytes(digest.averageSuspendedMemoryBytes)
            )
            MetricRow("Written to disk", FieldMetricsFormat.bytes(digest.logicalWriteBytes))
            MetricRow("Maps and photos on disk", FieldMetricsFormat.bytes(digest.dataFileBytes))
            MetricRow("Caches on disk", FieldMetricsFormat.bytes(digest.cacheFolderBytes))
        } header: {
            Text("Memory and Storage")
        }

    }

    @ViewBuilder
    private func signpostSection(_ digest: FieldMetricsDigest) -> some View {
        if !digest.signposts.isEmpty {
            Section {
                ForEach(digest.signposts) { signpost in
                    SignpostRow(signpost)
                }
            } header: {
                Text("Measured Activities")
            } footer: {
                Text(
                    "What a whole recording, an offline download or an import cost on this"
                    + " iPhone — the only place those can be measured honestly."
                )
            }
        }
    }

    private func diagnosticsSection(_ entries: [FieldDiagnosticDigest]) -> some View {
        Section {
            ForEach(entries) { entry in
                MetricRow(entry.kind.title, FieldMetricsFormat.diagnosticValue(entry))
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text(
                "Call stacks are stored with each entry and included when you share"
                + " diagnostics."
            )
        }
    }
}

// MARK: - Rows

/// A label/value pair, hidden from VoiceOver as two pieces and exposed as one.
private struct MetricRow: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

/// A histogram, reduced to the two numbers worth reading at a glance.
///
/// Both are upper bounds — see ``HistogramSummary/upperBound(atQuantile:)`` —
/// and the row says so, because a median that is really "the top of the bucket
/// the median fell in" being read as a median is how a budget gets set against
/// a number that was never measured.
private struct HistogramRow: View {
    let title: String
    let summary: HistogramSummary?
    let unit: String

    init(_ title: String, _ summary: HistogramSummary?, unit: String) {
        self.title = title
        self.summary = summary
        self.unit = unit
    }

    var body: some View {
        MetricRow(title, FieldMetricsFormat.histogram(summary, unit: unit))
    }
}

private struct SignpostRow: View {
    let signpost: SignpostDigest

    init(_ signpost: SignpostDigest) {
        self.signpost = signpost
    }

    var body: some View {
        let value = FieldMetricsFormat.signpostValue(signpost)
        return VStack(alignment: .leading, spacing: 3) {
            Text(FieldMetricsFormat.signpostTitle(signpost.name))
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(FieldMetricsFormat.signpostTitle(signpost.name))
        .accessibilityValue(value)
    }
}

// MARK: - Export

/// The share step, on its own screen.
///
/// The archive is written to a temporary file first rather than shared as an
/// in-memory `Data`: a share sheet handed raw bytes offers "Copy" and little
/// else, whereas a file with a name and a `.json` extension can go to Files,
/// Mail or a bug tracker, which is the only reason anyone would want it.
struct FieldMetricsExportView: View {
    @State private var archive: URL?
    @State private var isPreparing = true

    var body: some View {
        List {
            Section {
                if isPreparing {
                    Text("Preparing…")
                        .foregroundStyle(.secondary)
                } else if let archive {
                    ShareLink(item: archive) {
                        Label("Share Diagnostics File", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("field-metrics-share-button")
                } else {
                    Text("There is nothing to share yet.")
                        .foregroundStyle(.secondary)
                }

                Button(role: .destructive) {
                    Task {
                        await FieldMetricsStore.shared.deleteAll()
                        archive = nil
                    }
                } label: {
                    Text("Delete All Reports")
                }
                .accessibilityIdentifier("field-metrics-delete-button")
            } footer: {
                Text(
                    "The file contains battery, launch and reliability measurements for this"
                    + " app, plus call stacks for any crash or hang. It contains no location"
                    + " data, no hikes and no photos."
                )
            }
        }
        .navigationTitle("Share Diagnostics")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("field-metrics-export-screen")
        .task {
            archive = await FieldMetricsStore.shared.exportArchive(
                into: FileManager.default.temporaryDirectory,
                named: "OpenHikes-Diagnostics"
            )
            isPreparing = false
        }
    }
}
