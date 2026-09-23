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
//  It says that in one line, as Apple Maps' directions list does: the name
//  when there is one, the role until then — two at an accessibility type size,
//  where one would leave a long name a few letters wide. The distance along the
//  line is the row's accessibility value now, because the map draws it. A leg
//  with something wrong with it keeps a mark at the row's trailing edge, the
//  notice's own glyph, because the footer can only say what is wrong and not
//  where; its sentence is in the value too.
//
//  ## The line is drawn by the rows, not between them
//
//  There is no view between two rows of a list to draw anything in, so each
//  row draws its own half: a dotted stem from its top edge to its dot for every
//  row but the first, and from its dot to its bottom edge for every row but the
//  last. Two halves meeting at a shared edge look like one line, and the three
//  things that make that true rather than nearly true are:
//
//  - no separators, or a hairline crosses the stem at every join;
//  - no vertical margins around the row, so the stem reaches the edge rather
//    than stopping at the content and leaving a gap in the padding;
//  - the padding that makes the row a comfortable height is on the *text*
//    column instead, which is what the stem is then measured against.
//
//  The first two are ``rowInsets`` and a hidden row separator, which
//  ``TrailDraftView`` puts on the stops' `ForEach`es and ``TrailAddStopRow`` on
//  itself.
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
    /// Moves the stop one row earlier or later, for VoiceOver. The drag itself
    /// is the list's `onMove` — see ``TrailDraftView``. Open fields pass `nil`,
    /// because there is no waypoint there to move.
    var onStep: ((AccessibilityAdjustmentDirection) -> Void)?
    /// Opens the search sheet on this row.
    var onSearch: () -> Void

    /// The rows' measurements are Apple Maps' directions card, taken off a
    /// 3× screenshot of it: with the 16-point inset every row in the card has,
    /// this puts the dot's centre 25.5 points in from the card's edge, and
    /// ``railSpacing`` starts the text at 48, where Maps starts its names.
    static let railWidth: CGFloat = 19
    /// Between the rail and the text column.
    static let railSpacing: CGFloat = 13
    private static let dotSize: CGFloat = 11
    static let stemWidth: CGFloat = 2
    static let stemDash: [CGFloat] = [2, 4]
    /// What makes a row a row. On the text column rather than on the row, for
    /// the reason the file header gives. Either side of one line of body text
    /// it makes a 52-point row at the default type size, which is Maps' own:
    /// 150 pixels cap-top to cap-top in a 3× screenshot, where both sheets are
    /// drawn at 96% at the medium detent — the same 34-pixel capitals in each
    /// say the scale is shared, so the pixels compare directly.
    static let rowPadding: CGFloat = 16
    /// No vertical inset, so the stems reach the row's edges, and the 16
    /// points either side every row in the card has.
    static let rowInsets = EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)

    @Environment(\.dynamicTypeSize)
    private var dynamicTypeSize

    var body: some View {
        let slots = draft.slots
        let slot = slots.indices.contains(position) ? slots[position] : .open(.end)
        Button(action: onSearch) {
            HStack(alignment: .center, spacing: Self.railSpacing) {
                rail(
                    Self.role(of: slot, in: draft),
                    isOpen: slot.waypointIndex == nil,
                    count: slots.count
                )
                text(slot)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .padding(.vertical, Self.rowPadding)
                Spacer(minLength: 0)
                legMark(slot)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(spokenDetail(slot))
        .accessibilityIdentifier(Self.identifier(of: slot))
        .accessibilityHint("Opens a search for somewhere to put this stop")
        .accessibilityActions {
            if let onStep {
                Button("Move Up") { onStep(.decrement) }
                Button("Move Down") { onStep(.increment) }
            }
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

    /// What this stop is called: its name once it has one, its role until
    /// then. One line and nothing under it, as in Apple Maps — the row is there
    /// to be found in a list, and what the route does between two stops is the
    /// map's to draw and the footer's to sum up.
    @ViewBuilder
    private func text(_ slot: TrailStopSlot) -> some View {
        switch slot {
        case .open(let role):
            Text(role == .start ? LocalizedStringKey("Choose Start") : "Choose Destination")
                .foregroundStyle(.secondary)
        case .point(let index, _):
            let name = draft.name(ofWaypointAt: index)
            Text(name.isEmpty ? draft.role(ofWaypointAt: index).title : name)
        }
    }

    /// The glyph of what the leg into this stop has to report, when it is
    /// something wrong: which leg failed, where the footer says only that one
    /// did. Not for a leg that is merely routing — every leg does that for a
    /// moment, and a row of spinners says nothing. Hidden from VoiceOver,
    /// which hears the sentence in the value instead.
    @ViewBuilder
    private func legMark(_ slot: TrailStopSlot) -> some View {
        if case .point(let index, _) = slot,
           let notice = draft.leg(arrivingAtWaypointAt: index)?.snap.notice,
           notice.isWarning {
            Image(systemName: notice.symbolName)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
        }
    }

    /// What the row no longer prints, still said to VoiceOver: the role a
    /// name hides, how far along the stop sits, and what the leg into it has
    /// to report. The eye gets the second from the map and the third from the
    /// row's mark and the footer's sentence.
    private func spokenDetail(_ slot: TrailStopSlot) -> String {
        guard case .point(let index, _) = slot else { return "" }
        let isNamed = !draft.name(ofWaypointAt: index).isEmpty
        return [
            isNamed ? draft.role(ofWaypointAt: index).title : nil,
            Self.length(draft.distanceAlongLine(toWaypointAt: index)),
            draft.leg(arrivingAtWaypointAt: index)?.snap.notice?.text,
        ]
        .compactMap(\.self)
        .joined(separator: ", ")
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
            HStack(alignment: .center, spacing: TrailStopRowView.railSpacing) {
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
        .listRowInsets(TrailStopRowView.rowInsets)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("trail-draft-add-stop")
    }
}
