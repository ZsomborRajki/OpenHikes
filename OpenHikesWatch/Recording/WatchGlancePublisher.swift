//
//  WatchGlancePublisher.swift
//  OpenHikesWatch
//
//  Hands the recording to the watch's complication: writes the glance into
//  the watch's App Group and asks WidgetKit for a redraw, when
//  ``WatchGlanceReloadPolicy`` says one is worth spending — see
//  ``WatchGlance`` for why this is the only way the two processes meet.
//

import OpenHikesShared
import WidgetKit

@MainActor
final class WatchGlancePublisher {
    /// The last glance that was written, which the policy measures from.
    private var lastWritten: WatchGlance?

    func publish(_ glance: WatchGlance) {
        guard WatchGlanceReloadPolicy.shouldReload(from: lastWritten, to: glance),
              WatchGlanceStore.save(glance) else { return }
        lastWritten = glance
        WidgetCenter.shared.reloadTimelines(ofKind: WatchGlanceStore.widgetKind)
    }
}
