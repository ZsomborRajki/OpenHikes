//
//  TrailDraftController.swift
//  OpenHikes
//
//  Whether the map is offering to make a trail, whether it is currently one
//  big drawing surface, and the one place a waypoint is put down.
//
//  A reference type for the reason ``PhotoCaptureController`` is one, and it
//  is the same geometry: the pill is on the map, the screen it opens is inside
//  the sheet's navigation stack, and the tap that adds a point arrives at
//  `MapView.Coordinator` — three places that cannot see each other. They all
//  attach here instead, and the map observes only what it draws.
//
//  ## The two pills can never both be up, and nothing enforces it
//
//  That is the point of putting the maker in the slot the camera pill already
//  occupies. ``PhotoCaptureController/refreshAvailability()`` is
//  `subject != nil && hasHostScreen`, so the camera is offered only while a
//  screen is pushed *and* that screen has attached a hike to photograph; this
//  one is offered only while **no** screen is pushed. The maker itself is a
//  pushed screen that attaches no photo subject, so opening it withdraws this
//  pill without offering the other. The exclusion falls out of the two
//  definitions rather than out of a rule either of them has to remember, which
//  is why neither of these types knows the other exists.
//
//  ## Every mutation goes through here
//
//  The map appends a waypoint and the maker's screen toggles snapping, cancels
//  and saves — and all of them land on ``TrailDraft`` through this object,
//  because this is the one that also knows the draft has to be written down
//  and that a change to the line is a question for its routing provider. A screen
//  that mutated the draft directly would leave the durable copy behind by
//  exactly one tap and the line unrouted, every time.
//
//  ## Legs are routed one at a time, and a failure is not retried by itself
//
//  Every pass takes the legs that want an answer and do not have one, marks
//  them, and asks about them **in order, one at a time**. Concurrently would
//  be nineteen simultaneous requests from one phone for a twenty-point trail,
//  which is the shape that earns the `429` this app has already met in the
//  field; sequentially, the second leg usually joins the download the first
//  one started — see ``OverpassTrailLegRouter``.
//
//  A leg whose provider failed stays failed until the hiker taps *Retry*. Asking
//  again on the next tap would mean one extra request per point put down,
//  aimed at the server that has just said it is busy, and the hiker would see
//  the same sentence appear and disappear without having done anything.
//

import CoreLocation
import Foundation
import Observation

/// A request that the maker's screen open the place editor.
///
/// A type rather than a bare `UUID` so the token travels with it — see
/// ``TrailDraftController/placeEditorRequest`` for what the token is for, and
/// ``PinSelection``, which is the same shape one feature over.
nonisolated struct TrailPlaceEditRequest: Equatable, Sendable {
    let placeID: UUID
    let token: Int
}

@Observable
final class TrailDraftController {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    /// The line being drawn. Handed to the map, which observes it directly, so
    /// a tap that adds a point re-renders no SwiftUI view.
    let draft: TrailDraft

    /// What OpenStreetMap says is near the line, and the pill that asks.
    ///
    /// Held here rather than beside the draft because it is not part of the
    /// drawing: nothing it holds is written down, saved or restored, and
    /// closing the maker forgets all of it. What it shares with the draft is
    /// only that three places that cannot see each other read it — see
    /// ``TrailPointFinder``.
    let finder: TrailPointFinder

    /// What the line climbs and drops, asked for once the drawing settles.
    ///
    /// Held here for the reason the finder is, and it keeps the same bargain:
    /// nothing it holds is written down or restored, and closing the maker
    /// forgets all of it. See ``TrailDraftElevation`` for why the question
    /// waits rather than being asked per tap.
    let elevation: TrailDraftElevation

    /// What the points a hiker merely tapped are called.
    ///
    /// Held here like the two above, and unlike them what it produces *is*
    /// written down: a name is part of the drawing, so it goes through
    /// ``receiveName(_:for:)`` below rather than onto the draft directly. See
    /// ``TrailStopNamer``.
    let namer: TrailStopNamer

    /// Whether the map should be offering to make a trail. Observed directly
    /// by ``MapView/Coordinator``, so showing or hiding the pill never
    /// re-renders a view.
    private(set) var isAvailable = false

    /// Whether the map is the maker's canvas right now: a tap means *put a
    /// point here* and means nothing else.
    ///
    /// Observed by the coordinator, which is what suspends the drawn-route and
    /// shared-line hit tests while it holds — see `MapCoordinator+RouteTap.swift`.
    /// One tap, one meaning.
    private(set) var isEditing = false

    /// A one-shot request to open the maker, in the shape ``MapController``'s
    /// commands take: a token whose *change* is the message.
    private(set) var openRequest = 0

    /// A one-shot request to open the editor on one place, or `nil` when
    /// nothing has asked.
    ///
    /// Tokened for the reason ``PinSelection`` is: asking twice for the same
    /// place is two requests, and without the token the second would look to
    /// the screen like the one it has already answered — which is exactly
    /// what a hiker does by opening a pin's callout, tapping *Edit*, closing
    /// the sheet and tapping *Edit* again.
    ///
    /// The map is what asks — a callout's button, or *Mark a Place* — and the
    /// screen inside the sheet is what presents. Neither can see the other,
    /// which is the whole of why it lands here.
    private(set) var placeEditorRequest: TrailPlaceEditRequest?

    /// Whether this maker can make a leg follow a path at all.
    ///
    /// False when this launch has no provider for the selected mode. A
    /// preview can draw freehand without pretending to ask a routing service.
    var canSnapToPaths: Bool { routers[draft.travelMode] != nil }

    /// Where the draft is kept between launches, or `nil` for a launch that
    /// remembers nothing — a preview, or a suite asking only about the pill.
    @ObservationIgnored private let store: TrailDraftStore?

    /// Each mode has its own provider and therefore its own geometry cache.
    @ObservationIgnored private let routers: [TrailTravelMode: any TrailLegRouting]
    /// Readable by tests so a superseded pass can be joined before asserting
    /// that its late answer left the current line untouched.
    @ObservationIgnored private(set) var routingTask: Task<Void, Never>?
    @ObservationIgnored private var routingQueue: [TrailLegEnds] = []
    @ObservationIgnored private var routingGeneration = 0

    /// The legs a question is currently out about, so a second pass started by
    /// the next tap does not ask about them again beside the first.
    ///
    /// Not on ``TrailDraft`` even though the leg's own
    /// ``TrailLegSnap/routing`` says almost the same thing, because the two
    /// answer different questions: that one is *what should the map draw*, and
    /// a leg can stop being drawn as routing — the hiker turned snapping off —
    /// while the request for it is still on the wire.
    @ObservationIgnored private var legsInFlight: Set<TrailLegEnds> = []

    /// Whether the sheet has any screen pushed. The inverse of what the pill
    /// is offered on; see the note above on why that is the whole exclusion.
    ///
    /// Starts `true`, like ``PhotoCaptureController``'s, so the pill is
    /// withheld until the sheet has said otherwise rather than flashing in
    /// over a launch that restored a pushed screen.
    @ObservationIgnored private var hasPushedScreen = true

    @ObservationIgnored private var nextPlaceEditorToken = 0

    /// - Parameters:
    ///   - elevationSource: where the line's heights come from, or `nil` for a
    ///     launch that must not ask — a preview, or a suite, since every call
    ///     is billed. See ``OpenHikesModel/makeTrailElevationSource()``.
    ///   - elevationPause: the debounce in front of that source, exposed for
    ///     the reason ``TrailDraftElevation``'s own parameter is.
    ///   - naming: what a tapped point is called, or `nil` for a launch that
    ///     must not ask — a preview, or a suite, for the reason
    ///     `elevationSource` is `nil` in both. See
    ///     ``OpenHikesModel/makeTrailStopNaming()``.
    init(
        store: TrailDraftStore? = nil,
        router: (any TrailLegRouting)? = nil,
        placeSource: (any TrailPointSourcing)? = nil,
        elevationSource: (any CuratedElevationSourcing)? = nil,
        elevationPause: (@Sendable (TimeInterval) async throws -> Void)? = nil,
        naming: (any TrailStopNaming)? = nil,
        travelRouters: [TrailTravelMode: any TrailLegRouting] = [:]
    ) {
        self.store = store
        var providers = travelRouters
        providers[.hiking] = router
        routers = providers
        let drawing = TrailDraft()
        draft = drawing
        finder = TrailPointFinder(source: placeSource)
        elevation = elevationPause.map { pause in
            TrailDraftElevation(draft: drawing, source: elevationSource, pause: pause)
        } ?? TrailDraftElevation(draft: drawing, source: elevationSource)
        namer = TrailStopNamer(source: naming)
        namer.onNamed { [weak self] question, name in
            self?.receiveName(name, for: question)
        }
    }

    /// Reports whether the sheet has a screen pushed, which is the whole of
    /// what decides the pill.
    ///
    /// Written by ``MapSheet`` as a function of its navigation path rather
    /// than as a push event, for the reason
    /// ``PhotoCaptureController/setHostScreenPresent(_:)`` is: a pop's
    /// `onDisappear` arrives only after the animation, which would leave this
    /// pill standing over the map and answering taps for the whole of a back
    /// navigation, and an abandoned back-swipe recomputes to the same answer
    /// rather than leaving it withdrawn for good.
    func setHostScreenPresent(_ present: Bool) {
        guard hasPushedScreen != present else { return }
        hasPushedScreen = present
        refreshAvailability()
    }

    /// Reports whether the maker's screen is the one on top.
    ///
    /// Written from the sheet's path for the reason above, and it has to be:
    /// a tap landing on the map during the pop animation would put down a
    /// waypoint on a trail the hiker has just left.
    ///
    /// Opening restores whatever was left half-drawn, and asks about its legs
    /// — a restored draft comes back as points and a setting, never as
    /// resolved shapes, so the line follows the ground again a moment after it
    /// comes back rather than sitting straight until it is touched.
    ///
    /// Closing gives up on whatever is still in flight. Nothing else is owed:
    /// a point going down and the toggle moving are both written as they
    /// happen. A phase that lets a point be dragged or deleted has to write
    /// here too, or leave the disk one gesture behind.
    func setEditing(_ editing: Bool) {
        guard isEditing != editing else { return }
        isEditing = editing
        if editing {
            restoreIfNeeded()
            resolveLegs()
            // A restored draft is a line whose points this launch has never
            // asked about — and one drawn before names existed has none at
            // all. Asked on open for the reason the heights are.
            namer.nameUnnamed(in: draft.waypoints)
            // A restored draft is a line nobody has measured this launch, and
            // it is a line the hiker is looking at — so the figure is asked
            // for on open exactly as it is asked for after an edit, and
            // arrives a couple of seconds later either way.
            elevation.drawingDidChange()
        } else {
            // Stop this editor's requests. The graph provider retains any
            // download another caller still owns through its waiter count.
            // The generation check also rejects a provider's late answer.
            // A finger cannot survive the screen it was on. A drag left held
            // would put the pin back where it was on the next open, which is
            // right, but the map would have been taken down mid-gesture and
            // never told to stop.
            draft.cancelDrag()
            cancelRouting()
            // Nothing on offer is the hiker's, so nothing survives the screen
            // it was offered on — see ``TrailPointFinder/clear()``.
            finder.clear()
            // A height question is cancelled on the way out too:
            // there is no shared download behind it and nothing else is
            // waiting for it, so a request nobody will read is a request worth
            // dropping. The next open asks again.
            elevation.clear()
            // Cancelled for the same reason, and with the record of what has
            // been asked — see ``TrailStopNamer/clear()``.
            namer.clear()
        }
    }

    /// Asks for the maker. Refused when the pill isn't available, so a tap
    /// that races the withdrawal above cannot push a screen from a map that
    /// has stopped offering one.
    func requestOpen() {
        guard isAvailable else { return }
        openRequest &+= 1
    }

    /// Puts a point down at the end of the line.
    ///
    /// Refused unless the maker is up, which is the same guard
    /// ``PhotoCaptureController/requestCamera()`` makes and for the same
    /// reason: the map's recognizer sees every tap, and the one that arrives
    /// as the screen is leaving must not be the one that changes the trail.
    ///
    /// - Parameter name: what it is called, for a point picked out of the
    ///   search sheet. Empty for a tap on the map, which ``TrailStopNamer``
    ///   describes a moment later.
    func appendWaypoint(at coordinate: CLLocationCoordinate2D, named name: String = "") {
        guard isEditing else { return }
        draft.append(coordinate, named: Self.bounded(name))
        commitLine()
        resolveLegs()
    }

    /// Puts a named place into the row a hiker opened the search sheet from.
    ///
    /// The one verb the sheet has, and it covers both of the things a row can
    /// be when it is tapped: a stop that is already down — which this *moves*,
    /// keeping its place in the line — and the *Add Stop* row at the bottom,
    /// which has no point behind it and appends one. Which of the two is
    /// decided by the sheet's own ``TrailStopSearchTarget``, not here.
    ///
    /// By identity rather than by row, because a sheet is a presentation the
    /// drawing can change underneath: a leg landing while the hiker is typing
    /// does not move any point, but an undo reached from the map's callout
    /// can, and a row index captured when the sheet opened would then name the
    /// wrong stop.
    func placeWaypoint(
        _ id: UUID,
        at coordinate: CLLocationCoordinate2D,
        named name: String
    ) {
        guard isEditing,
              let index = draft.waypoints.firstIndex(where: { $0.id == id }) else { return }
        draft.place(waypointAt: index, at: coordinate, named: Self.bounded(name))
        commitLine()
        resolveLegs()
    }

    /// Puts a point into the middle of a leg, where the tap landed.
    ///
    /// The other meaning a tap on the canvas has, and the one that makes a
    /// drawn trail editable rather than merely extendable: a route that needs
    /// to bend round a spur is fixed by tapping the leg that cuts the corner,
    /// not by starting again. Which of the two a tap means is decided on the
    /// map, by whether it landed on a line — see
    /// ``MapView/Coordinator/addTrailDraftWaypoint(at:in:)``.
    func insertWaypoint(
        at coordinate: CLLocationCoordinate2D,
        intoLegAt index: Int,
        named name: String = ""
    ) {
        guard isEditing else { return }
        draft.insert(coordinate, intoLegAt: index, named: Self.bounded(name))
        commitLine()
        resolveLegs()
    }

    /// Writes what ``TrailStopNamer`` worked out a point is called, and writes
    /// the drawing down with it.
    ///
    /// Not ``commitLine()``: nothing geometric moved, so no leg wants asking
    /// about again and the climb is the number it already was — the same split
    /// marking a place makes, and for the same reason. Not guarded on
    /// ``isEditing`` either, because a name that landed as the screen closed is
    /// still true of the point it is about, and the persist below is what keeps
    /// it; the namer is cancelled on the way out anyway, so this is the race
    /// rather than the ordinary path.
    ///
    /// Refused for a stop that has moved since it was asked about: a drag
    /// keeps the point's id, and the answer is the address of the spot it
    /// left. The namer asks again about where it stands now.
    private func receiveName(_ name: String, for question: TrailStopQuestion) {
        guard let point = draft.waypoints.first(where: { $0.id == question.id }),
              TrailStopQuestion(point) == question else { return }
        draft.describe(waypointWith: question.id, as: name)
        persist()
    }

    /// The bound every name in this app is taken through where it enters — see
    /// ``HikeTitle``. A stop's name arrives from MapKit rather than from a
    /// keyboard, which is the unattended half that bound is for.
    private static func bounded(_ name: String) -> String {
        BoundedText.boundedOrEmpty(name, to: .title)
    }

    /// Takes points out of the line. What a swipe on a row does.
    func removeWaypoints(atOffsets offsets: IndexSet) {
        guard isEditing else { return }
        draft.remove(atOffsets: offsets)
        commitLine()
        resolveLegs()
    }

    /// Reorders the line. What a drag in the list's edit mode commits.
    func reorderWaypoints(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard isEditing else { return }
        draft.moveWaypoints(fromOffsets: offsets, toOffset: destination)
        commitLine()
        resolveLegs()
    }

    /// Walks the line the other way. Hiking turns settled shapes around;
    /// direction-dependent modes ask their provider about the reverse trip.
    func reverse() {
        guard isEditing else { return }
        cancelRouting()
        draft.reverse()
        commitLine()
        resolveLegs()
    }

    /// Joins the end back to the start.
    func closeTheLoop() {
        guard isEditing else { return }
        draft.closeTheLoop()
        commitLine()
        resolveLegs()
    }

    /// Throws the points away and leaves the maker open, which is the
    /// undoable half of the pair ``discard()`` is the other end of.
    func clearDrawing() {
        guard isEditing else { return }
        cancelRouting()
        draft.clearDrawing()
        commitLine()
    }

    // MARK: - Places

    /// Marks a place, and hands back what was marked so the caller can open
    /// the editor on it.
    ///
    /// Returned rather than merely added, because marking a place and naming
    /// it are one gesture from the hiker's side: the callout's *Mark a Place*
    /// puts a pin down and opens the sheet that says what it is. `nil` when
    /// the maker is not up, which is the same guard every other mutation here
    /// makes and for the same reason — the map's recognizer sees every tap.
    ///
    /// Nothing is routed. A place is not on the line, so no leg changes and
    /// OpenStreetMap is asked nothing; this is the one mutation in the feature
    /// that costs a store write and not a request.
    @discardableResult func markPlace(
        at coordinate: CLLocationCoordinate2D,
        named name: String = "",
        symbol: TrailPlaceSymbol? = nil
    ) -> TrailPlace? {
        guard isEditing else { return nil }
        let place = TrailPlace(
            coordinate: coordinate,
            // Bounded where it enters, like every other name in this app —
            // see ``HikeTitle``. A place's name can arrive from a search
            // result rather than from a keyboard, which is exactly the
            // unattended half that bound exists for.
            name: BoundedText.boundedOrEmpty(name, to: .title),
            symbol: symbol
        )
        draft.addPlace(place)
        commit()
        return place
    }

    /// Writes an edited place back.
    func updatePlace(_ place: TrailPlace) {
        guard isEditing else { return }
        draft.updatePlace(place)
        commit()
    }

    /// Moves a place. What a drag on its pin commits.
    func movePlace(id: UUID, to coordinate: CLLocationCoordinate2D) {
        guard isEditing else { return }
        draft.movePlace(id: id, to: coordinate)
        commit()
    }

    /// Asks the maker's screen to open the editor on a place.
    ///
    /// Not guarded on ``isEditing``, unlike every mutation here, and for the
    /// reason ``PhotoMapPinController/select(_:)`` is not guarded either: the
    /// request has to survive the moment it is made in. It is raised from a
    /// callout on the map, and what answers it is a sheet on a screen — the
    /// screen decides whether it is still interested.
    func requestPlaceEditor(for id: UUID) {
        nextPlaceEditorToken += 1
        placeEditorRequest = TrailPlaceEditRequest(
            placeID: id,
            token: nextPlaceEditorToken
        )
    }

    func removePlace(id: UUID) {
        guard isEditing else { return }
        draft.removePlace(id: id)
        commit()
    }

    // MARK: - Places from OpenStreetMap

    /// Asks what is on the ground near the drawing: what the maker's *Search
    /// this area* pill runs.
    ///
    /// The one tap in this feature that spends a request of its own — every
    /// other one spends a leg. Guarded on ``isEditing`` like every mutation
    /// here, although this changes nothing: the pill is on the map, the map's
    /// controls outlive the screen they belong to by the length of a pop
    /// animation, and a search that landed after the maker closed would be a
    /// page of candidates drawn over somebody's library.
    func searchNearbyPlaces() {
        guard isEditing else { return }
        finder.search(along: draft.routeCoordinates, avoiding: draft.places)
    }

    /// Marks one of the places OpenStreetMap offered.
    ///
    /// **An unnamed candidate is named after what it is**, which is the whole
    /// of what adopting adds to it: four fifths of the best answers this
    /// feature has carry no name at all — see ``TrailPointQuery`` — and a
    /// trail saved with six places called nothing is a trail whose GPX, whose
    /// detail screen and whose published listing all read as a row of blanks.
    /// ``TrailPlace/displayName`` already falls back to the symbol's word on
    /// screen; this is what writes it down, so the hiker can then change it.
    ///
    /// The candidate leaves the offer as it becomes a place, so the pin under
    /// the new pin goes with it.
    ///
    /// - Returns: the place that was marked, so the caller can open the editor
    ///   on it — the same pair ``markPlace(at:named:symbol:)`` makes.
    @discardableResult func adopt(_ candidate: TrailPlace) -> TrailPlace? {
        guard isEditing else { return nil }
        let marked = markPlace(
            at: candidate.clCoordinate,
            named: candidate.name.isEmpty ? candidate.symbol?.label ?? "" : candidate.name,
            symbol: candidate.symbol
        )
        guard marked != nil else { return nil }
        finder.take(candidate.id)
        return marked
    }

    /// Takes places out of the list a screen is showing. What a swipe on a
    /// place row does — the offsets are into the ranked list, not the marked
    /// one; see ``TrailDraft/removePlaces(atRowOffsets:)``.
    func removePlaces(atRowOffsets offsets: IndexSet) {
        guard isEditing else { return }
        draft.removePlaces(atRowOffsets: offsets)
        commit()
    }

    // MARK: - History

    func undo() {
        guard isEditing else { return }
        draft.undo()
        commitLine()
        resolveLegs()
    }

    func redo() {
        guard isEditing else { return }
        draft.redo()
        commitLine()
        resolveLegs()
    }

    // MARK: - A point under a finger

    /// Takes hold of the point at `index`. Answers whether there was one.
    ///
    /// Nothing is written and nothing is asked between here and
    /// ``endDrag()``: a drag is one edit, however far the finger travels, and
    /// a store write or an Overpass request per frame would be neither. See
    /// ``TrailDraft`` for the channel the movement itself goes down.
    func beginDrag(ofWaypointAt index: Int) -> Bool {
        guard isEditing else { return false }
        return draft.beginDrag(ofWaypointAt: index)
    }

    func dragWaypoint(to coordinate: CLLocationCoordinate2D) {
        draft.moveDrag(to: coordinate)
    }

    /// Lets go. The one point in a drag where the drawing changes, the draft
    /// is written down and the two legs either side are asked about.
    ///
    /// - Returns: whether the point moved at all, so the map can tell a drag
    ///   from a press that went nowhere and answer only the first with a
    ///   haptic.
    @discardableResult func endDrag() -> Bool {
        guard draft.endDrag() else { return false }
        commitLine()
        resolveLegs()
        return true
    }

    /// Puts the held point back and asks nothing — a cancelled gesture is not
    /// an edit.
    func cancelDrag() {
        draft.cancelDrag()
    }

    /// Turns path-following on or off, and re-resolves what is already drawn.
    ///
    /// **Re-resolve, not discard.** Turning it off straightens the legs but
    /// keeps the points; turning it back on asks again, and the router answers
    /// the ones it has already been asked from memory, so the line comes back
    /// the way it was without a single request. That is what makes the toggle
    /// something a hiker can try rather than something they have to commit to.
    func setSnapsToPaths(_ snapping: Bool) {
        guard draft.snapsToPaths != snapping else { return }
        cancelRouting()
        draft.setSnapsToPaths(snapping)
        commitLine()
        resolveLegs()
    }

    /// Asks again about legs whose routing provider was temporarily unavailable.
    ///
    /// The only thing that does: an ordinary pass leaves a refusal alone, for
    /// the reason the file header gives.
    func retryRefusedLegs() {
        resolveLegs(retryingRefusals: true)
    }

    /// Throws the drawing away: what Cancel does, and what a completed Save
    /// does with what it has just turned into a hike.
    func discard() {
        cancelRouting()
        draft.clear()
        store?.clear()
        // The heights go with the line they were read for. Nothing else would
        // clear them: the drawing is emptied rather than edited, and an empty
        // draft is never measured, so a figure left here would be the climb of
        // a trail that has just been saved or thrown away.
        elevation.clear()
        // And the names go with the points they were about, for the same
        // reason: a question still out about one of them has nothing left to
        // answer.
        namer.clear()
    }

    private func restoreIfNeeded() {
        // Only into an empty draft. Leaving the maker and coming back within a
        // launch finds the line still in memory, and overwriting it with the
        // copy on disk would undo whatever was added after the last write.
        guard draft.isEmpty, let stored = store?.load(), !stored.isEmpty else { return }
        draft.replace(
            with: stored.waypoints,
            places: stored.places,
            snapsToPaths: stored.snapsToPaths,
            travelMode: stored.travelMode
        )
    }

    /// What every edit to the **line** ends with: everything ``commit()``
    /// does, and the heights asked for again once the drawing settles.
    ///
    /// Two methods rather than one, and the split is about a bill. Marking a
    /// place, renaming it or dragging its pin changes no geometry, so the
    /// climb is the number it already was — and a hiker marking the six
    /// springs along a climb would otherwise spend six billed calls being told
    /// so. Every edit that moves the line goes through here; everything else
    /// goes through ``commit()``.
    private func commitLine() {
        commit()
        elevation.drawingDidChange()
        // Every edit to the line, rather than only the two that add a point:
        // a restore brings back points nothing has named, a delete can leave a
        // named point in flight beside an unnamed one, and asking after all of
        // them costs nothing once each has been asked once. See
        // ``TrailStopNamer/nameUnnamed(in:)``.
        namer.nameUnnamed(in: draft.waypoints)
    }

    /// What every edit ends with: the drawing written down, and whatever
    /// OpenStreetMap offered put back in its place along the new line.
    ///
    /// One method rather than two calls at fourteen sites, because forgetting
    /// either of them is invisible — a draft one gesture behind on disk, or a
    /// candidate still labelled with the distance it sat at two points ago.
    /// The re-rank costs nothing at all while nothing is on offer, which is
    /// nearly always; see ``TrailPointFinder/rerank(along:)``.
    private func commit() {
        persist()
        // Guarded rather than left to the re-rank's own guard: what is being
        // avoided is building the argument, which is the whole flattened line.
        // See ``TrailPointFinder/isOffering``.
        guard finder.isOffering else { return }
        finder.rerank(along: draft.routeCoordinates)
    }

    private func persist() {
        guard let store else { return }
        guard !draft.isEmpty else {
            store.clear()
            return
        }
        store.save(
            waypoints: draft.waypoints,
            places: draft.places,
            snapsToPaths: draft.snapsToPaths,
            travelMode: draft.travelMode
        )
    }

    private func refreshAvailability() {
        let available = !hasPushedScreen
        guard isAvailable != available else { return }
        isAvailable = available
    }

}

extension TrailDraftController {
    /// One queue across taps, so newly appended stops cannot start another
    /// network request beside the current one. A generation also rejects an
    /// old answer if a provider ignores cancellation while the mode changes.
    private func resolveLegs(retryingRefusals: Bool = false) {
        guard let router = routers[draft.travelMode], isEditing else { return }
        let pending = draft
            .legsAwaitingRoutes(retryingRefusals: retryingRefusals)
            .filter { ends in !legsInFlight.contains(ends) }
        guard !pending.isEmpty else { return }
        legsInFlight.formUnion(pending)
        routingQueue.append(contentsOf: pending)
        draft.beginRouting(pending)
        guard routingTask == nil else { return }
        let generation = routingGeneration
        routingTask = Task { [weak self] in
            while let ends = self?.nextRoutingLeg(generation: generation) {
                let route = await router.route(ends)
                guard !Task.isCancelled, let self,
                      routingGeneration == generation else { return }
                receive(route, for: ends)
            }
        }
    }

    private func nextRoutingLeg(generation: Int) -> TrailLegEnds? {
        guard generation == routingGeneration else { return nil }
        while !routingQueue.isEmpty {
            let ends = routingQueue.removeFirst()
            if draft.legs.contains(where: { $0.ends == ends && $0.snap.isRouting }) {
                return ends
            }
            legsInFlight.remove(ends)
        }
        routingTask = nil
        return nil
    }

    private func cancelRouting() {
        routingGeneration &+= 1
        routingTask?.cancel()
        routingTask = nil
        routingQueue = []
        legsInFlight.removeAll()
        draft.stopRouting()
    }

    func setTravelMode(_ mode: TrailTravelMode) {
        guard isEditing, draft.travelMode != mode else { return }
        cancelRouting()
        draft.setTravelMode(mode)
        commitLine()
        resolveLegs()
    }

    /// Takes one answer, whatever has happened to the drawing meanwhile.
    ///
    /// The draft decides whether the answer still applies: it is matched
    /// against the leg's two ends rather than its place in the list, so a
    /// hiker who added three more points while this was in flight still gets
    /// it, and one who turned snapping off does not. See
    /// ``TrailDraft/apply(_:to:)``.
    ///
    /// **A cancelled question has to be given back as well as released.**
    /// Cancellation is not a failure and is not drawn as one, but a leg left
    /// marked as waiting is never asked about again — ``TrailDraft/legsAwaitingRoutes(retryingRefusals:)``
    /// skips it — so it would stay dashed for the rest of the drawing.
    /// A routing edit can also cancel the pass. Its generation check prevents
    /// this receiver from publishing a provider answer that arrives anyway.
    private func receive(_ route: TrailLegRoute?, for ends: TrailLegEnds) {
        legsInFlight.remove(ends)
        // Either way the line has stopped waiting on this leg, and the climb
        // is asked for again from the moment it does. A leg given back
        // unanswered is the same news as one answered, for this purpose: the
        // drawing has settled by exactly one leg, and the debounce in front of
        // the question is what folds a run of them into one — see
        // ``TrailDraftElevation``.
        defer { elevation.drawingDidChange() }
        guard let route else {
            draft.abandonRouting(of: ends)
            return
        }
        draft.apply(route, to: ends)
        // A leg that has just found a path is a line that has just changed
        // shape, without the hiker having touched anything — so anything on
        // offer beside it is now at a different distance along it. Nothing is
        // written down here: a resolved shape is re-derivable and deliberately
        // not part of the stored draft.
        guard finder.isOffering else { return }
        finder.rerank(along: draft.routeCoordinates)
    }
}
