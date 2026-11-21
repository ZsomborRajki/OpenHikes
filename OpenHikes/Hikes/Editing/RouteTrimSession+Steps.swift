//
//  RouteTrimSession+Steps.swift
//  OpenHikes
//
//  What *Edit Route* does to a line beyond cutting its ends: a stretch drawn
//  along mapped trails, straightened or taken out, a pull through a spot on
//  the map, and the whole line turned round, begun somewhere else, closed or
//  doubled back. Each is a ``RouteStep``, made on the line the cuts leave.
//
//  ## A cut becomes a step when one is made on it
//
//  A step says where it works in metres along the line as it stood. The
//  hiker sees the line the two cuts leave, so that is the line a step is
//  made on: the cuts are kept as a step of their own first
//  (``RouteStep/trim(_:endPauses:)``), and the handles go back to the ends
//  of what is left. *Undo* gives them back as cuts.
//
//  ## Picking a stretch out
//
//  The same two handles, in the chart and on the map, where a hiker already
//  knows them — and the chart is what tells two passes over the same ground
//  apart. While they pick a stretch out they cut nothing
//  (``RouteTrimSession/isSelectingStretch``), and what is done to the
//  stretch ends the picking.
//
//  ## A pull is bounded by junctions
//
//  A line held and pulled through another spot has to stop somewhere either
//  side, or one drag redraws the hike. It stops at the nearest fork each
//  side — a reroute is a choice between two ways at a fork — and where none
//  is known near, a distance the map's zoom gives. See
//  ``pullBounds(around:reach:)``.
//
//  ## One change at a time
//
//  Working a step out awaits — a path, the line measured again — and every
//  step is made on the line the one before it left, so nothing else that
//  changes the line starts until it has landed: no second step, no Undo, no
//  answer to a section and no Save (``RouteTrimSession/isMakingStep``).
//
//  ## An answer to the line it was asked about
//
//  A path is asked for between two spots of the line as it stands, and the
//  handles can move, or the line be drawn again, while it is found. A step
//  says where it works in metres along the line it is made on, so a path
//  that comes back to other ground than it was asked about would be put in
//  the wrong place: it is dropped (``StepGround``).
//

import CoreLocation
import Foundation
import OpenHikesData

extension RouteTrimSession {
    /// The furthest a junction may be from a pull and still bound it. Past
    /// it the pull takes the reach the map gives, so a tug on a trail with
    /// no forks for an hour does not redraw the hour.
    static let maximumPullMeters = 3000.0

    /// Whether a button that makes a step may be pressed.
    var canMakeSteps: Bool { !isSaving && !isRouting && !isMakingStep }

    /// Whether there is a step to take back.
    var canUndo: Bool { !steps.isEmpty && !isSelectingStretch && canMakeSteps }

    /// What a step would be made on: the line, where the cuts stand on it,
    /// and whether the handles pick a stretch out. A path asked for on one
    /// is no answer on another — see the file header.
    struct StepGround: Equatable {
        let revision: Int
        let start: Double
        let end: Double
        let pausesTakenOff: RouteTrim.EndPauses
        let isSelectingStretch: Bool
    }

    var stepGround: StepGround {
        StepGround(
            revision: lineRevision,
            start: startMeters,
            end: endMeters,
            pausesTakenOff: pausesTakenOff,
            isSelectingStretch: isSelectingStretch
        )
    }

    /// Whether the line comes back to where it began — see ``RouteShape``.
    var returnsToItsStart: Bool {
        _ = lineRevision
        return line?.shape == .loop || line?.shape == .outAndBack
    }

    /// Whether the line is a loop, which can be begun anywhere along it: an
    /// out and back begun at its far end is the same walk the other way.
    var isLoop: Bool {
        _ = lineRevision
        return line?.shape == .loop
    }

    // MARK: Making a step

    /// Makes `step` on the line the cuts leave, keeping the cuts as a step
    /// of their own first — see the file header. A step that leaves the line
    /// as it was is not made.
    ///
    /// - Parameter ground: what the step was worked out on, for one that
    ///   waited for a path: it is made only on the same — see
    ///   *An answer to the line it was asked about* in the file header.
    @discardableResult private func make(_ step: RouteStep, on ground: StepGround? = nil) async -> Bool {
        await settled()
        guard line != nil, !isSaving, ground == nil || ground == stepGround else { return false }
        var next = steps
        if let range = trim { next.append(.trim(range, endPauses: pausesTakenOff.rawValue)) }
        next.append(step)
        guard RouteSteps.pathCoordinateCount(of: next) <= RouteSteps.maximumPathCoordinates else {
            refusal = .tooMuchToKeep
            return false
        }
        return await redraw(with: next, isNewStep: true)
    }

    /// Takes the last step back. A cut that became a step when that one was
    /// made is a cut again.
    func undo() async {
        guard canUndo else { return }
        await holdingSteps { await takeBackLastStep() }
    }

    private func takeBackLastStep() async {
        var next = steps
        var cuts = EditedLine.Cuts()
        if case let .trim(range, endPauses)? = next.popLast() {
            cuts = EditedLine.Cuts(range: range, takingOff: RouteTrim.EndPauses(rawValue: endPauses))
        } else if case let .trim(range, endPauses)? = next.last {
            next.removeLast()
            cuts = EditedLine.Cuts(range: range, takingOff: RouteTrim.EndPauses(rawValue: endPauses))
        }
        await redraw(with: next, cuts: cuts)
    }

    // MARK: A stretch

    /// Turns the two handles to picking a stretch out, on the middle third
    /// of the line the cuts leave.
    func beginStretch() async {
        guard line != nil, canMakeSteps, !isSelectingStretch else { return }
        await holdingSteps {
            var next = steps
            let cut = trim
            if let cut { next.append(.trim(cut, endPauses: pausesTakenOff.rawValue)) }
            let picking = await redraw(with: next, selectingStretch: true, trimStepIsOnlyForTheStretch: cut != nil)
            guard picking else { return }
            let total = totalMeters
            select((total / Self.thirds)...(total * 2 / Self.thirds))
        }
    }

    private static let thirds = 3.0

    /// Leaves the stretch alone, and gives the handles back to the cuts.
    func endStretch() async {
        guard isSelectingStretch, !isSaving else { return }
        await holdingSteps {
            if trimStepIsOnlyForTheStretch, case let .trim(range, endPauses)? = steps.last {
                let cuts = EditedLine.Cuts(range: range, takingOff: RouteTrim.EndPauses(rawValue: endPauses))
                await redraw(with: Array(steps.dropLast()), cuts: cuts)
            } else {
                await redraw(with: steps)
            }
        }
    }

    /// Draws the stretch straight from one handle to the other.
    func straightenStretch() async {
        guard isSelectingStretch, canMakeSteps else { return }
        await holdingSteps { await make(.replace(keptRange, with: .straight)) }
    }

    /// Takes the stretch out, as a pause is: no distance and no trail. Not
    /// the whole line, which would leave none (``picksWholeLine``).
    func takeOutStretch() async {
        guard isSelectingStretch, canMakeSteps, !picksWholeLine else { return }
        await holdingSteps { await make(.pause(keptRange)) }
    }

    /// Draws the stretch along mapped trails from one handle to the other,
    /// or says there are none.
    func followTrailsAcrossStretch() async {
        guard isSelectingStretch, canMakeSteps,
              let from = spot(of: .start)?.coordinate, let to = spot(of: .end)?.coordinate
        else { return }
        guard let router = routing?.router else {
            refusal = .noMappedWay
            return
        }
        await holdingSteps { await follow(from: from, to: to, using: router) }
    }

    private func follow(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        using router: any TrailLegRouting
    ) async {
        let asked = stepGround
        isRouting = true
        let found = await RouteReroute.way(from: from, to: to, using: router)
        isRouting = false
        guard let way = found else { return }
        // Still the stretch that was asked about: a handle moved while the
        // path was being found is a new question.
        guard stepGround == asked else { return }
        guard way.isMapped else {
            refusal = .noMappedWay
            return
        }
        await make(.replace(asked.start...asked.end, with: RoutePath(way.coordinates)), on: asked)
    }

    // MARK: The whole line

    func reverse() async {
        guard canMakeSteps, !isSelectingStretch else { return }
        await holdingSteps { await make(.reverse) }
    }

    /// Doubles the line back — not one that already ends where it began
    /// (``keptEndsMeet``), which would walk all of it again to get there.
    func goOutAndBack() async {
        guard canMakeSteps, !isSelectingStretch, !keptEndsMeet else { return }
        await holdingSteps { await make(.outAndBack) }
    }

    /// Joins the line's end to its start: along mapped trails where there
    /// are any between them, and straight where there are none. Not a line
    /// whose ends already meet.
    func closeLoop() async {
        guard canMakeSteps, !isSelectingStretch, !keptEndsMeet,
              let from = spot(of: .end)?.coordinate, let to = spot(of: .start)?.coordinate
        else { return }
        await holdingSteps {
            let asked = stepGround
            var path = RoutePath.straight
            if let router = routing?.router {
                isRouting = true
                let way = await RouteReroute.way(from: from, to: to, using: router)
                isRouting = false
                guard let way else { return }
                if way.isMapped { path = RoutePath(way.coordinates) }
            }
            await make(.closeLoop(path), on: asked)
        }
    }

    /// Begins the loop where its start handle stands: what the cut took off
    /// the start goes on after the end. Not a cut, so it is not kept as one.
    func startLoopAtCut() async {
        guard canStartLoopAtCut, canMakeSteps else { return }
        await holdingSteps { await redraw(with: steps + [.startAt(startMeters)]) }
    }

    // MARK: A pull on the map

    /// How far along the line each junction it passes is, read once for
    /// each line. Quietly nothing where the graph cannot be had: a pull is
    /// then bounded by the reach the map gives.
    func findJunctions() async {
        guard let line, let graph = routing?.graph, junctionMeters.isEmpty else { return }
        let revision = lineRevision
        let found = (try? await TrailJunctionFinder.passDistances(along: line.profile, from: graph)) ?? []
        guard revision == lineRevision else { return }
        junctionMeters = found
    }

    /// The stretch a pull `meters` along the line redraws: from the junction
    /// before it to the junction after, inside what the cuts leave.
    ///
    /// - Parameter reach: how far either side a pull takes where no junction
    ///   is known within ``maximumPullMeters``: the map's, by its zoom.
    func pullBounds(around meters: Double, reach: Double) -> ClosedRange<Double>? {
        guard line != nil, !isSelectingStretch, canMakeSteps else { return nil }
        let kept = keptRange
        let margin = Self.minimumStretchMeters / 2
        guard meters > kept.lowerBound + margin, meters < kept.upperBound - margin else { return nil }
        let before = junctionMeters.last { $0 <= meters - margin && meters - $0 <= Self.maximumPullMeters }
        let after = junctionMeters.first { $0 >= meters + margin && $0 - meters <= Self.maximumPullMeters }
        let lower = max(before ?? (meters - max(reach, margin)), kept.lowerBound)
        let upper = min(after ?? (meters + max(reach, margin)), kept.upperBound)
        return upper > lower ? lower...upper : nil
    }

    /// Draws `stretch` through `via` instead: along mapped trails where the
    /// router finds them, and straight through the spot where it does not.
    ///
    /// - Parameters:
    ///   - stretch: in metres along the line as the handles see it, from
    ///     ``pullBounds(around:reach:)``.
    ///   - ground: what `stretch` was measured on, when that was before now:
    ///     a pull takes hold of the line before it lets go.
    @discardableResult func reroute(
        _ stretch: ClosedRange<Double>,
        through via: CLLocationCoordinate2D,
        on ground: StepGround? = nil
    ) async -> Bool {
        let asked = ground ?? stepGround
        guard let line, canMakeSteps, !isSelectingStretch, asked == stepGround else { return false }
        // The spots either side of the stretch the line before it ends on
        // and the line after it begins on: across a pause, the walk's side
        // of it — see `RouteStep.swift`.
        let from = line.startSpot(at: stretch.lowerBound, takingOffPause: true).coordinate
        let to = line.endSpot(at: stretch.upperBound, takingOffPause: true).coordinate
        // The line a step is made on begins at the start cut.
        let begins = cuts(.start) ? startMeters : 0
        let made = (stretch.lowerBound - begins)...(stretch.upperBound - begins)
        return await holdingSteps {
            var coordinates = [via]
            if let router = routing?.router {
                isRouting = true
                let way = await RouteReroute.way(from: from, to: to, using: router, through: via)
                isRouting = false
                guard let way else { return false }
                coordinates = way.coordinates
            }
            return await make(.replace(made, with: RoutePath(coordinates)), on: asked)
        } ?? false
    }
}
