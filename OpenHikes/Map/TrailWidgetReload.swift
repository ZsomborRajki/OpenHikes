//
//  TrailWidgetReload.swift
//  OpenHikes
//
//  Where the *trail* feed asks WidgetKit to redraw the home screen widget,
//  and the one place the recording precedence rule costs anything.
//
//  The rule itself is stated in three places that must not disagree:
//  `TrailWidgetEntry.init` applies it to the widget, `HikeLiveActivityController`
//  to the Lock Screen, and `HikeRecordingControlState` to the Control Center
//  button. A recording always outranks a selected trail, because a follow can
//  be re-derived from the trail and a fix and a recording cannot.
//

import Foundation
import OpenHikesShared
import WidgetKit

/// Asks for a trail-widget redraw unless a live recording owns the widget.
///
/// ``TrailWidgetEntry`` discards the stored trail outright while a recording
/// payload exists, so every redraw the trail feed asks for during a recording
/// produces a byte-identical timeline: the same recording figures, the same
/// trace, the same deep link. WidgetKit gives an app a finite number of
/// reloads a day and quietly throttles a widget that overruns it, and the two
/// feeds run at wildly different rates — `BackgroundTrailTracker` publishes a
/// live fix every 45 seconds, against a recording snapshot `HikeRecorder`
/// rewrites every fifteen minutes. Ungated, a walk recorded *along* a followed
/// trail spent up to eighty reloads an hour redrawing a picture that could not
/// change, which is the throttling the follow feed's own budget work exists to
/// stay clear of.
///
/// What is deliberately *not* gated is the write behind the reload. The trail
/// snapshot and its basemaps stay current in the App Group throughout the
/// recording, so the unconditional reload `AppGroupRecordingSharedStateStore`
/// issues when the walk ends finds the selected trail exactly as it would have
/// been. The redraw is deferred; the data is not.
///
/// Nor is the *recording* feed gated. Its reloads are the ones that change
/// what the widget draws, and they stay unconditional in
/// `AppGroupRecordingSharedStateStore` — this is only about the feed that has
/// lost the screen.
///
/// A value with an injected sink rather than a free function, for the reason
/// `TrailBasemapRenderer.Render` is one: `WidgetCenter` neither reports a
/// reload nor replays it, so without a seam here the only assertable thing is
/// this type in isolation — and a call site that went back to calling
/// `WidgetCenter` directly would pass that test while spending the budget this
/// exists to protect. ``system`` is what the app builds; a suite hands the
/// tracker and the renderer a counter instead and drives the real paths.
nonisolated struct TrailWidgetReload: Sendable {
    /// What a *granted* request does. Only tests supply one.
    typealias Reload = @Sendable () -> Void

    /// The one the app uses, and the default every production call site takes.
    static let system = Self()

    private let reload: Reload

    init(reload: @escaping Reload = {
        WidgetCenter.shared.reloadTimelines(ofKind: TrailWidgetKind.id)
    }) {
        self.reload = reload
    }

    /// - Returns: whether the redraw was asked for, which is what the refusal
    ///   is asserted through where a sink would be indistinguishable from
    ///   silence.
    @discardableResult func requestUnlessRecording() -> Bool {
        assertOffMainThread(
            "Reading the recording snapshot must stay off the main thread"
        )
        guard SharedStore.loadRecording() == nil else { return false }
        reload()
        return true
    }
}
