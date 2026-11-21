//
//  RouteTrimDetails.swift
//  OpenHikes
//
//  What *Edit Route* says under its chart: what a save would leave, and the
//  stretches it offers to take off in one tap.
//
//  Each is a view of its own because each reads the cuts, which move at drag
//  frequency — see ``RouteTrimView`` for what its body may read.
//

import OpenHikesData
import SwiftUI

/// What the hike would be with the cuts where they stand: its distance, its
/// clock where the line has one, and how much comes off.
struct RouteTrimFigures: View {
    let session: RouteTrimSession
    /// ``Hike/distanceMeters`` as it is now. A save takes what it cuts off
    /// the hike's line off this figure, or adds what it gives back, rather
    /// than measuring the kept line again — see ``RouteEditSave`` — and so
    /// does this.
    let hikeDistanceMeters: Double

    var body: some View {
        // An answer changed is a new whole line, of another length.
        _ = session.lineRevision
        let total = session.totalMeters
        let kept = max(session.endMeters - session.startMeters, 0)
        let removed = max(total - kept, 0)
        let lost = session.currentLengthMeters - kept
        return StatStrip {
            StatFigure(
                label: "Distance",
                value: RouteTrimFormat.length(max(0, min(kept, hikeDistanceMeters - lost)))
            )
            if let seconds = keptSeconds {
                StatFigure(label: "Duration", value: HikeFormat.duration(seconds))
            }
            StatFigure(label: "Removed", value: RouteTrimFormat.length(removed))
        }
        .accessibilityIdentifier("route-trim-figures")
    }

    /// From the kept line's first moment to its last, as a hike's *Duration*
    /// is — ``HikeRouteStatistics/duration`` — or `nil` for a line with no
    /// clock.
    private var keptSeconds: TimeInterval? {
        guard let began = session.timestamp(of: .start),
              let ended = session.timestamp(of: .end),
              ended > began
        else { return nil }
        return ended.timeIntervalSince(began)
    }
}

/// The ends of the line that were not walked, each with the tap that takes it
/// off — see ``RouteCarriedEnds`` for how they are found. Nothing is drawn
/// for a line with none, or once a cut already stands at or inside one.
struct RouteTrimOffers: View {
    let session: RouteTrimSession

    var body: some View {
        // A new line has its own ends.
        _ = session.lineRevision
        let ends = session.line?.carriedEnds ?? RouteCarriedEnds()
        let leading = ends.leading.flatMap { session.hasTakenOff($0, at: .start) ? nil : $0 }
        let trailing = ends.trailing.flatMap { session.hasTakenOff($0, at: .end) ? nil : $0 }
        return Group {
            if leading != nil || trailing != nil {
                PlaceCardList(title: String(localized: "Not on Foot")) {
                    if let leading {
                        offer(
                            String(localized: "Remove \(RouteTrimFormat.length(leading.carriedMeters)) at the Start"),
                            identifier: "route-trim-remove-start"
                        ) {
                            session.takeOff(leading, at: .start)
                        }
                    }
                    if let trailing {
                        offer(
                            String(localized: "Remove \(RouteTrimFormat.length(trailing.carriedMeters)) at the End"),
                            identifier: "route-trim-remove-end"
                        ) {
                            session.takeOff(trailing, at: .end)
                        }
                    }
                }
            }
        }
    }

    private func offer(_ title: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PlaceCardActionLabel(title: title, systemImage: "car")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}
