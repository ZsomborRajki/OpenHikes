//
//  HikeRecorder+PlaceName.swift
//  OpenHikes
//
//  Naming a recording for the town it started in.
//
//  A recording that followed no trail used to be named for the time of day
//  alone — "Morning Hike – Oct 26, 2026" — which says the same of every walk
//  started that morning, wherever it was. The town a walk set off from is what
//  a hiker remembers it by, so it now takes that town's name in the same
//  shape: "Budapest – Oct 26, 2026". It ranks below the two names that know
//  more about the walk itself — the one the hiker types, and the trail the
//  walk mostly followed (``RecordingTrailNames``) — and above the time of day,
//  which is what is left when the town cannot be had. See
//  ``HikeRecorder/suggestedTitle(forDistance:)``.
//
//  ## Asked once, at the first fix
//
//  Not at Stop, for two reasons. The stop alert offers the name a hike will be
//  saved under as its placeholder, and it can only offer one that is already
//  known. And a trailhead is where a phone is likeliest to have signal; the
//  end of a walk can be the far side of a ridge.
//
//  One question per recording, about one coordinate, and a failed one is not
//  asked again: the name it would have given is a nicety, and the name it
//  falls back to is the one every recording had before this. A relaunch that
//  recovers the walk asks once more, about the same first point, because the
//  answer was only ever held in memory.
//
//  ## Held, not written
//
//  The answer waits in ``HikeRecorder/startPlaceTitle`` until the hike is
//  saved, and the draft keeps its time-of-day title until then, as it does for
//  a trail's name. The draft is a mirrored row and the title the Live Activity
//  draws, so renaming it seconds after Start would be a CloudKit export and a
//  Lock Screen relabeling itself, for a name the stop alert shows the hiker
//  anyway.
//

import CoreLocation
import Foundation

extension HikeRecorder {
    /// Asks what town this recording started in, the first time it is called
    /// for a recording.
    ///
    /// Called with every accepted fix and with a recovered walk's first point,
    /// so the first of those is the start: later calls ask nothing. A `nil`
    /// coordinate — a recovered walk with no points yet — asks nothing either,
    /// and leaves the question to the first fix.
    ///
    /// The answer belongs to the recording that asked. One that lands after
    /// that recording was saved or discarded, or after another has started, is
    /// dropped rather than naming a walk somewhere else.
    func nameStartPlace(at coordinate: CLLocationCoordinate2D?) {
        guard let placeNames,
              let coordinate,
              !hasAskedForStartPlace,
              let askingSessionID = sessionID,
              let startedAt = sessionStartedAt else { return }
        hasAskedForStartPlace = true
        Task { [weak self] in
            let city = await placeNames.cityName(at: coordinate)
            guard let self, sessionID == askingSessionID else { return }
            startPlaceTitle = city.flatMap { name in
                Self.placeTitle(city: name, for: startedAt)
            }
        }
    }
}
