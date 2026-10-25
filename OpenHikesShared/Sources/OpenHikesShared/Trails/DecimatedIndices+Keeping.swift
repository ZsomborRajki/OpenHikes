//
//  DecimatedIndices+Keeping.swift
//  OpenHikesShared
//
//  The stride, around points a line must keep.
//
//  Three writers thin a line to a budget and must keep certain points
//  whatever the stride would have dropped: the widget's line keeps the ends
//  of the pauses it can afford (``SharedTrailSnapshot/line(of:cutAt:maxPoints:pauseEndBudget:coordinate:)``),
//  the watch's package the ends of the pauses that cross
//  (``WatchTrailPackage/keptPoints(of:gapMeters:pointBudget:pauseBudget:)``),
//  and the heights asked of Stadia the ends of every pause while they come to
//  half the request (`CuratedElevationRequest.sampleIndexes(of:limit:)` in
//  the app). Which points must be kept is each writer's own policy and stays
//  with it. What is left is the same arithmetic in all three, and lives here
//  so it is written once (#1084): the kept points come out of the budget, and
//  the stride, ``decimatedIndices(count:maxPoints:)``, is taken over the other
//  points only, so none of its points is spent on one that is kept anyway. A
//  stride over the whole line lost a point to every kept point it happened to
//  land on, and the line came in short of its budget (#1053).
//
//  Plain indices and the standard library only, because this package has no
//  dependencies (see *Layout and targets* in AGENTS.md).
//

/// Which of `count` points a line keeps when every one of `required` must be
/// among them: those, and ``decimatedIndices(count:maxPoints:)`` over the
/// other points for what is left of `maxPoints`, in ascending order.
///
/// A line whose points all fit comes back whole. A longer one comes back as
/// exactly `maxPoints` points while `required` leaves the stride two or more,
/// and the stride's two are the first and last of the other points, so the
/// line's own ends are kept, as the stride's or as required ones. A caller
/// that cannot promise the stride two points says what it wants then: the
/// stride keeps every point it is asked to thin to fewer than two.
///
/// - Parameter required: indices in `0..<count`. The caller has already
///   bounded how many there are; this keeps every one of them.
public func decimatedIndices(count: Int, maxPoints: Int, keeping required: Set<Int>) -> [Int] {
    let others = (0..<max(0, count)).filter { !required.contains($0) }
    let strided = decimatedIndices(count: others.count, maxPoints: maxPoints - required.count)
    return required.union(strided.map { others[$0] }).sorted()
}
