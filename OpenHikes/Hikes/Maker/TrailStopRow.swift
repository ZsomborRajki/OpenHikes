//
//  TrailStopRow.swift
//  OpenHikes
//
//  One stop on the route, and the line that joins it to the next.
//
//  This is what Phase 6's numbered "Point 3" row became. The change is not
//  cosmetic: a row now says *what a point is to the route* — where it starts,
//  somewhere it passes, where it ends — and *what is there*, which is the one
//  thing that makes a drawn route readable with the map put away. The number is
//  gone because the number was never the interesting fact; the order is, and
//  the list already draws that.
//
//  ## The line is drawn by the rows, not between them
//
//  There is no view between two rows of a `List` to draw anything in, so each
//  row draws its own half: a dotted stem from its top edge to its dot for every
//  row but the first, and from its dot to its bottom edge for every row but the
//  last. Two halves meeting at a shared edge look like one line, and the three
//  things that make that true rather than nearly true are all here:
//
//  - the separator is hidden, or a hairline crosses the stem at every join;
//  - the row's insets are zero top and bottom, so the stem reaches the edge
//    rather than stopping at the content and leaving a gap in the padding;
//  - the padding that makes the row a comfortable height is on the *text*
//    column instead, which is what the stem is then measured against.
//
//  ## It reads the drawing itself
//
//  The Phase 6 finding, unchanged and now with more to read: a twenty-point
//  trail waits on nineteen Overpass answers, and every one of them rewrites
//  ``TrailDraft/legs`` and ``TrailDraft/distancesAlongLine``. A parent body
//  that read either of those to *build* these rows would be re-evaluated
//  nineteen times and take everything else on the screen with it. Read here,
//  the same answer redraws the rows and nothing else — and a `List` is lazy, so
//  it asks only the rows on screen.
//
//  Names are the third thing read that way, and the most frequent: a stop named
//  by ``TrailStopNamer`` lands seconds after a tap, one point at a time.
//

import SwiftUI

/// The dotted stem that joins one stop to the next.
///
/// A `Shape` rather than a `Rectangle` with a dash overlay, because a dash
/// pattern belongs to a stroke and a stroke wants a path. Drawn down the middle
/// of whatever it is given, so the column's width is what centres it under the
/// dot.
///
/// `nonisolated` on the type, because `SWIFT_DEFAULT_ACTOR_ISOLATION` is
/// `MainActor` here and `Shape` is not — SwiftUI calls `path(in:)` off the main
/// actor, and an unannotated conformance is refused for exactly that reason.
/// See *Repository-specific conventions*.
nonisolated struct TrailStopConnector: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

/// One row of the route: its dot, its stems, what it is called and how far
/// along it sits.
struct TrailStopRowView: View {
    let draft: TrailDraft
    /// Where in the line this row sits.
    let index: Int
    /// Opens the search sheet on this stop.
    var onSearch: () -> Void

    /// Wide enough to centre a dot under a fingertip and narrow enough that the
    /// text column still has a phone's width at an accessibility type size. The
    /// same kind of number ``PhotoCalloutMetrics`` holds.
    private static let railWidth: CGFloat = 26
    private static let dotSize: CGFloat = 11
    private static let stemWidth: CGFloat = 2
    private static let stemDash: [CGFloat] = [2, 4]
    /// What makes a row a row. On the text column rather than on the row, for
    /// the reason the file header gives.
    private static let rowPadding: CGFloat = 11

    var body: some View {
        let role = draft.role(ofWaypointAt: index)
        let name = draft.name(ofWaypointAt: index)
        Button(action: onSearch) {
            HStack(alignment: .center, spacing: 0) {
                rail(role)
                text(role, name: name)
                    .padding(.vertical, Self.rowPadding)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowSeparator(.hidden)
        // One element rather than four, the rule every composite row here
        // follows — see ``HikeRow``. The identifier is unchanged from the
        // numbered rows it replaces, and deliberately so: it is what the map's
        // own callout, the automation and this screen all name a point by, and
        // the row's *place in the line* is still exactly what it means.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("trail-draft-point-\(index + 1)")
        .accessibilityHint("Opens a search for somewhere to put this stop")
    }

    /// The dot, with the half-stems either side of it.
    ///
    /// `maxHeight: .infinity` on both stems is what makes them meet the row's
    /// edges: the row is as tall as the padded text column beside them, and a
    /// stem that sized itself would stop short of it.
    @ViewBuilder
    private func rail(_ role: TrailStopRole) -> some View {
        VStack(spacing: 0) {
            stem(drawn: index > 0)
            Image(systemName: role.systemImageName)
                .font(.system(size: Self.dotSize, weight: .black))
                .foregroundStyle(.tint)
            stem(drawn: index < draft.waypoints.count - 1)
        }
        .frame(width: Self.railWidth)
        // The whole rail is decoration: the row says what it is in words.
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func stem(drawn: Bool) -> some View {
        TrailStopConnector()
            .stroke(
                drawn ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.clear),
                style: StrokeStyle(
                    lineWidth: Self.stemWidth,
                    lineCap: .round,
                    dash: Self.stemDash
                )
            )
            .frame(width: Self.railWidth, height: nil)
            .frame(maxHeight: .infinity)
    }

    /// What this stop is called, what it is to the route, and how far along it
    /// sits.
    ///
    /// A named stop leads with its name and says its role underneath, because
    /// the name is what a hiker is scanning for; an unnamed one leads with the
    /// role, which is all there is to say. Either way exactly two lines of text
    /// plus whatever the leg into it has to report, so the rows stay a
    /// consistent height while the names land one at a time.
    @ViewBuilder
    private func text(_ role: TrailStopRole, name: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if name.isEmpty {
                Text(role.title)
            } else {
                Text(name).lineLimit(2)
            }
            HStack(spacing: 6) {
                if !name.isEmpty {
                    Text(role.title)
                    Text(verbatim: "·")
                }
                Text(Self.length(draft.distanceAlongLine(toWaypointAt: index)))
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            // The leg *into* this stop, which is why the first row never has
            // one: nothing arrives at it.
            if let notice = draft.leg(arrivingAtWaypointAt: index)?.snap.notice {
                TrailDraftNoticeLabel(notice: notice)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func length(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }
}

/// *Add Stop*, and it never goes away.
///
/// The one row of the route section that is not a point, kept at the bottom of
/// it whatever the line is doing — including for a draft with nothing in it,
/// where it is the only way in that is not a tap on the map. That permanence is
/// the whole of what makes the section read as a route being built rather than
/// as a list of things that happen to be there.
///
/// It carries the same rail as the rows above it, with a stem reaching up to
/// the last of them, so the line the route is drawn as arrives at the place a
/// hiker adds to it.
struct TrailAddStopRow: View {
    let draft: TrailDraft
    var onAdd: () -> Void

    private static let railWidth: CGFloat = 26
    private static let rowPadding: CGFloat = 11
    private static let stemWidth: CGFloat = 2
    private static let stemDash: [CGFloat] = [2, 4]

    var body: some View {
        Button(action: onAdd) {
            HStack(alignment: .center, spacing: 0) {
                rail
                Text("Add Stop")
                    .foregroundStyle(.tint)
                    .padding(.vertical, Self.rowPadding)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowSeparator(.hidden)
        // Never draggable and never deletable: it is a control rather than a
        // stop, and in a list whose rows are all reorderable an *Add* row that
        // could be dragged into the middle of the route would be a control that
        // lies about what it is.
        .moveDisabled(true)
        .deleteDisabled(true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("trail-draft-add-stop")
    }

    @ViewBuilder private var rail: some View {
        VStack(spacing: 0) {
            TrailStopConnector()
                .stroke(
                    draft.waypoints.isEmpty
                        ? AnyShapeStyle(.clear)
                        : AnyShapeStyle(.tertiary),
                    style: StrokeStyle(
                        lineWidth: Self.stemWidth,
                        lineCap: .round,
                        dash: Self.stemDash
                    )
                )
                .frame(maxHeight: .infinity)
            Image(systemName: "plus.circle.fill")
                .font(.body)
                .foregroundStyle(.tint)
            Color.clear.frame(maxHeight: .infinity)
        }
        .frame(width: Self.railWidth)
        .accessibilityHidden(true)
    }
}
