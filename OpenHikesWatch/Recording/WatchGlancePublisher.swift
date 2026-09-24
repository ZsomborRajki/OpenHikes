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
    ///
    /// Seeded from the disk rather than starting empty, because the last
    /// glance may be a previous process's: an app that died mid-walk left a
    /// recording there, and the idle glance a new process publishes has to
    /// read as the change of state it is.
    private var lastWritten = WatchGlanceStore.load()

    func publish(_ glance: WatchGlance) {
        guard WatchGlanceReloadPolicy.shouldReload(from: lastWritten, to: glance),
              WatchGlanceStore.save(glance) else { return }
        lastWritten = glance
        WidgetCenter.shared.reloadTimelines(ofKind: WatchGlanceStore.widgetKind)
    }
}
