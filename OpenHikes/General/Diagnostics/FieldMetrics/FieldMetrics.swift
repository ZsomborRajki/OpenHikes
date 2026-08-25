//
//  FieldMetrics.swift
//  OpenHikes
//
//  The MetricKit subscriber, and the only thing in the app that talks to
//  `MXMetricManager`.
//
//  Registered once from `OpenHikesModel`. Not `#if DEBUG` — and that is the
//  whole point of it. Every other file in `Diagnostics/` compiles to nothing
//  in Release, because `RenderSignpost`, `PerformanceLog` and
//  `MainThreadWatchdog` measure a build nobody ships. MetricKit measures the
//  build everybody ships, on the walk it was written for, and a Debug-only
//  MetricKit integration would report on a configuration that never leaves
//  this machine.
//
//  What it costs when it is doing nothing, which is almost always: one
//  `NSObject` retained for the lifetime of the process and one entry in a
//  framework's subscriber list. Payloads arrive at most once a day, on a
//  background queue, and are reduced and written from there.
//
//  Three limits worth knowing before reading a number it produces:
//
//  1. **Nothing arrives on the Simulator.** `mxSignpost` compiles to a
//     "NO_METRICS" placeholder there (`MXSignpost_Private.h` branches on
//     `TARGET_OS_SIMULATOR`), and payload delivery is a device behaviour. Use
//     Xcode's *Debug ▸ Simulate MetricKit Payloads* against a device to
//     exercise this path.
//  2. **The first real payload is a day away.** MetricKit aggregates over 24
//     hours. This is not an instrument you iterate against; it is one you read
//     after a weekend.
//  3. **A payload describes a device, not a hike.** Everything is cumulative
//     over the period, so a day containing one six-hour walk and a day
//     containing six one-hour walks report the same totals. ``FieldSignpost``
//     exists to put a boundary inside that, which is the only way an
//     individual recording gets its own CPU figure.
//

import Foundation
import MetricKit
import os
import Synchronization

nonisolated final class FieldMetrics: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    private static let logger = Logger(
        subsystem: "OpenHikes",
        category: "FieldMetrics"
    )

    static let shared = FieldMetrics()

    private let store: FieldMetricsStore
    /// Idempotent registration, because a background relaunch runs
    /// `OpenHikesModel`'s initializer again and `addSubscriber` has no
    /// documented behaviour for a duplicate registration. `compareExchange`
    /// states the whole intent in one operation, matching
    /// ``MainThreadWatchdog``'s start guard.
    private let isRegistered = Atomic<Bool>(false)

    /// `@unchecked Sendable` with no unguarded mutable state: the store is an
    /// actor, the registration flag is atomic, and `MXMetricManager` is the
    /// only other thing touched. The annotation is needed because
    /// `MXMetricManagerSubscriber` inherits from `NSObjectProtocol`, which
    /// carries no `Sendable` conformance.
    init(store: FieldMetricsStore = .shared) {
        self.store = store
        super.init()
    }

    func register() {
        let (claimed, _) = isRegistered.compareExchange(
            expected: false,
            desired: true,
            ordering: .relaxed
        )
        guard claimed else { return }
        MXMetricManager.shared.add(self)
        Self.logger.notice("Subscribed to MetricKit.")
    }

    func unregister() {
        let (claimed, _) = isRegistered.compareExchange(
            expected: true,
            desired: false,
            ordering: .relaxed
        )
        guard claimed else { return }
        MXMetricManager.shared.remove(self)
    }

    // MARK: MXMetricManagerSubscriber

    /// Invoked on a background queue. Kept there: reducing a payload reads a
    /// few dozen fields and serialises some JSON, which is neither expensive
    /// enough to need a queue of its own nor cheap enough to be worth putting
    /// on the main actor on the way to a file.
    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            let report = FieldMetricsReport(
                receivedAt: Date(),
                periodStart: payload.timeStampBegin,
                periodEnd: payload.timeStampEnd,
                appVersion: payload.latestApplicationVersion,
                content: .metrics(FieldMetricsDigest(payload)),
                appBuild: payload.metaData?.applicationBuildVersion,
                osVersion: payload.metaData?.osVersion,
                deviceType: payload.metaData?.deviceType,
                bundleIdentifier: payload.metaData?.bundleIdentifier,
                isTestFlight: payload.metaData?.isTestFlightApp ?? false,
                rawJSON: payload.jsonRepresentation()
            )
            Task { [store] in await store.save(report) }
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let entries = FieldDiagnosticDigest.entries(in: payload)
            guard !entries.isEmpty else { continue }
            let report = FieldMetricsReport(
                receivedAt: Date(),
                periodStart: payload.timeStampBegin,
                periodEnd: payload.timeStampEnd,
                appVersion: entries.first?.appVersion ?? "unknown",
                content: .diagnostics(entries),
                rawJSON: payload.jsonRepresentation()
            )
            Task { [store] in await store.save(report) }
        }
    }
}
