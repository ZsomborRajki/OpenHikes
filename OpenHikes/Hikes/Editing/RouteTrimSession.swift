//
//  RouteTrimSession.swift
//  OpenHikes
//
//  One visit to *Edit Route* on a hike that was recorded or imported: the
//  whole line it works on, where the two cuts stand on it, how each stretch
//  to check is answered, and what the map draws of all three.
//
//  ## The whole line
//
//  Not the line the hike has now but the one it was saved with, put together
//  under the answers that stand, with the hike's trim as two cuts on it — see
//  ``RouteEditSources``. Changing an answer puts the line together again and
//  moves the cuts with the ground they stood on.
//
//  ## Whose it is
//
//  ``SheetPresentation`` keeps one for as long as the screen's route is on
//  the path, for the reason it keeps every pushed screen's state: a turn of
//  the phone builds the screen again in the other host, and the cuts a hiker
//  placed must not go back to the ends. The pop that takes the screen away
//  ends it, which is what takes its handles off the map.
//
//  ## Two readers, neither a screen's body
//
//  The cuts move at drag frequency, from the chart in the sheet and from the
//  handles on the map. The map reads them directly (see `MapRouteTrim.swift`),
//  and in the sheet only the leaf views that draw them do, so a drag redraws
//  the chart, the figures and the Save button and nothing above them — see
//  *Render isolation, in practice* in `AGENTS.md`. Both cuts are `Double`s,
//  which Observation filters a same-value write of, so a handle held still
//  wakes nothing.
//

import Algorithms
import CoreLocation
import Foundation
import MapKit
import OpenHikesData
import RealModule

@Observable
final class RouteTrimSession {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    /// The least a trim may leave: two handles closer than this are one
    /// place, and a line that short is no hike.
    static let minimumKeptMeters = 50.0
    /// How near its end a cut has to be to count as standing on it.
    static let endToleranceMeters = 0.5
    /// The least a stretch picked out may be: shorter than the least a trim
    /// leaves, because a tangle of fixes at a rest is a stretch worth
    /// straightening.
    static let minimumStretchMeters = 10.0

    /// Moves when the whole line is put together anew — a load, or an answer
    /// changed — which is rare; the map and the screen read ``line`` when it
    /// does.
    private(set) var lineRevision = 0
    @ObservationIgnored private(set) var line: RouteTrimLine?
    /// What the visit works from. Kept to tell the same hike again from a
    /// new one, and for what a save compares against.
    @ObservationIgnored private(set) var sources: RouteEditSources?
    /// Moves each time the visit starts over on new ``sources``: which of
    /// them the screen is showing. *Looks Good* names the one it was drawn
    /// over, so a look is never taken at sources that landed after the tap
    /// — see ``confirmChecks(in:tappedOn:)``.
    private(set) var sourcesRevision = 0

    /// Where the kept line begins and ends, in metres along ``line``.
    private(set) var startMeters = 0.0
    private(set) var endMeters = 0.0
    /// The pauses standing on the line's own two ends that the cuts take
    /// off, which no distance along the line can say — see
    /// ``RouteTrim/EndPauses``. Only an offer sets one
    /// (``takeOff(_:at:)``); placing that handle by hand clears it.
    private(set) var pausesTakenOff: RouteTrim.EndPauses = []

    /// What has been done to the whole line beyond its cuts, in the order it
    /// was done — see ``RouteStep`` and `RouteTrimSession+Steps.swift`. The
    /// hike's own when the visit opens.
    private(set) var steps: [RouteStep] = []
    /// Whether the two handles are picking a stretch out rather than cutting
    /// the ends off: what *Change a Stretch* turns on. The cuts the hiker
    /// had placed are a step by then, so nothing reads the handles as cuts.
    private(set) var isSelectingStretch = false
    /// Whether the line the cuts leave already ends where it began
    /// (``RouteSteps/endsMeet(_:)``), so there is nothing to double back or
    /// close. Written as the cuts move, and filtered when it stays the same,
    /// so a handle dragged wakes the menu that reads it only when it turns.
    private(set) var keptEndsMeet = false
    /// Whether the handles picking a stretch out have the whole line between
    /// them, which is nothing to take out. Kept as ``keptEndsMeet`` is.
    private(set) var picksWholeLine = false
    /// Whether the start handle marks where a loop could begin instead: the
    /// line is a loop, its start is cut and its end is not. Kept as
    /// ``keptEndsMeet`` is, for the menu that reads it.
    private(set) var canStartLoopAtCut = false
    /// Whether a path is being asked for, which shows a spinner beside the
    /// button that asked.
    var isRouting = false
    /// Whether a step is being worked out and drawn, which holds every
    /// control that changes the line: one change at a time, each made on
    /// the line the one before it left — see ``holdingSteps(_:)``.
    private(set) var isMakingStep = false

    /// The stretches to check, as the hiker has answered them. Empty for a
    /// hike with none. An answer is here the moment it is given, and the
    /// line catches up with it — see ``settled()``.
    private(set) var checks: [RouteCheck] = []
    /// The stretch the hiker is looking at, which the map picks out.
    private(set) var focusedCheckID: Int?
    /// Whether the hike still asks for a look — see ``RouteEdit/isOwedALook``.
    private(set) var isOwedALook = false
    /// Whether the line the editor opened on has an original to go back to,
    /// which is what *Revert to Original* is offered for. A record that no
    /// longer describes the hike's line has none — see ``RouteEditSources``.
    private(set) var hasOriginal = false
    /// How long the line the hike has now is, which the figures measure
    /// what a save would take off, or give back, against.
    @ObservationIgnored private(set) var currentLengthMeters = 0.0
    /// How long the line the hike has now was being recorded, carried
    /// through its steps as a save carries the edited line's — see
    /// ``EditedLine/recordedSeconds(of:cutTo:steps:)``. What a save measures
    /// the time it takes off the recording's own walk against.
    @ObservationIgnored private(set) var currentRecordedSeconds: TimeInterval = 0
    /// How long each stretch is under each of its answers, by the stretch's
    /// id: what tells two answers apart in the list.
    @ObservationIgnored private(set) var choiceMeters: [Int: [RouteCheck.Choice: Double]] = [:]
    /// The stretches of the hike's own line, as the map still draws it, that
    /// an answer changed in this visit has replaced. The map covers them.
    @ObservationIgnored private(set) var staleStretches: [[CLLocationCoordinate2D]] = []

    /// Whether a save or a revert is under way, which holds the buttons.
    var isSaving = false
    /// Why the last one did not land, while its alert is up.
    var refusal: RouteEditRefusal?

    /// The Health replacement the last save or revert started, if it owed
    /// one — see ``RouteEditWorkout``. Kept so a suite can wait for it.
    @ObservationIgnored var workoutReplacement: Task<Void, Never>?

    @ObservationIgnored private weak var preview: RouteTrimPreview?
    @ObservationIgnored private(set) var isEnded = false
    /// Which load is the newest, so an older one landing late is dropped,
    /// and a rebuild that a load overtook with it.
    @ObservationIgnored private var loads = 0
    /// The rebuild under way, if any, and which one is the newest — see
    /// ``catchUp()``.
    @ObservationIgnored private var rebuilding: Task<Void, Never>?
    @ObservationIgnored private var rebuilds = 0
    /// Where each cut was last placed, and on which line: by the hike's own
    /// trim, or by hand. An answer moves a cut from here, never from where
    /// the answer before it left the cut, so changing an answer and changing
    /// it back puts the cut back where it was.
    @ObservationIgnored private var anchors: [RouteTrimHandle: (line: RouteTrimLine, meters: Double)] = [:]
    /// The ends the hike's own trim took something off when the visit
    /// opened, which is what a save tells a moved end from a kept one by —
    /// see ``EditedLine/ClockEnd``.
    @ObservationIgnored private(set) var cutWhenLoaded: Set<RouteTrimHandle> = []
    /// Whether the line the hike has, which is the one the map draws for it,
    /// is the whole line this visit opened on: nothing was cut off it before.
    @ObservationIgnored private var ownLineIsWhole = true
    /// Whether the cuts the hiker had placed became a step only so a stretch
    /// could be picked out, with nothing made on them since: leaving the
    /// stretch alone gives them back as cuts.
    @ObservationIgnored private(set) var trimStepIsOnlyForTheStretch = false
    /// Who draws a path, and who knows where the junctions are. `nil` on a
    /// launch with neither, where a stretch can still be straightened or
    /// taken out — see ``RouteReroute``.
    @ObservationIgnored var routing: RouteReroute.Services?
    /// How far along the line each junction it passes is, once that is
    /// known: what a pull on the map is bounded by.
    @ObservationIgnored var junctionMeters: [Double] = []
    @ObservationIgnored private var junctionSearch: Task<Void, Never>?

    var totalMeters: Double { line?.totalMeters ?? 0 }

    /// Whether either cut takes anything off the whole line.
    var isTrimmed: Bool { cuts(.start) || cuts(.end) }

    var keptRange: ClosedRange<Double> { startMeters...max(startMeters, endMeters) }

    /// The cuts as a save would store them: `nil` while neither takes
    /// anything off, which is no trim at all.
    var trim: ClosedRange<Double>? { isTrimmed ? keptRange : nil }

    /// The pieces of the line with the answers that stand now.
    var assembly: RouteAssembly? {
        guard var pieces = sources?.edit?.assembly else { return nil }
        pieces.checks = checks
        return pieces
    }

    /// Whether a save would change the hike: a cut moved, an answer, or a
    /// step made or undone. Not while a stretch is being picked out: what
    /// is done to it comes first, or leaving it alone.
    var hasChanges: Bool {
        // Read before anything can return: the Save button asks this before
        // the line has loaded, and what it read then is all it is told of.
        // With nothing read, it never heard that there was a line, or that a
        // cut on it had moved.
        _ = lineRevision
        guard let sources, line != nil, !isSelectingStretch else { return false }
        return steps != (sources.edit?.routeSteps ?? [])
            || checks != (sources.edit?.assembly?.checks ?? [])
            || !Self.isSame(trim, sources.edit?.trim)
            || pausesTakenOff != (sources.edit?.endPausesTakenOff ?? [])
    }

    /// Whether the map has to draw the kept line itself, because the hike's
    /// own line on it is not that line: an earlier trim cut ground off that
    /// a handle can now be dragged back over, or the line is drawn under an
    /// answer changed in this visit.
    var drawsKeptLine: Bool {
        guard let sources, let line else { return false }
        return !ownLineIsWhole || line.steps != (sources.edit?.routeSteps ?? [])
            || line.choices != RouteTrimLine.choices(of: sources.edit?.assembly?.checks ?? [])
    }

    /// The ways `check` can be drawn on this device, in the order it offers
    /// them — see ``RouteEditSources/choices(of:)``.
    func choices(of check: RouteCheck) -> [RouteCheck.Choice] {
        sources?.choices(of: check) ?? check.availableChoices
    }

    /// Whether two trims are the same cuts: both none, or each end within
    /// ``endToleranceMeters`` of the other's. Internal for the stored-cuts
    /// suite, which holds it to the boundary.
    static func isSame(_ one: ClosedRange<Double>?, _ other: ClosedRange<Double>?) -> Bool {
        guard let one, let other else { return one == nil && other == nil }
        return isSameEnd(one.lowerBound, other.lowerBound) && isSameEnd(one.upperBound, other.upperBound)
    }

    /// Whether two cuts stand at one place on the line. Never for an end
    /// that is not finite, even beside an equal one: `isApproximatelyEqual`
    /// calls two equal infinities equal, and an infinite cut is no place.
    private static func isSameEnd(_ one: Double, _ other: Double) -> Bool {
        one.isFinite && other.isFinite
            && one.isApproximatelyEqual(to: other, absoluteTolerance: endToleranceMeters)
    }

    // MARK: The line

    /// Starts over on `sources`: the whole line under the hike's answers,
    /// with the hike's trim as its cuts. The same sources again change
    /// nothing, so coming back to the screen keeps what was moved.
    func load(_ sources: RouteEditSources) async {
        guard sources.current.count > 1, sources != self.sources else { return }
        if sources.isMissingOriginal || sources.isMissingTrace || sources.isUnreadable {
            refusal = .notHereYet
            return
        }
        loads += 1
        let mine = loads
        let saved = sources.edit?.assembly
        let made = sources.edit?.routeSteps ?? []
        guard let measured = try? await RouteTrimLine.measuring(sources, under: saved, steps: made),
              !Task.isCancelled, mine == loads
        else { return }
        // Everything measured before anything is shown: the list draws each
        // answer's length the moment it has the answers.
        let lengths = await Self.lengths(in: sources, measured: measured)
        guard !Task.isCancelled, mine == loads else { return }
        (currentLengthMeters, choiceMeters, currentRecordedSeconds) = lengths
        self.sources = sources
        sourcesRevision += 1
        checks = saved?.checks ?? []
        steps = made
        isSelectingStretch = false
        trimStepIsOnlyForTheStretch = false
        junctionMeters = []
        isOwedALook = sources.edit?.isOwedALook ?? false
        hasOriginal = sources.edit?.original != nil
        focusedCheckID = nil
        staleStretches = []
        ownLineIsWhole = measured.route == sources.current
        line = measured
        let stored = sources.edit?.trim
        startMeters = min(max(stored?.lowerBound ?? 0, 0), measured.totalMeters)
        endMeters = min(max(stored?.upperBound ?? measured.totalMeters, startMeters), measured.totalMeters)
        pausesTakenOff = sources.edit?.endPausesTakenOff ?? []
        anchors = [.start: (measured, startMeters), .end: (measured, endMeters)]
        cutWhenLoaded = Set([RouteTrimHandle.start, .end].filter { cuts($0) }).union(measured.endsMovedBySteps)
        noteCuts()
        lineRevision += 1
        lookForJunctions()
    }

    /// Reads where the new line's junctions are, for the next pull on the
    /// map — see ``findJunctions()``. On its own time: nothing waits for it.
    private func lookForJunctions() {
        junctionSearch?.cancel()
        junctionSearch = Task { [weak self] in await self?.findJunctions() }
    }

    /// A hike with nothing but its line — see ``load(_:)``.
    func load(_ route: [RouteCoordinate]) async {
        await load(RouteEditSources(current: route))
    }

    // MARK: The cuts

    func position(of handle: RouteTrimHandle) -> Double {
        switch handle {
        case .start: startMeters
        case .end: endMeters
        }
    }

    /// Whether the cut at `handle` takes anything off: it has left its end
    /// of the line, or takes off the pause standing on it.
    func cuts(_ handle: RouteTrimHandle) -> Bool {
        // Picking a stretch out, the handles cut nothing.
        guard !isSelectingStretch else { return false }
        if pausesTakenOff.contains(handle.endPause) { return true }
        return switch handle {
        case .start: startMeters > 0
        case .end: endMeters < totalMeters
        }
    }

    /// Moves one cut, held at least ``minimumKeptMeters`` short of the other
    /// and inside the line. A handle moved by hand stands where it was put,
    /// so it no longer takes off a pause on its end. A touch that leaves it
    /// where it was, as the chart's drag makes on the way down, moves
    /// nothing.
    func move(_ handle: RouteTrimHandle, to meters: Double) {
        let total = totalMeters
        guard total > 0, meters.isFinite else { return }
        let gap = min(isSelectingStretch ? Self.minimumStretchMeters : Self.minimumKeptMeters, total)
        let before = position(of: handle)
        switch handle {
        case .start: startMeters = min(max(meters, 0), max(endMeters - gap, 0))
        case .end: endMeters = max(min(meters, total), min(startMeters + gap, total))
        }
        let moved = position(of: handle)
        guard moved != before else { return }
        if let line { anchors[handle] = (line, moved) }
        if pausesTakenOff.contains(handle.endPause) { pausesTakenOff.remove(handle.endPause) }
        noteCuts()
    }

    /// Says what the cuts now stand on, for what reads it rather than them —
    /// see ``keptEndsMeet`` and ``picksWholeLine``.
    private func noteCuts() {
        guard let line, let start = keptSpot(of: .start), let end = keptSpot(of: .end) else { return }
        keptEndsMeet = RouteSteps.endsMeet(start.coordinate, end.coordinate)
        picksWholeLine = isSelectingStretch && startMeters <= Self.endToleranceMeters
            && endMeters >= line.totalMeters - Self.endToleranceMeters
        canStartLoopAtCut = line.shape == .loop && !isSelectingStretch && cuts(.start) && !cuts(.end)
            && pausesTakenOff.isEmpty
    }

    /// Runs `change` as the one change to the line under way, holding every
    /// control that would make another — see ``isMakingStep``. `nil` when
    /// another is under way already.
    @discardableResult func holdingSteps<Result>(_ change: () async -> Result) async -> Result? {
        guard !isMakingStep else { return nil }
        isMakingStep = true
        defer { isMakingStep = false }
        return await change()
    }

    /// Cuts `stretch` off the end of the line `handle` stands on: what the
    /// offer under *Not on Foot* does — see ``RouteCarriedEnds``.
    ///
    /// A drive that ends the line paused, with only the fix it took up again
    /// on after it, has no length on the line, so its inner edge is the
    /// line's own end. The cut stands there, and takes off the pause.
    func takeOff(_ stretch: RouteCarriedEnds.Stretch, at handle: RouteTrimHandle) {
        let edge = Self.innerEdge(of: stretch, at: handle)
        move(handle, to: edge)
        let isOnTheEnd = switch handle {
        case .start: edge <= 0
        case .end: edge >= totalMeters
        }
        if isOnTheEnd {
            pausesTakenOff.insert(handle.endPause)
            noteCuts()
        }
    }

    /// Whether the cut at `handle` already takes `stretch` off: it stands at
    /// the stretch's inner edge or past it, and is a cut.
    func hasTakenOff(_ stretch: RouteCarriedEnds.Stretch, at handle: RouteTrimHandle) -> Bool {
        let edge = Self.innerEdge(of: stretch, at: handle)
        let isPast = switch handle {
        case .start: startMeters >= edge
        case .end: endMeters <= edge
        }
        return isPast && cuts(handle)
    }

    /// The edge of `stretch` the walk is on.
    private static func innerEdge(of stretch: RouteCarriedEnds.Stretch, at handle: RouteTrimHandle) -> Double {
        switch handle {
        case .start: stretch.range.upperBound
        case .end: stretch.range.lowerBound
        }
    }

    /// Slides one cut along the line towards where a finger is on the map.
    func move(_ handle: RouteTrimHandle, toward coordinate: CLLocationCoordinate2D) {
        guard let meters = line?.distance(nearest: coordinate, around: position(of: handle)) else { return }
        move(handle, to: meters)
    }

    // MARK: The map

    /// Puts the cuts on the map. An ended session is never shown again: the
    /// pop that ended it builds its screen once more on the way out.
    func show(on preview: RouteTrimPreview) {
        guard !isEnded else { return }
        self.preview = preview
        preview.present(self)
    }

    /// Takes the cuts off the map, for good — see the file header — and
    /// stops reading the line's junctions, which may be asking Overpass.
    func end() {
        isEnded = true
        junctionSearch?.cancel()
        preview?.withdraw(self)
    }
}

// What a visit does beyond placing its two cuts. An extension rather than
// more of the class for its length alone; in this file because it writes the
// state the class keeps to itself.
extension RouteTrimSession {
    // MARK: The stretches to check

    /// Picks a stretch out on the map, or none.
    func focus(onCheck id: Int?) {
        guard focusedCheckID != id else { return }
        focusedCheckID = id
    }

    /// Answers for a stretch. The answer stands at once; the whole line is
    /// put together again under it, and each cut goes back to the ground
    /// it was placed on — see ``anchors``.
    func choose(_ choice: RouteCheck.Choice, forCheck id: Int) async {
        // An answer puts the line together again under the steps made on
        // it, whose distances were measured on the line the old answer
        // drew: with a step made, the answers stand.
        guard line != nil, !isSaving, !isMakingStep, steps.isEmpty,
              let index = checks.firstIndex(where: { $0.id == id }),
              checks[index].choice != choice,
              choices(of: checks[index]).contains(choice)
        else { return }
        checks[index].choice = choice
        focusedCheckID = id
        await catchUp()
    }

    /// Puts the line together again under ``checks``, after any rebuild
    /// already under way and never beside it. Each takes the answers as they
    /// stand when it begins, so one given while another is being drawn is
    /// not lost, and the last answer given is the one the line ends under.
    private func catchUp() async {
        rebuilds += 1
        let mine = rebuilds
        let previous = rebuilding
        let next = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await rebuildUnderChecks()
            // The newest lets ``settled()`` go; an older one leaves it
            // waiting on the newest.
            if rebuilds == mine { rebuilding = nil }
        }
        rebuilding = next
        await next.value
    }

    /// Waits until the line is drawn under every answer given: what Save and
    /// *Looks Good* do first.
    func settled() async {
        while let pending = rebuilding { await pending.value }
    }

    private func rebuildUnderChecks() async {
        guard let sources, let before = line, var pieces = sources.edit?.assembly else { return }
        pieces.checks = checks
        let wanted = RouteTrimLine.choices(of: pieces.checks)
        guard wanted != before.choices else { return }
        let loaded = loads
        guard let after = try? await RouteTrimLine.measuring(sources, under: pieces), loaded == loads else { return }
        staleStretches = Self.staleStretches(of: pieces, in: sources)
        line = after
        let start = anchors[.start].map { $0.line.meters(matching: $0.meters, on: after, for: .start) } ?? 0
        let end = anchors[.end].map { $0.line.meters(matching: $0.meters, on: after, for: .end) } ?? after.totalMeters
        startMeters = min(max(start, 0), after.totalMeters)
        endMeters = min(max(end, startMeters), after.totalMeters)
        noteCuts()
        // The junctions a pull is bounded by were measured along the line
        // the old answer drew.
        junctionMeters = []
        lineRevision += 1
        lookForJunctions()
    }

    /// The length of the hike's line, and of every stretch under every
    /// answer it can take; and the recorded time of the hike's line, from
    /// the whole line it was cut from, `measured`.
    @concurrent
    nonisolated private static func lengths(
        in sources: RouteEditSources,
        measured: RouteTrimLine
    ) async -> (current: Double, choices: [Int: [RouteCheck.Choice: Double]], recorded: TimeInterval) {
        var choices: [Int: [RouteCheck.Choice: Double]] = [:]
        for check in sources.edit?.assembly?.checks ?? [] {
            for choice in sources.choices(of: check) {
                let stretch = RouteAssembly.stretch(of: check, choosing: choice, saved: sources.saved, raw: sources.raw)
                choices[check.id, default: [:]][choice] = stretch.lengthMeters
            }
        }
        let recorded = EditedLine.recordedSeconds(
            of: measured.route,
            cutTo: sources.current,
            steps: EditedLine.Steps(recordedSeconds: measured.recordedSeconds)
        )
        return (sources.current.lengthMeters, choices, recorded)
    }

    /// Each stretch whose answer differs from the hike's, as the hike's own
    /// line draws it. A handful of stretches, each a slice.
    private static func staleStretches(
        of assembly: RouteAssembly?,
        in sources: RouteEditSources
    ) -> [[CLLocationCoordinate2D]] {
        guard let assembly else { return [] }
        let stored = sources.edit?.assembly?.checks ?? []
        return assembly.checks.compactMap { check in
            guard let before = stored.first(where: { $0.id == check.id }), before.choice != check.choice else {
                return nil
            }
            return RouteAssembly.stretch(of: before, saved: sources.saved, raw: sources.raw).map(\.clCoordinate)
        }
    }

    /// Takes `looked` as what the visit works from, where the hike's edit
    /// record has changed under it and its line has not: the stretches'
    /// looks, kept on the answers that stand in this visit.
    func adopt(_ looked: RouteEditSources) {
        guard looked.current == sources?.current else { return }
        let stored = looked.edit?.assembly?.checks ?? []
        sources = looked
        isOwedALook = looked.edit?.isOwedALook ?? false
        checks = checks.map { check in
            var merged = check
            if let saved = stored.first(where: { $0.id == check.id }) { merged.isChecked = saved.isChecked }
            return merged
        }
    }

    // MARK: Saving

    /// The line the cuts and the answers leave, measured for a save — see
    /// ``EditedLine``. `nil` while nothing has changed. Waits for the line
    /// to be drawn under every answer given first.
    func editedLine() async -> EditedLine? {
        await settled()
        // A line drawn under other answers than the ones it would be saved
        // with is no line to keep.
        guard let line, let sources, hasChanges, line.choices == RouteTrimLine.choices(of: checks),
              line.steps == steps, !isSelectingStretch
        else { return nil }
        var pieces = assembly
        // A save is a look: the hiker has had every stretch in front of them.
        for index in (pieces?.checks ?? []).indices { pieces?.checks[index].isChecked = true }
        let cuts = EditedLine.Cuts(range: trim, takingOff: pausesTakenOff)
        return await Self.edited(
            line,
            cuts: cuts,
            assembly: pieces,
            replacing: sources.current,
            cutBefore: cutWhenLoaded,
            recordedBefore: currentRecordedSeconds
        )
    }

    // MARK: Steps

    /// Draws the line again with `next` made on it, and puts the cuts where
    /// `cuts` says: on the line's ends unless a step that was a cut is being
    /// given back as one. The one place ``steps`` changes after a load.
    ///
    /// - Parameter isNewStep: whether the last of `next` is a step being
    ///   made, which has to change the line it is made on to be kept.
    /// - Returns: whether the line was drawn. A load that overtook it, or a
    ///   list that leaves the very line there was, changes nothing.
    @discardableResult func redraw(
        with next: [RouteStep],
        cuts: EditedLine.Cuts = EditedLine.Cuts(),
        selectingStretch: Bool = false,
        trimStepIsOnlyForTheStretch onlyForTheStretch: Bool = false,
        isNewStep: Bool = false
    ) async -> Bool {
        await settled()
        guard let sources, let before = line else { return false }
        var pieces = sources.edit?.assembly
        pieces?.checks = checks
        let loaded = loads
        guard let after = try? await RouteTrimLine.measuring(sources, under: pieces, steps: next),
              loaded == loads
        else { return false }
        // A step that does not fit the line leaves the line: it is not one
        // to keep, whatever else it would have changed.
        if isNewStep, !after.lastStepChangedLine { return false }
        guard after.route != before.route || next.count < steps.count || selectingStretch != isSelectingStretch else {
            return false
        }
        // The hike's own line is still on the map under this one, and is
        // not this one: what this one no longer has of it is covered. Worked
        // out before anything changes, so nothing is seen half changed.
        let stale = next == (sources.edit?.routeSteps ?? [])
            ? Self.staleStretches(of: pieces, in: sources)
            : await Self.groundLeft(of: sources.current, by: after.route)
        guard loaded == loads else { return false }
        steps = next
        isSelectingStretch = selectingStretch
        trimStepIsOnlyForTheStretch = onlyForTheStretch
        line = after
        startMeters = min(max(cuts.range?.lowerBound ?? 0, 0), after.totalMeters)
        endMeters = min(max(cuts.range?.upperBound ?? after.totalMeters, startMeters), after.totalMeters)
        pausesTakenOff = cuts.range == nil ? [] : cuts.takingOff
        anchors = [.start: (after, startMeters), .end: (after, endMeters)]
        noteCuts()
        focusedCheckID = nil
        junctionMeters = []
        staleStretches = stale
        lineRevision += 1
        lookForJunctions()
        return true
    }

    /// The stretches of `current` that `line` does not go over as `current`
    /// draws them: each run of its legs that `line` has no leg for, between
    /// the same two points, walked or paused alike. A leg taken out as a
    /// pause keeps both its points, and the hike's own line still strokes it
    /// whole underneath. A line turned round or begun somewhere else leaves
    /// none, and neither does one that only goes on further.
    @concurrent
    nonisolated private static func groundLeft(
        of current: [RouteCoordinate],
        by line: [RouteCoordinate]
    ) async -> [[CLLocationCoordinate2D]] {
        let kept = Set(line.indices.dropFirst().map { Leg(line[$0 - 1], line[$0]) })
        var runs: [[CLLocationCoordinate2D]] = []
        // The legs left, by the index of the point each arrives at.
        var run: ClosedRange<Int>?
        func close() {
            guard let open = run else { return }
            runs.append(current[(open.lowerBound - 1)...open.upperBound].map(\.clCoordinate))
            run = nil
        }
        for index in current.indices.dropFirst() {
            if kept.contains(Leg(current[index - 1], current[index])) {
                close()
            } else {
                run = (run?.lowerBound ?? index)...index
            }
        }
        close()
        return runs
    }

    /// A leg of a line, whichever way it is walked, and whether a pause
    /// opened it.
    nonisolated private struct Leg: Hashable {
        struct Spot: Hashable, Comparable {
            let latitude: Double
            let longitude: Double

            static func < (one: Self, other: Self) -> Bool {
                (one.latitude, one.longitude) < (other.latitude, other.longitude)
            }
        }

        let ends: [Spot]
        let isPaused: Bool

        init(_ from: RouteCoordinate, _ to: RouteCoordinate) {
            ends = [
                Spot(latitude: from.latitude, longitude: from.longitude),
                Spot(latitude: to.latitude, longitude: to.longitude),
            ].sorted()
            isPaused = to.isPauseBoundary
        }
    }

    /// Puts both handles on a stretch, where they are picking one out.
    func select(_ stretch: ClosedRange<Double>) {
        guard isSelectingStretch, let line else { return }
        startMeters = min(max(stretch.lowerBound, 0), line.totalMeters)
        endMeters = min(max(stretch.upperBound, startMeters), line.totalMeters)
        anchors = [.start: (line, startMeters), .end: (line, endMeters)]
        noteCuts()
    }

    @concurrent
    nonisolated private static func edited(
        _ line: RouteTrimLine,
        cuts: EditedLine.Cuts,
        assembly: RouteAssembly?,
        replacing current: [RouteCoordinate],
        cutBefore: Set<RouteTrimHandle>,
        recordedBefore: TimeInterval
    ) async -> EditedLine? {
        EditedLine(
            whole: line.route,
            distances: line.distances,
            cuts: cuts,
            replacing: current,
            cutBefore: cutBefore,
            assembly: assembly,
            steps: EditedLine.Steps(
                made: line.steps,
                moving: line.endsMovedBySteps,
                recordedSeconds: line.recordedSeconds,
                clockedRoute: line.clockedRoute
            ),
            recordedBefore: recordedBefore
        )
    }

    /// Where the cut at `handle` stands on the map, or `nil` with no line.
    func spot(of handle: RouteTrimHandle) -> RouteTrimLine.Spot? {
        guard let line else { return nil }
        // A stretch picked out keeps a pause at either edge on its side —
        // see `RouteStep.swift` — the pause on an end of the line included.
        let takesOffPause = isSelectingStretch || pausesTakenOff.contains(handle.endPause)
        return switch handle {
        case .start: line.startSpot(at: startMeters, takingOffPause: takesOffPause)
        case .end: line.endSpot(at: endMeters, takingOffPause: takesOffPause)
        }
    }

    /// Where the kept line ends on the map: the cut at `handle`, or the
    /// line's own end while the handles pick a stretch out and cut nothing.
    func keptSpot(of handle: RouteTrimHandle) -> RouteTrimLine.Spot? {
        guard isSelectingStretch, let line else { return spot(of: handle) }
        return switch handle {
        case .start: line.startSpot(at: 0)
        case .end: line.endSpot(at: line.totalMeters)
        }
    }

    /// The clock at the cut at `handle`, or `nil` where the line has none.
    func timestamp(of handle: RouteTrimHandle) -> Date? {
        line?.timestamp(
            of: handle,
            at: position(of: handle),
            takingOffPause: pausesTakenOff.contains(handle.endPause)
        )
    }
}

/// The trim the map draws, if a screen has one up: held in a reference type
/// for the reason ``WalkHighlight`` is, so the map observes it directly and
/// no SwiftUI view re-renders for a handle that moved.
@Observable
final class RouteTrimPreview {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    private(set) var session: RouteTrimSession?

    /// Called by ``RouteTrimSession/show(on:)`` and nothing else.
    func present(_ session: RouteTrimSession) {
        guard self.session !== session else { return }
        self.session = session
    }

    /// Called by ``RouteTrimSession/end()`` and nothing else.
    func withdraw(_ session: RouteTrimSession) {
        guard self.session === session else { return }
        self.session = nil
    }
}
