//
//  RecordingView.swift
//  OpenHikes
//

import Foundation
import os
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct RecordingView: View {
    let recorder: HikeRecorder
    var mapController: MapController
    /// Offers the map's camera pill while a walk is being recorded. Optional
    /// so previews and tests can build this view without one.
    var photoCapture: PhotoCaptureController?
    /// Draws the photos already taken on this walk as pins on the live track,
    /// the same way a saved hike's detail screen draws its own. Optional for
    /// the same reason as above.
    var photoPins: PhotoMapPinController?
    var onSaved: (Hike) -> Void
    var onDiscarded: (UUID?) -> Void
    /// Pushes the gallery when one of those pins is tapped. Carries the draft
    /// with it because the caller builds a route out of the pair, and the
    /// recorder's hike is this screen's to know, not the sheet's.
    var onOpenPhoto: (Hike, HikePhoto) -> Void = { _, _ in /* no-op default */ }

    private var recordingFailure: RecordingFailure? {
        if case let .failed(failure) = recorder.phase {
            failure
        } else {
            nil
        }
    }

    private var showingFailure: Binding<Bool> {
        Binding(
            get: {
                recordingFailure != nil && !recorder.canRetrySave
            },
            set: { if !$0 { recorder.dismissFailure() } }
        )
    }

    private var failureNeedsSettings: Bool {
        recordingFailure == .locationDenied
            || recordingFailure == .preciseLocationRequired
    }

    var body: some View {
        RenderSignpost.mark("RecordingBody")
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                RecordingHeader(recorder: recorder)
                RecordingRecoveryNotice(recorder: recorder)
                RecordingConditionsNotice(recorder: recorder)
                RecordingStatsGrid(stats: recorder.stats)
                RecordingControls(
                    recorder: recorder,
                    onSaved: onSaved,
                    onDiscarded: onDiscarded
                )
            }
            .padding()
        }
        .navigationTitle("Record Hike")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .softScrollEdgeEffect(for: .top)
        .onAppear {
            mapController.followUser()
        }
        // Each photo is pinned to the walker's last accepted fix — read at the
        // shutter, so a picture taken twenty minutes in is pinned twenty
        // minutes along. The recorder's live fix, not the draft `Hike`'s
        // `route`: that is only written when the recording stops. A draft only
        // exists once recording starts, which is why the modifier takes an
        // optional hike.
        .photoCaptureSubject(photoCapture, for: recorder.currentHike) {
            PhotoTrailAnchor.recordingCoordinate(recorder.lastAcceptedPoint)
        }
        // …and each one stands on the map as soon as it is taken, rather than
        // only once the walk has been saved. A background because the claim is
        // all this draws — see ``RecordingPhotoPins`` for why it is a separate
        // view rather than a modifier on this one.
        .background {
            if let hike = recorder.currentHike {
                RecordingPhotoPins(hike: hike, controller: photoPins) { photo in
                    onOpenPhoto(hike, photo)
                }
            }
        }
        // The phase is a coloured dot and a word at the top of a scrolling
        // screen, so a change nobody is looking at is a change nobody hears.
        .onChange(of: recorder.phase) { _, phase in
            AccessibilityNotification.Announcement(phase.accessibilityTitle)
                .post()
        }
        .alert(isPresented: showingFailure, error: recordingFailure) {
            #if os(iOS)
            if failureNeedsSettings {
                Button("Open Settings") {
                    guard let url = URL(
                        string: UIApplication.openSettingsURLString
                    ) else { return }
                    UIApplication.shared.open(url)
                }
            }
            #endif
            Button("OK", role: .cancel) { /* no-op */ }
        }
    }
}

/// The photos already taken on this walk, as pins on the map's live track.
///
/// Its own view for the reason ``HikePhotoSection`` is one on the detail
/// screen, and with rather more at stake here: `RecordingView`'s body reads
/// `recorder.stats`, so it re-runs on every accepted fix — and `orderedPhotos`
/// is a full sort behind a computed property. Reading the gallery from up
/// there would sort it once per GPS fix, for the whole of a six-hour walk, to
/// produce the same handful of pins every time.
///
/// It draws nothing itself. The pins are MapKit annotations published through
/// ``PhotoMapPinController``; this exists only to own the claim, which is why
/// it is a zero-sized background rather than anything on the screen.
private struct RecordingPhotoPins: View {
    let hike: Hike
    var controller: PhotoMapPinController?
    var onOpen: (HikePhoto) -> Void

    var body: some View {
        RenderSignpost.mark("RecordingPhotoPinsBody", "\(hike.photos.count) photos")
        return Color.clear
            .frame(width: 0, height: 0)
            .photoMapPins(controller, photos: hike.orderedPhotos) { photoID in
                guard let photo = hike.photos.first(where: { $0.id == photoID }) else { return }
                onOpen(photo)
            }
    }
}

private struct RecordingRecoveryNotice: View {
    let recorder: HikeRecorder

    private let noticePadding: CGFloat = 12
    private let noticeRadius: CGFloat = 12
    private let noticeSpacingResumed: CGFloat = 10
    private let noticeSpacingDecision: CGFloat = 6

    @ViewBuilder var body: some View {
        switch recorder.recoveryState {
        case .absent: EmptyView()
        case .resumed:
            HStack(spacing: noticeSpacingResumed) {
                Label(
                    "Recording resumed after OpenHikes restarted.",
                    systemImage: "arrow.clockwise.circle"
                )
                .font(.subheadline)
                Spacer()
                Button("Dismiss") {
                    recorder.dismissRecoveryNotice()
                }
                .font(.caption)
            }
            .padding(noticePadding)
            // Orange-tinted glass rather than a flat 12% orange wash: the
            // notice keeps the colour that says "recovered" while staying a
            // card that floats over the screen rather than a block painted
            // onto it.
            .glassSurface(
                .regular.tint(.orange),
                in: .rect(cornerRadius: noticeRadius)
            )
        case .needsDecision(let summary):
            VStack(alignment: .leading, spacing: noticeSpacingDecision) {
                Label("Recovered recording", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Text(
                    "\(distance(summary.distanceMeters)) · "
                        + "\(summary.pointCount.formatted()) points · "
                        + "\(HikeFormat.duration(max(0, summary.lastUpdatedAt.timeIntervalSince(summary.startedAt))))"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                Text("Resume it, stop to save it, or discard it below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(noticePadding)
            .glassSurface(
                .regular.tint(.orange),
                in: .rect(cornerRadius: noticeRadius)
            )
        }
    }

    private func distance(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }
}

/// Warns about system settings that quietly degrade a recording without
/// stopping it. Never blocks: a hike recorded in Low Power Mode is worth far
/// more than one refused on principle.
private struct RecordingConditionsNotice: View {
    let recorder: HikeRecorder

    var body: some View {
        #if os(iOS)
        if recorder.isActive, !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #endif
    }

    #if os(iOS)
    private var warnings: [String] {
        var warnings: [String] = []
        // The energy profile's own words rather than a separate sentence about
        // Low Power Mode: the profile is what the app did about it, and two
        // messages about the same condition would contradict each other.
        if let reason = recorder.energyProfile.reason {
            warnings.append(reason)
        }
        if UIApplication.shared.backgroundRefreshStatus != .available {
            warnings.append(
                "Background App Refresh is off, so the track may be sparse while OpenHikes isn't open."
            )
        }
        return warnings
    }
    #endif
}

private struct RecordingHeader: View {
    let recorder: HikeRecorder
    /// Read here, on the render path, unlike ``MapView/Coordinator``'s
    /// notification observers — and for the opposite reason. The coordinator
    /// gates work that MapKit does off SwiftUI's path entirely; this gates
    /// whether a `TimelineView` is *in the hierarchy at all*, which is a
    /// question only SwiftUI can answer. Scene phase changes a handful of
    /// times per hike, so the redraw it costs is bounded by transitions rather
    /// than by fixes.
    @Environment(\.scenePhase)
    private var scenePhase

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(phaseColor)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(phaseTitle)
                .font(.headline)
            Spacer()
            // Only while the readout is on screen. A recording keeps running
            // in the user's pocket for hours, and iOS does *not* suspend a
            // `TimelineView` in an app held awake by background location — it
            // was measured redrawing at a steady 1 Hz with the screen off,
            // which is ~21,600 pointless redraws over a six-hour walk. The
            // elapsed value is derived from a timestamp, not accumulated, so
            // nothing is lost by not counting: the readout is correct again on
            // the first tick after return.
            if recorder.sessionStartedAt != nil, scenePhase == .active {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    // The tick only says *when* to redraw; the value comes
                    // from ``HikeRecorder/elapsedSeconds()``, which counts
                    // from a monotonic source wherever it has one rather than
                    // from the wall clock.
                    RecordingClock(readout: HikeFormat.duration(recorder.elapsedSeconds()))
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("recording-phase")
    }

    private var phaseTitle: String {
        recorder.phase.accessibilityTitle
    }

    private var phaseColor: Color {
        switch recorder.phase {
        case .recording: .red
        case .recovering, .waitingForFix, .saving: .orange
        case .paused: .secondary
        case .reviewing: .orange
        case .idle: .green
        case .failed: .red
        }
    }
}

/// The elapsed-time readout, and the app's last per-second wake-up.
///
/// Its own view so the 1 Hz tick redraws a `Text` rather than the header
/// around it, and so the tick is *countable*: `RecordingClockTick` is what
/// makes "the system suspends this while backgrounded" a measurement in the
/// report instead of an assumption in a comment.
///
/// It stores the formatted readout rather than the recorder deliberately.
/// A view holding only a reference is structurally identical on every tick,
/// so SwiftUI skips its body and the clock freezes — which is exactly what
/// happened the first time this was extracted, and what the assertion in
/// `testLiveRecordingCostPerFix` now catches.
private struct RecordingClock: View {
    let readout: String

    var body: some View {
        RenderSignpost.mark("RecordingClockTick")
        return Text(readout)
            .font(.headline.monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

private extension HikeRecorder.Phase {
    var accessibilityTitle: String {
        switch self {
        case .idle: "Ready"
        case .recovering: "Recovering"
        case .waitingForFix: "Finding GPS"
        case .recording: "Recording"
        case .paused: "Paused"
        case .saving: "Saving"
        case .reviewing: "Review Route"
        case .failed: "Needs Attention"
        }
    }
}

private struct RecordingStatsGrid: View {
    let stats: RecordingStats

    var body: some View {
        StatGrid {
            StatTile(label: "Distance", value: distance)
            // `StatTile` already exposes itself as one label/value element;
            // only the identifier UI automation waits on is added here.
            StatTile(label: "Points", value: stats.pointCount.formatted())
                .accessibilityIdentifier("recording-point-count")
            StatTile(label: "Avg Speed", value: averageSpeed)
            StatTile(label: "Accuracy", value: accuracy)
        }

        if let trail = stats.matchedTrailName {
            Text("Following: \(trail)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var distance: String {
        Measurement(value: stats.distanceMeters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    private var averageSpeed: String {
        guard let speed = stats.averageSpeedMetersPerSecond else { return "—" }
        return HikeFormat.speed(
            Measurement(value: speed, unit: UnitSpeed.metersPerSecond)
        )
    }

    private var accuracy: String {
        guard let horizontalAccuracy = stats.horizontalAccuracy else { return "Searching…" }
        guard horizontalAccuracy <= RecordingFixPolicy.maximumHorizontalAccuracy else { return "Weak signal" }
        return "±\(Int(horizontalAccuracy.rounded())) m"
    }
}

private struct RecordingControls: View {
    /// How close two adjacent glass controls have to come before they merge.
    private static let controlGlassSpacing: CGFloat = 8

    let recorder: HikeRecorder
    var onSaved: (Hike) -> Void
    var onDiscarded: (UUID?) -> Void

    @State private var showDiscardConfirmation = false
    @State private var showStopAlert = false
    @State private var stopNameDraft = ""

    var body: some View {
        VStack(spacing: 12) {
            phaseControls
        }
        .frame(maxWidth: .infinity)
        .confirmationDialog(
            "Discard this recording?",
            isPresented: $showDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard Recording", role: .destructive) {
                Task {
                    let hikeID = recorder.currentHike?.id
                    await recorder.discard()
                    if recorder.phase == .idle {
                        onDiscarded(hikeID)
                    }
                }
            }
            Button("Cancel", role: .cancel) { /* no-op */ }
        } message: {
            Text("The recorded track cannot be recovered after it is discarded.")
        }
        .alert("Name Your Hike", isPresented: $showStopAlert) {
            TextField(
                recorder.currentHike?.title ?? "Hike name",
                text: $stopNameDraft
            )
            Button("Save") {
                Task { await stopAndSave() }
            }
            Button("Cancel", role: .cancel) { /* no-op */ }
        } message: {
            Text("Give this hike a name, or leave it blank to keep the default.")
        }
    }

    @ViewBuilder private var phaseControls: some View {
        switch recorder.phase {
        case .idle:
            Button("Start Recording", systemImage: "record.circle") {
                Task { await recorder.start() }
            }
            .prominentGlassButtonStyle()
            .tint(.red)
        case .recovering:
            ProgressView("Recovering recorded hike…")
                .frame(maxWidth: .infinity)
        case .waitingForFix, .recording:
            // Two `.glass` buttons side by side: a container renders them in
            // one pass and lets them blend as they meet, which is what makes
            // a pair read as one control group rather than two panes.
            GlassStack(spacing: Self.controlGlassSpacing) {
                HStack {
                    Button("Pause", systemImage: "pause.fill") {
                        recorder.pause()
                    }
                    .glassButtonStyle()

                    stopButton
                }
            }
        case .paused:
            GlassStack(spacing: Self.controlGlassSpacing) {
                HStack {
                    Button("Resume", systemImage: "play.fill") {
                        Task { await recorder.resume() }
                    }
                    .glassButtonStyle()

                    stopButton
                }
            }
            discardButton
        case .saving:
            ProgressView("Saving recorded hike…")
                .frame(maxWidth: .infinity)
        case .reviewing:
            if let review = recorder.routeReview {
                RecordingRouteReviewControls(
                    recorder: recorder,
                    review: review
                ) { hike in
                    onSaved(hike)
                }
            }
            discardButton
        case .failed(let failure):
            if recorder.canRetrySave {
                VStack(alignment: .leading, spacing: 12) {
                    Text(failure.errorDescription ?? "The hike could not be saved.")
                        .font(.headline)
                    if let suggestion = failure.recoverySuggestion {
                        Text(suggestion)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Button("Retry Save") {
                        Task { await retrySave() }
                    }
                    .prominentGlassButtonStyle()
                    .accessibilityIdentifier("recording-retry-save")
                    discardButton
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if recorder.isActive {
                discardButton
            } else {
                Button("Try Again") {
                    recorder.dismissFailure()
                }
                .prominentGlassButtonStyle()
            }
        }
    }

    private var stopButton: some View {
        Button("Stop", systemImage: "stop.fill") {
            // Deliberately blank rather than pre-filled with the default
            // title. The alert's own copy says "leave it blank to keep the
            // default" and the field's placeholder already shows that default,
            // so pre-filling made the field impossible to leave blank —
            // tapping Stop → Save without typing sent the default through as
            // `customName`, and `normalizedCustomName` only nils out an
            // *empty* string, so the hike was permanently flagged user-named.
            // The rendered name was identical, which is why nothing looked
            // wrong; the state was just no longer true.
            stopNameDraft = ""
            showStopAlert = true
        }
        .prominentGlassButtonStyle()
        .tint(.red)
    }

    private var discardButton: some View {
        Button("Discard Recording", role: .destructive) {
            showDiscardConfirmation = true
        }
        .glassButtonStyle()
    }

    private func stopAndSave() async {
        let customName = stopNameDraft.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        do {
            let outcome = try await recorder.stop(customName: customName)
            if case .saved(let hike) = outcome {
                onSaved(hike)
            }
        } catch {
            HikeRecorder.logger.error(
                "Recording save failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func retrySave() async {
        do {
            onSaved(try await recorder.retrySave())
        } catch {
            HikeRecorder.logger.error(
                "Recording save retry failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
