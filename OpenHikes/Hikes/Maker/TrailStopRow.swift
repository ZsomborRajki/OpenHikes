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
/// along it sits — or, for an open start or destination, the field waiting to
/// be filled.
struct TrailStopRowView: View {
    let draft: TrailDraft
    /// Where in ``TrailDraft/slots`` this row sits.
    let position: Int
    /// Receives the handle's global drop point. Open fields pass `nil`, because
    /// there is no waypoint there to move.
    var onReorder: ((CGPoint) -> Void)?
    /// VoiceOver's equivalent of moving the same handle up or down.
    var onReorderAdjustment: ((AccessibilityAdjustmentDirection) -> Void)?
    /// Opens the search sheet on this row.
    var onSearch: () -> Void

    /// Keeps the row under the finger until its drop commits the new order.
    @GestureState private var reorderOffset: CGFloat = 0

    /// Wide enough to centre a dot under a fingertip and narrow enough that the
    /// text column still has a phone's width at an accessibility type size. The
    /// same kind of number ``PhotoCalloutMetrics`` holds.
    static let railWidth: CGFloat = 26
    private static let dotSize: CGFloat = 11
    static let stemWidth: CGFloat = 2
    static let stemDash: [CGFloat] = [2, 4]
    /// What makes a row a row. On the text column rather than on the row, for
    /// the reason the file header gives.
    static let rowPadding: CGFloat = 11

    var body: some View {
        let slots = draft.slots
        let slot = slots.indices.contains(position) ? slots[position] : .open(.end)
        HStack(spacing: 0) {
            Button(action: onSearch) {
                HStack(alignment: .center, spacing: 0) {
                    rail(
                        Self.role(of: slot, in: draft),
                        isOpen: slot.waypointIndex == nil,
                        count: slots.count
                    )
                    text(slot)
                        .padding(.vertical, Self.rowPadding)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(Self.identifier(of: slot))
            .accessibilityHint("Opens a search for somewhere to put this stop")

            if let onReorder {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
                    .gesture(reorderGesture(onDrop: onReorder))
                    .accessibilityIdentifier("trail-draft-reorder-\(position + 1)")
                    .accessibilityLabel("Reorder stop")
                    .accessibilityValue("Position \(position + 1) of \(slots.count)")
                    .accessibilityHint("Drag to another stop to change its position")
                    .accessibilityAdjustableAction { direction in
                        onReorderAdjustment?(direction)
                    }
            }
        }
        .offset(y: reorderOffset)
        .zIndex(reorderOffset == 0 ? 0 : 1)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowSeparator(.hidden)
    }

    private func reorderGesture(onDrop: @escaping (CGPoint) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .updating($reorderOffset) { value, offset, _ in
                offset = value.translation.height
            }
            .onEnded { value in
                onDrop(value.location)
            }
    }

    static func role(of slot: TrailStopSlot, in draft: TrailDraft) -> TrailStopRole {
        switch slot {
        case .open(let role): role
        case .point(let index, _): draft.role(ofWaypointAt: index)
        }
    }

    private static func identifier(of slot: TrailStopSlot) -> String {
        switch slot {
        case .open(.start): "trail-draft-open-start"
        case .open: "trail-draft-open-destination"
        case .point(let index, _): "trail-draft-point-\(index + 1)"
        }
    }

    /// The dot, with the half-stems either side of it. Hollow for an open
    /// field, which has nothing in it yet.
    ///
    /// `maxHeight: .infinity` on both stems is what makes them meet the row's
    /// edges: the row is as tall as the padded text column beside them, and a
    /// stem that sized itself would stop short of it.
    @ViewBuilder
    private func rail(_ role: TrailStopRole, isOpen: Bool, count: Int) -> some View {
        VStack(spacing: 0) {
            TrailStopStem(isDrawn: position > 0)
            Image(systemName: isOpen ? "circle" : role.systemImageName)
                .font(.system(size: Self.dotSize, weight: .black))
                .foregroundStyle(isOpen ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
            // The last row's lower stem reaches *Add Stop* when there is one.
            TrailStopStem(isDrawn: position < count - 1 || draft.canBeSaved)
        }
        .frame(width: Self.railWidth)
        .accessibilityHidden(true)
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
    private func text(_ slot: TrailStopSlot) -> some View {
        switch slot {
        case .open(let role):
            Text(role == .start ? LocalizedStringKey("Choose Start") : "Choose Destination")
                .foregroundStyle(.secondary)
        case .point(let index, _):
            let role = draft.role(ofWaypointAt: index)
            let name = draft.name(ofWaypointAt: index)
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
                if let notice = draft.leg(arrivingAtWaypointAt: index)?.snap.notice {
                    TrailDraftNoticeLabel(notice: notice)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private static func length(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }
}

/// Half of the dotted line between two rows — see the file header.
private struct TrailStopStem: View {
    let isDrawn: Bool

    var body: some View {
        TrailStopConnector()
            .stroke(
                isDrawn ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.clear),
                style: StrokeStyle(
                    lineWidth: TrailStopRowView.stemWidth,
                    lineCap: .round,
                    dash: TrailStopRowView.stemDash
                )
            )
            .frame(width: TrailStopRowView.railWidth)
            .frame(maxHeight: .infinity)
    }
}

/// *Add Stop*, under a route that has both ends.
///
/// Absent while a start or destination field is still open: that field is the
/// way in, and a second row offering the same thing would be two answers to
/// one question. Once both are filled it stays at the bottom whatever the line
/// is doing, as in Apple Maps, and what it adds joins the end of the list to be
/// dragged into place.
///
/// It carries the same rail as the rows above it, with a stem reaching up to
/// the last of them, so the line the route is drawn as arrives at the place a
/// hiker adds to it.
struct TrailAddStopRow: View {
    var onAdd: () -> Void

    var body: some View {
        Button(action: onAdd) {
            HStack(alignment: .center, spacing: 0) {
                VStack(spacing: 0) {
                    TrailStopStem(isDrawn: true)
                    Image(systemName: "plus.circle.fill")
                        .font(.body)
                        .foregroundStyle(.tint)
                    Color.clear.frame(maxHeight: .infinity)
                }
                .frame(width: TrailStopRowView.railWidth)
                .accessibilityHidden(true)
                Text("Add Stop")
                    .foregroundStyle(.tint)
                    .padding(.vertical, TrailStopRowView.rowPadding)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowSeparator(.hidden)
        // Not a stop, so it has no place in the order and nothing to delete.
        .moveDisabled(true)
        .deleteDisabled(true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("trail-draft-add-stop")
    }
}
