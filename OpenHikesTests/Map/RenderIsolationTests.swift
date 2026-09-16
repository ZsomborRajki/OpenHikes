//
//  RenderIsolationTests.swift
//  OpenHikesTests
//
//  The app's central performance idea (the "Preserve render isolation"
//  convention in `.github/copilot-instructions.md`) is that high-frequency
//  state lives in `@Observable` reference types that the owning views never
//  read in their own `body`, so a GPS fix or a sheet drag moves one
//  annotation instead of re-diffing a view tree. That only holds if two
//  things are true, and neither is checkable by reading the code:
//
//  * an observer really is notified per write — including writes that don't
//    change the value, which is why the coordinate-typed publishers compare
//    before assigning (`RouteHighlight.move(to:)`, `LocationManager.publish`);
//    and
//  * observing one property really doesn't wake observers of another.
//
//  Neither is true unconditionally, and the two halves point opposite ways:
//  Observation *does* filter a write that compares equal on an `Equatable`
//  property, and SwiftData's `@Model` does *not*. Several suites' zero
//  assertions are really assertions about one or the other, so both are pinned
//  in `ObservationCostTests`, one of the four files split out of this one.
//
//  So the tests here pin the *notification* behaviour these views are tuned
//  against; `RouteHighlightTests`, `LocationPublishingTests` and
//  `DownloadProgressTests` check the producers that feed them at high
//  frequency, and share the `ObservationCounter` below.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import SwiftUI
import Testing

/// Counts `withObservationTracking` notifications, re-registering after each
/// one exactly the way `MapView.Coordinator` does.
final class ObservationCounter {
    private(set) var count = 0
    private var track: (() -> Void)?

    /// - Parameter read: the property access to observe, mirroring what the
    ///   corresponding view or coordinator reads.
    init(_ read: @escaping () -> Void) {
        track = { [weak self] in
            withObservationTracking {
                read()
            } onChange: {
                Task { @MainActor in
                    guard let self else { return }
                    self.count += 1
                    self.track?()
                }
            }
        }
        track?()
    }

    /// Lets the queued re-registrations run. Observation delivers its change
    /// callback synchronously but the re-registration hops through a `Task`,
    /// same as in the app.
    ///
    /// Deliberately without a condition — the one wait in these suites that
    /// stays best-effort. Half its callers wait for the count to rise and the
    /// other half assert that it did *not*, and "the count has reached N"
    /// would satisfy the first kind the instant the notification it expects
    /// lands, returning before a *spurious* extra one could arrive. That turns
    /// the regression this counter exists to catch into a pass, which is worse
    /// than the load-sensitivity naming it would remove.
    func settle() async {
        await settleDelegateHop()
    }
}

@Suite("Recording isolation")
struct RecordingIsolationTests {
    @Test("a fix wakes only the recording leaves that read its state")
    func recordingStateIsSplitByConcern() async {
        let stats = RecordingStats()
        let trace = RecordingTrace()
        let distanceCounter = ObservationCounter { _ = stats.distanceMeters }
        let pointCounter = ObservationCounter { _ = stats.pointCount }
        let traceCounter = ObservationCounter { _ = trace.revision }
        await distanceCounter.settle()

        stats.distanceMeters = 42
        trace.append(
            CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86)
        )
        await distanceCounter.settle()

        #expect(distanceCounter.count == 1)
        #expect(pointCounter.count == 0)
        #expect(traceCounter.count == 1)
    }

    @Test("a live match revises only the provisional trace generation")
    func liveMatchReplacesTheProvisionalTail() {
        let trace = RecordingTrace()
        let generation = trace.generation
        trace.append(
            CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86),
            provisional: true
        )
        trace.append(
            CLLocationCoordinate2D(latitude: 47.6302, longitude: 12.86),
            provisional: true
        )

        #expect(trace.applyLiveMatch(
            committing: [
                CLLocationCoordinate2D(
                    latitude: 47.63,
                    longitude: 12.8599
                ),
            ],
            provisional: [
                CLLocationCoordinate2D(
                    latitude: 47.63,
                    longitude: 12.8599
                ),
                CLLocationCoordinate2D(
                    latitude: 47.6302,
                    longitude: 12.8599
                ),
            ],
            expectedGeneration: generation
        ))
        #expect(trace.tail.count == 2)
        #expect(trace.tail.allSatisfy { coord in
            abs(coord.longitude - 12.8599) < 0.000001
        })

        trace.replace(with: [])
        #expect(!trace.applyLiveMatch(
            committing: [],
            provisional: [
                CLLocationCoordinate2D(
                    latitude: 47.64,
                    longitude: 12.85
                ),
            ],
            expectedGeneration: generation
        ))
        #expect(trace.tail.isEmpty)
    }

    /// `RecordingView.body` and the whole hikes sheet (via
    /// `HikeRecorder.isActive`) read `phase`, and the accepted-fix path in
    /// `HikeRecorder` touches it on every fix. Those bodies are budgeted at
    /// one invalidation per phase change, not one per fix, so a fix that
    /// leaves the phase alone must wake nothing.
    @Test("a fix that doesn't change the phase doesn't wake a body reading it")
    func steadyRecordingDoesNotInvalidatePhaseReaders() async throws {
        let container = try Fixture.modelContainer()
        let source = IsolationRecordingSource()
        let clock = TestClock()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "recording-isolation-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = HikeRecorder(
            container: container,
            source: source,
            journalDirectory: directory,
            clock: clock.read,
            journalFlushDelay: .zero,
            automaticallyRecovers: false
        )
        await recorder.start()

        let phaseCounter = ObservationCounter { _ = recorder.phase }
        await phaseCounter.settle()

        for step in 1...5 {
            clock.advance(by: 10)
            source.deliver(
                CLLocation(
                    coordinate: CLLocationCoordinate2D(
                        latitude: 47.63 + Double(step) * 0.0002,
                        longitude: 12.86
                    ),
                    altitude: 600,
                    horizontalAccuracy: 8,
                    verticalAccuracy: 5,
                    course: 0,
                    speed: 1,
                    timestamp: clock.now
                )
            )
            await phaseCounter.settle()
        }

        #expect(recorder.stats.pointCount == 5)
        #expect(
            phaseCounter.count == 1,
            "only waitingForFix → recording; the four fixes after it change nothing"
        )
    }
}

/// The minimum `RecordingLocationSource` needed to push fixes at a recorder.
private final class IsolationRecordingSource: RecordingLocationSource {
    var authorization: RecordingLocationAuthorization = .authorized
    var hasFullAccuracy = true
    private weak var delegateObject: AnyObject?

    var sourceDelegate: CLLocationManagerDelegate? {
        get { delegateObject as? CLLocationManagerDelegate }
        set { delegateObject = newValue }
    }

    func requestWhenInUseAuthorization() { /* no-op */ }
    func requestTemporaryFullAccuracy() { /* no-op */ }
    func startRecordingUpdates(profile: RecordingEnergyProfile) { /* no-op */ }
    func stopRecordingUpdates() { /* no-op */ }

    func deliver(_ location: CLLocation) {
        sourceDelegate?.locationManager?(
            CLLocationManager(),
            didUpdateLocations: [location]
        )
    }
}
