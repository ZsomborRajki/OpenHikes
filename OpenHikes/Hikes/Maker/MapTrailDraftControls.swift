//
//  MapTrailDraftControls.swift
//  OpenHikes
//
//  The *make a trail* and *record* buttons, on the map's leading edge.
//
//  They sit in the slot ``MapPhotoControlsView`` occupies, and that is a
//  decision rather than a coincidence of layout. The camera pill is offered
//  only while a screen is pushed that has attached a hike to photograph, so on
//  the search screen — the one a hiker is looking at when they decide where to
//  walk on Saturday — that corner of the map is empty and has been since it
//  was built. `MapView.addPhotoControls` says so in its own comment. This is
//  what goes there: the two ways of making a hike that happen on the map.
//  Importing a file is the third, and it stays beside the list it adds to.
//
//  *Record* is the lower of the two, because the bottom of the column is the
//  one a thumb reaches first and recording is the one a hiker does standing
//  at a trailhead. It is on the map rather than in the sheet so it can be
//  reached at the compact detent, where the sheet draws no list at all.
//
//  UIKit for the reason the camera pill is, and it is the same reason twice
//  over: it has to sit at exactly the height the tracking button sits at,
//  follow the sheet through ``MapView/Coordinator/applySheetTop(on:)`` without
//  a SwiftUI pass in between, and fade exactly where the rest of that row
//  fades. It is built from ``MapGlassPill``, as the camera pill is, and shares
//  ``MapView/Coordinator/applyCreditLineClearance()`` with it.
//

import Foundation
import MapKit

#if os(iOS)
import OpenHikesData
import UIKit

/// The pill itself. Owns its appearance and its two actions; where it sits is
/// decided by ``MapView/Coordinator/applySheetTop(on:)``, which positions the
/// whole leading-edge column together.
final class MapTrailDraftControlsView: UIView {
    /// The glyph a route is drawn with everywhere this app has one to draw:
    /// two points and the line between them.
    static let symbolName = "point.topleft.down.to.point.bottomright.curvepath"
    /// The record button's glyph at rest, and while a recording is under way —
    /// the two the sheet's button drew before it moved here.
    static let recordSymbolName = "record.circle"
    static let recordingSymbolName = "stop.circle.fill"

    private let onDraw: () -> Void
    private let onRecord: () -> Void
    /// Kept for ``setRecording(_:)``, which re-dresses it in place.
    private(set) var recordButton: UIButton?
    private var recordGlass: UIVisualEffectView?
    /// What ``setRecording(_:)`` last drew, so a repeat is free.
    private(set) var isRecording = false

    init(onDraw: @escaping () -> Void, onRecord: @escaping () -> Void) {
        self.onDraw = onDraw
        self.onRecord = onRecord
        super.init(frame: .zero)
        buildHierarchy()
        applyRecordingAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MapTrailDraftControlsView is created in code only")
    }

    /// Dresses the record button for a recording under way, or for none.
    ///
    /// Red glass with a white glyph while one is live — the same red the map's
    /// trace and the row badge use — rather than a red glyph on red glass,
    /// which is a glyph nobody can see.
    func setRecording(_ recording: Bool) {
        guard recording != isRecording else { return }
        isRecording = recording
        applyRecordingAppearance()
    }

    private func applyRecordingAppearance() {
        guard let recordButton, let recordGlass else { return }
        // The configuration's colour rather than the button's tint, which a
        // plain button on glass does not carry to its glyph.
        recordButton.configuration?.image = MapGlassPill.symbol(
            isRecording ? Self.recordingSymbolName : Self.recordSymbolName
        )
        recordButton.configuration?.baseForegroundColor = isRecording ? .white : .systemRed
        let glass = UIGlassEffect(style: .regular)
        if isRecording { glass.tintColor = .systemRed }
        recordGlass.effect = glass
        recordButton.accessibilityLabel = isRecording
            ? String(localized: "Open hike recording")
            : String(localized: "Record a hike")
    }

    private func buildHierarchy() {
        let draw = MapGlassPill.button(
            symbol: Self.symbolName,
            label: String(localized: "Make a trail"),
            identifier: "map-trail-maker-button",
            action: onDraw
        )
        // The same identifier the sheet's button carried, so everything that
        // starts a recording by it still finds one.
        let record = MapGlassPill.button(
            symbol: Self.recordSymbolName,
            label: String(localized: "Record a hike"),
            identifier: "record-hike-button",
            action: onRecord
        )
        recordGlass = record.glass
        recordButton = record.button

        MapGlassPill.install([draw.glass, record.glass], in: self)
    }
}
#endif

#if os(iOS)
/// Where the pill is put on the map.
///
/// Here rather than in `MapView.swift` for the reason
/// ``MapView/addAreaSearchControl(to:_:alignedTo:)`` is in the community
/// folder: a feature owns the piece of the map it draws, and the file that
/// builds every control on this map is at its length limit.
extension MapView {
    /// The *make a trail* and *record* pill, in the same place the camera
    /// pill sits.
    ///
    /// Not merely nearby: it hangs off the same two constraints against the
    /// credit line that ``addPhotoControls(to:_:alignedTo:)`` builds, so the
    /// two occupy one slot and ride the sheet as one row. They can never both
    /// be visible — see ``TrailDraftController`` for why that falls out of the
    /// two availability rules rather than out of anything here — which is what
    /// makes sharing the slot safe rather than merely tidy.
    ///
    /// Sharing the *constraints* is not possible, because a constraint belongs
    /// to one view, so ``placeInCreditLineSlot(_:on:_:alignedTo:)`` builds this
    /// pill a pair of its own against the same anchors.
    /// ``MapView/Coordinator/applyCreditLineClearance()`` activates whichever
    /// of each pair the current provider calls for.
    func addTrailDraftControls(
        to mapView: MKMapView,
        _ coordinator: Coordinator,
        alignedTo guide: UILayoutGuide
    ) {
        let controls = MapTrailDraftControlsView(
            onDraw: { [trailMaker] in trailMaker.requestOpen() },
            onRecord: { [recordingEntry] in recordingEntry.requestRecording() }
        )
        // Starts out of the way, for the reason the camera pill does:
        // `observeTrailDraftControls` decides on its first pass whether there
        // is anything to offer, and a pill that flashed in before it answered
        // would be visible over a screen that is already pushed.
        coordinator.trailDraftClearance = placeInCreditLineSlot(
            controls,
            on: mapView,
            coordinator,
            alignedTo: guide
        )
        coordinator.trailDraftControls = controls
        coordinator.applyCreditLineClearance()
    }
}
#endif

extension MapView.Coordinator {
    /// Observes whether a trail can be made right now and shows or hides the
    /// pill, then re-registers — the same imperative arrangement
    /// ``observePhotoControls(_:)`` uses, so navigating between screens never
    /// re-renders the map.
    ///
    /// Idempotent for the reason every registration here is: a second one
    /// would leave two observers running two overlapping fades against the
    /// same view, and `withObservationTracking` offers no way to cancel the
    /// first.
    ///
    /// The record button in the same pill is registered here too, under the
    /// same guard: it is one view, observed once.
    func observeTrailDraftControls(
        _ controller: TrailDraftController,
        recording entry: RecordingEntry
    ) {
        guard !isObservingTrailDraftControls else { return }
        isObservingTrailDraftControls = true
        trackTrailDraftControls(controller)
        trackRecordingEntry(entry)
    }

    private func trackTrailDraftControls(_ controller: TrailDraftController) {
        trailDraftController = controller
        applyTrailDraftControlsVisibility(animated: false)
        reobserving(self, controller) {
            _ = controller.isAvailable
        } onChange: { coordinator, model in
            coordinator.applyTrailDraftControlsVisibility(animated: true)
            coordinator.trackTrailDraftControls(model)
        }
    }

    private func applyTrailDraftControlsVisibility(animated: Bool) {
        #if os(iOS)
        guard let trailDraftControls else { return }
        let visible = trailDraftController?.isAvailable == true
        // The camera pill's resting opacity, since the two share a slot and
        // therefore share the sheet's fade.
        trailDraftControls.fadeMapControl(
            visible: visible,
            restingAlpha: photoControlsSheetAlpha,
            animated: animated
        ) { [weak self] in
            guard let self else { return false }
            return trailDraftController?.isAvailable != true
        }
        #endif
    }

    /// Applies the sheet's own fade, shared with the tracking button and the
    /// credit line.
    ///
    /// Kept apart from the visibility above for the reason
    /// ``applyPhotoControlsAlpha(_:)`` is: the two answer different questions
    /// — "is there a trail to make?" and "has the sheet covered this part of
    /// the map?" — and both have to be true for the pill to be seen. The
    /// sheet's value is the one the camera pill already remembers, since the
    /// two share a slot and therefore share a row.
    func applyTrailDraftControlsAlpha(_ alpha: CGFloat) {
        #if os(iOS)
        guard let trailDraftControls,
              trailDraftController?.isAvailable == true,
              trailDraftControls.alpha != alpha else { return }
        trailDraftControls.alpha = alpha
        #endif
    }

    /// Keeps the record button's red in step with the recorder, then
    /// re-registers — the arrangement every observation on this map uses, so
    /// a recording starting or ending re-dresses one button and re-renders
    /// nothing.
    private func trackRecordingEntry(_ entry: RecordingEntry) {
        #if os(iOS)
        trailDraftControls?.setRecording(entry.isRecording)
        #endif
        reobserving(self, entry) {
            _ = entry.isRecording
        } onChange: { coordinator, model in
            coordinator.trackRecordingEntry(model)
        }
    }
}
