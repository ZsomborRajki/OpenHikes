//
//  TrailDraftFields.swift
//  OpenHikes
//
//  The maker's name field, its snapping switch, its notices and its running
//  figures.
//
//  Each is its own `View` type and that is a render-isolation decision rather
//  than tidiness: only a `View` is a boundary, so a name typed into a field
//  declared inside ``TrailDraftView``'s body would re-evaluate that body — and
//  with it the whole route — once per character. See
//  ``SheetPresentation/searchText``, which is the same problem one screen up
//  and has the same answer.
//
//  That holds for the name field even though it is inside an alert: an alert
//  is presented *over* the list rather than instead of it, so the body behind
//  it is evaluated exactly as often and the stops are rebuilt exactly as
//  many times.
//
//  The stop rows themselves are in `TrailStopRow.swift` and the search sheet a
//  row opens is in `TrailStopSearch.swift`. Both were here as a numbered
//  waypoint row and a *Find a Place* field before the route became a list of
//  stops.
//

import Observation
import SwiftUI

/// What the hiker is typing into the save alert, for as long as that alert is
/// up.
///
/// A reference type rather than the screen's `@State`, for the reason
/// ``TrailStopSearchRun`` is one and the file header states: a `@State`
/// mutation invalidates the view holding it whether or not its body reads it,
/// so a name typed into an alert declared by ``TrailDraftView`` would rebuild
/// that screen's whole route once per character.
///
/// Nowhere near ``TrailDraft``, and that is the point of it: the drawing is
/// kept across launches and this is not. A name belongs to the save it was
/// typed for, so a hiker who starts naming a trail, thinks better of it and
/// cancels comes back to a blank field rather than to their own second
/// thoughts.
@Observable
final class TrailDraftName {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    var text = ""

    func clear() {
        guard !text.isEmpty else { return }
        text = ""
    }
}

/// What the hiker is calling this trail, asked once, on the way out.
///
/// The placeholder is the name a blank field writes, which is what makes
/// leaving it blank a choice rather than an omission — see
/// ``TrailDraftView`` for why the date behind it is taken at the tap.
struct TrailDraftNameField: View {
    let name: TrailDraftName
    let placeholder: String

    var body: some View {
        TextField(placeholder, text: Binding(
            get: { name.text },
            set: { name.text = $0 }
        ))
        .accessibilityIdentifier("trail-draft-name")
        .autocorrectionDisabled()
        #if os(iOS)
        .textInputAutocapitalization(.words)
        #endif
    }
}

/// Whether the legs between the points follow mapped paths.
///
/// Its own `View` for the reason the fields above are, and here the cost it
/// avoids is the larger one: this sits over a list whose every row reads the
/// draft, and a `Toggle` declared inline in ``TrailDraftView``'s body would
/// make the animation of the switch itself a body pass.
///
/// It writes through ``TrailDraftController`` rather than onto the draft, like
/// every other mutation in this feature, because turning it back on is a
/// question for OpenStreetMap and the controller is what asks — see
/// ``TrailDraftController/setSnapsToPaths(_:)``.
struct TrailDraftSnapToggle: View {
    let maker: TrailDraftController

    var body: some View {
        Section {
            Toggle("Follow Paths", isOn: Binding(
                get: { maker.draft.snapsToPaths },
                set: { following in maker.setSnapsToPaths(following) }
            ))
            .accessibilityIdentifier("trail-draft-snap")
        } footer: {
            Text(
                """
                Legs run along paths mapped in OpenStreetMap. \
                Turn this off to draw straight lines.
                """
            )
        }
    }
}

/// One short line about a leg, or about the line as a whole.
///
/// The glyph is the whole of the difference at a glance and its colour is what
/// says whether anything is wrong — the arrangement ``CuratedTrailNotice``
/// already uses under *Search this area*, and the reason a leg with nothing
/// mapped under it does not wear a warning triangle.
struct TrailDraftNoticeLabel: View {
    let notice: TrailLegNotice

    var body: some View {
        Label {
            Text(notice.text)
        } icon: {
            Image(systemName: notice.symbolName)
                .foregroundStyle(notice.isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}

/// What the line is so far: how long, and — once anybody has been able to
/// measure it — what it climbs and drops.
///
/// Its own `View` and this is the one on the screen that most needed to be.
/// The length changes when the drawing does, so a body carrying it rebuilds
/// the list of points at exactly the moments that list has to be rebuilt
/// anyway. The climb does not: it lands a couple of seconds after the hiker
/// stops, from a task nobody is watching, and a figure read in
/// ``TrailDraftView``'s body would rebuild every stop, every place and every
/// candidate row to say it. See ``TrailDraftElevation``.
///
/// **Nothing at all is drawn where there is no height**, which is a free
/// hiker's drawn trail, a build with no key and every launch running tests.
/// That is the same degradation a curated route already has — a line, a
/// length, and no chart — rather than a prompt for a subscription in the
/// middle of a drawing.
struct TrailDraftLineHeader: View {
    let draft: TrailDraft
    let elevation: TrailDraftElevation

    var body: some View {
        // Read once and handed to both layouts below, so the one that is
        // discarded costs a measurement rather than a second read of an
        // observable.
        let climb = elevation.summary
        let waiting = elevation.isMeasuring
        let length = Self.length(draft.distanceMeters)
        // Stacked rather than clipped at the accessibility type sizes, where
        // three figures and a heading do not fit across a phone. The audit
        // measures exactly this — see ``AccessibilityUITests``.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Text("Route")
                Spacer(minLength: 12)
                figures(climb, waiting: waiting, length: length)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Route")
                figures(climb, waiting: waiting, length: length)
            }
        }
        // One element rather than four, and a value rather than four labels,
        // the rule every composite row here follows — see ``HikeRow``. The
        // units are spoken in full because "km" and "m" are read out as
        // letters otherwise; ``HikeFormat/spokenElevation(_:locale:)`` is the
        // same fix the elevation chart already carries.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Route")
        .accessibilityValue(
            Self.spoken(draft.distanceMeters, climb: climb, measuring: waiting)
        )
    }

    @ViewBuilder
    private func figures(
        _ climb: RouteElevationSummary?,
        waiting: Bool,
        length: String
    ) -> some View {
        HStack(spacing: 10) {
            // The same thing the *Search this area* pill's spinner says, in
            // the slot the answer will land in: a figure is coming. It is on
            // screen once, after the hiker stops drawing, for as long as one
            // request takes — never during the drawing itself.
            if waiting {
                ProgressView()
                    #if os(iOS)
                    .controlSize(.mini)
                    #endif
            }
            if let gain = climb?.gainMeters {
                Label(Self.height(gain), systemImage: "arrow.up")
            }
            if let loss = climb?.lossMeters {
                Label(Self.height(loss), systemImage: "arrow.down")
            }
            Text(length)
        }
        .monospacedDigit()
        .imageScale(.small)
        .accessibilityIdentifier("trail-draft-length")
    }

    private static func height(_ meters: Double) -> String {
        HikeFormat.elevation(Measurement(value: meters, unit: UnitLength.meters))
    }

    /// The same height with its unit said in full, because "m" is read out as
    /// a letter otherwise.
    private static func spokenHeight(_ meters: Double) -> String {
        HikeFormat.spokenElevation(Measurement(value: meters, unit: UnitLength.meters))
    }

    private static func length(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    /// The same figures as a sentence, with every unit said in full.
    ///
    /// The spinner is a shape and says nothing, so the sentence is where a
    /// hiker who cannot see it is told a number is on its way.
    static func spoken(
        _ meters: Double,
        climb: RouteElevationSummary?,
        measuring: Bool = false
    ) -> String {
        let length = Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .wide, usage: .road))
        let parts = [
            length,
            measuring ? String(localized: "measuring the climb") : nil,
            climb?.gainMeters.map { gain in
                String(localized: "\(Self.spokenHeight(gain)) of climb")
            },
            climb?.lossMeters.map { loss in
                String(localized: "\(Self.spokenHeight(loss)) of descent")
            },
        ]
        return parts.compactMap(\.self).joined(separator: ", ")
    }
}

/// What the whole route has to say for itself, under its stops.
///
/// Its own `View` for the reason the header above is: everything it draws is
/// read off ``TrailDraft/legs``, which every leg that lands rewrites.
///
/// It carries the empty state too, which used to be a row inside the section.
/// It cannot be a row any more: ``TrailAddStopRow`` is always the last one, and
/// a "there is nothing here" row sitting above a control that offers to put
/// something there would be the section saying two things at once.
struct TrailDraftLineFooter: View {
    let draft: TrailDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if draft.waypoints.isEmpty {
                Text("Tap the map to put down your first stop, or search for one above.")
                    .accessibilityIdentifier("trail-draft-empty")
            }
            // One line for the whole line, saying the worst thing any leg has
            // to report — see ``TrailDraft/notice``. The per-leg sentence is on
            // the row it belongs to; this is what a hiker who has not scrolled
            // sees.
            if let notice = draft.notice {
                TrailDraftNoticeLabel(notice: notice)
            }
            // The two gestures on the map that nothing on screen could
            // otherwise announce. Both are discoverable only by being told: a
            // leg looks like a drawing rather than a control, and a pin that
            // answers a press but not a tap advertises nothing. Withheld until
            // there is a line to do either to.
            if !draft.legs.isEmpty {
                Text(
                    """
                    Tap a leg to add a stop in the middle. \
                    Press and hold a stop to move it.
                    """
                )
            }
        }
    }
}

/// *Try Again*, offered only when Overpass refused something.
///
/// Not for a leg with nothing mapped under it and not for one the hiker
/// straightened themselves: asking again about either would spend a request to
/// be told the same thing. See ``TrailLegSnap/isRetryable``.
///
/// Its own `View` for the reason the two above are — it reads
/// ``TrailDraft/legs``, and it is a row inside the same section they are.
struct TrailDraftRetryRow: View {
    let maker: TrailDraftController

    var body: some View {
        if maker.draft.hasRetryableLegs {
            Button("Try Again", systemImage: "arrow.clockwise", action: maker.retryRefusedLegs)
                .accessibilityIdentifier("trail-draft-retry")
        }
    }
}
