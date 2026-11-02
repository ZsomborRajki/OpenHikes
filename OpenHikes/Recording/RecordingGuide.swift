//
//  RecordingGuide.swift
//  OpenHikes
//
//  One of the hiker's own trails, drawn under a recording as a line to aim
//  for.
//
//  A hiker part way through a recording who decides to go somewhere else
//  draws the way there in the trail maker, as they would at home. What they
//  could not do was see it: the recording screen draws no selected route, and
//  a walk along the new trail cannot start while the recording runs. This is
//  the one thing they were missing — the trail's line under their own track,
//  for as long as the recording lasts.
//
//  ## Not a walk
//
//  A hiker walks a trail or records one, never both (see ``RecordingEntry``),
//  and that stays true. Nothing here matches a fix against the trail, keeps a
//  distance left or starts a ``TrailWalkSession``, and nothing reaches the
//  widget, the Live Activity or the watch, all of which the recording owns —
//  see *A recording always outranks a followed trail*. The guide is a line on
//  the map (`MapRecordingGuide.swift`), a row on the recording screen naming
//  it (``RecordingGuideRow``) and a button on the trail's own screen
//  (``RecordingGuideButton``).
//
//  ## One recording's
//
//  Chosen during a recording, and ended with it. The draft the recorder held
//  when the trail was chosen is kept, and once it holds another or none —
//  the recording saved or discarded — nothing is shown and the line is let
//  go. In memory only, so a launch that recovers a recording recovers it
//  without its guide.
//
//  ## The line
//
//  Read and projected off the main actor by a ``DisplayedRouteCoordinateCache``
//  and a ``SelectedLine`` of its own, the pair the selected route is drawn
//  through, so the guide is the trail's whole line cut at its pauses rather
//  than the thinned copy the library draws, and an *Edit Route* saved while
//  it is shown is drawn again. A trail deleted from the list goes with its
//  guide (``forget(_:)``). An edit or a deletion mirrored in from another
//  device is not followed: nothing watches the store for this line, and a
//  recording is over long before the hiker's other phone matters.
//

import Foundation
import Observation
import OpenHikesData

/// The trail shown under the recording under way, if any — see the file
/// header.
@MainActor
@Observable
final class RecordingGuide {
    /// The trail as the recording screen names it, taken when it was chosen.
    struct Trail: Equatable {
        let hikeID: UUID
        let title: String
        /// The trail's own colour, which its line is drawn in.
        let tintHex: String
    }

    /// The trail chosen, whether or not the recording it was chosen in is
    /// still the one under way — ``shown`` says that.
    private var trail: Trail?

    /// The recording draft the trail was chosen during.
    @ObservationIgnored private var recordingID: UUID?
    /// Whether a watch on the recorder's draft is armed. An observation can
    /// only be ignored, never cancelled, so one stays armed until it fires,
    /// and a second is never added beside it.
    @ObservationIgnored private var isWatchingRecording = false
    /// Where the trail's line is read, off the main actor. Its own rather than
    /// the selection's, which keeps one read of one hike at a time.
    @ObservationIgnored private let lines: SelectedLine
    /// The trail's line, projected for the map.
    @ObservationIgnored let projection: DisplayedRouteCoordinateCache
    /// The id of the recording draft under way, or `nil` when none is. Read
    /// inside observation, so it has to read observable state.
    @ObservationIgnored private let recordingHikeID: @MainActor () -> UUID?
    /// Where the request for the recording screen is sent, or `nil` for a
    /// guide with nowhere to send it.
    @ObservationIgnored private let openRequests: HikeOpenRequests?

    /// - Parameters:
    ///   - recordingHikeID: the id of the recording draft under way, or `nil`.
    ///   - openRequests: where ``openRecording()`` sends its request.
    ///   - lines: where the trail's line is read. A seam.
    ///   - projection: what projects it. A seam.
    init(
        recordingHikeID: @escaping @MainActor () -> UUID?,
        openRequests: HikeOpenRequests? = nil,
        lines: SelectedLine = SelectedLine(),
        projection: DisplayedRouteCoordinateCache = DisplayedRouteCoordinateCache()
    ) {
        self.recordingHikeID = recordingHikeID
        self.openRequests = openRequests
        self.lines = lines
        self.projection = projection
    }

    /// The trail shown, while the recording it was chosen during is the one
    /// under way.
    ///
    /// Asks the recorder as well as the stored trail, so a recording that has
    /// just ended takes its guide off the map and the screen in the same pass,
    /// rather than one hop later when the watch on it fires.
    var shown: Trail? {
        guard let trail, let recordingID, recordingID == recordingHikeID() else { return nil }
        return trail
    }

    /// The shown trail's line, once it has been read and projected.
    var line: DisplayedRouteCoordinateCache.DrawnRoute? {
        shown.flatMap { projection.drawnRoute(forHikeID: $0.hikeID) }
    }

    /// Whether `hike` can be shown under the recording under way: there is
    /// one, `hike` is not it, and `hike` has a line to draw.
    func canShow(_ hike: Hike) -> Bool {
        guard let recording = recordingHikeID() else { return false }
        return hike.id != recording && !hike.isRecording && hike.distanceMeters > 0
    }

    /// Whether the hike with `hikeID` is the one shown.
    func isShowing(_ hikeID: UUID) -> Bool {
        shown?.hikeID == hikeID
    }

    /// Shows `hike` under the recording under way, in place of any trail shown
    /// before it. Does nothing when ``canShow(_:)`` says it cannot be.
    func show(_ hike: Hike) {
        guard canShow(hike), let recording = recordingHikeID() else { return }
        recordingID = recording
        trail = Trail(hikeID: hike.id, title: hike.displayTitle, tintHex: hike.tintHex)
        projection.prepare(for: hike, from: lines)
        watchRecording()
    }

    /// Takes the trail off the recording, which goes on as it was.
    func stopShowing() {
        recordingID = nil
        // `Trail` is `Equatable`, so a `nil` written over `nil` notifies
        // nobody.
        trail = nil
        projection.prepare(for: nil, from: lines)
    }

    /// Stops showing the trail if it is one of `hikeIDs`, which have just
    /// been deleted.
    func forget(_ hikeIDs: some Sequence<UUID>) {
        guard let trail, hikeIDs.contains(trail.hikeID) else { return }
        stopShowing()
    }

    /// Opens the recording screen, the way the recording's widget does — see
    /// ``HikeOpenRequests/openRecording()``. One way in, so the screen is not
    /// pushed a second time when it is already up.
    func openRecording() {
        guard recordingHikeID() != nil else { return }
        openRequests?.openRecording()
    }

    /// Lets the trail go once the recording it was chosen during is no longer
    /// the one under way, then watches again — see the file header.
    private func watchRecording() {
        guard !isWatchingRecording else { return }
        isWatchingRecording = true
        followRecording()
    }

    private func followRecording() {
        guard trail != nil else {
            isWatchingRecording = false
            return
        }
        guard recordingID == recordingHikeID() else {
            isWatchingRecording = false
            stopShowing()
            return
        }
        reobserving(self) { [recordingHikeID] in
            _ = recordingHikeID()
        } onChange: { guide in
            guide.followRecording()
        }
    }
}

extension RecordingGuide {
    /// The guide of `recorder`'s recordings, which asks it for the draft under
    /// way and holds no other reference to it.
    convenience init(recorder: HikeRecorder, openRequests: HikeOpenRequests) {
        self.init(
            recordingHikeID: { [weak recorder] in recorder?.currentHike?.id },
            openRequests: openRequests
        )
    }
}
