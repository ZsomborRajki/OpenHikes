//
//  WalkStartedPill.swift
//  OpenHikes
//
//  The pill at the top of the map that says a hike has started.
//
//  A walk begins on its own, on the first matched fix with Follow This Trail
//  on — see ``TrailWalkSession``. Its controls live on the trail's detail,
//  under the progress bar, which is nowhere near where a hiker is looking
//  when they reach the trailhead with the sheet pulled down. Starting
//  silently there read as the app doing something behind their back, so the
//  start is said on the map, where it is seen at every detent: which trail,
//  a tap to open it and reach Pause and End, and an *x*.
//
//  The same place and the same glass as the caption *Search this area* hangs
//  under — see ``MapAreaSearchView`` — centred and dropped past the weather
//  badge rather than beside it, for the reason that caption is: the badge is
//  another hierarchy's overlay and there is nothing to anchor against.
//
//  Reads ``TrailWalkSession/startNotice`` and nothing else, in a view of its
//  own so the read is not charged to `OpenHikesView`'s body. The notice moves
//  when a walk starts, when it ends and when the *x* is tapped.
//

import SwiftUI

struct WalkStartedPill: View {
    /// The gap the caption under *Search this area* keeps from the weather
    /// badge, so the two pills stand in the same place.
    private static let badgeSpacing: CGFloat = 6
    /// Wide enough that a long title wraps rather than reaching the compass
    /// or the badge's column.
    private static let sideMargin: CGFloat = 16
    private static let leadingPadding: CGFloat = 14
    private static let contentSpacing: CGFloat = 4
    /// Half the tap target, so one line of text is a capsule and two are a
    /// rounded rectangle rather than a stadium.
    private static let cornerRadius = AccessibilityMetrics.minimumTapTarget / 2

    let session: TrailWalkSession
    /// Landscape's side panel, which moves the badge — and so this — into the
    /// safe area and against the panel's top margin.
    let usesSidePanel: Bool
    let onOpen: (UUID) -> Void

    var body: some View {
        VStack {
            if let notice = session.startNotice {
                pill(for: notice)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: session.startNotice)
        .padding(.top, topPadding)
        .padding(.horizontal, Self.sideMargin)
        .padding(.leading, usesSidePanel ? MapSidePanelLayout.mapInset : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Measured from the screen's edge in portrait, as the badge is.
        .ignoresSafeArea(.container, edges: usesSidePanel ? [] : .vertical)
    }

    /// Past the bottom of the weather badge, wherever the badge is.
    private var topPadding: CGFloat {
        (usesSidePanel ? MapSidePanelLayout.margin : WeatherBadge.topPadding)
            + AccessibilityMetrics.minimumTapTarget
            + Self.badgeSpacing
    }

    private func pill(for notice: TrailWalkStartNotice) -> some View {
        HStack(spacing: Self.contentSpacing) {
            Button {
                onOpen(notice.hikeID)
            } label: {
                Label {
                    Text("Hike started on \(notice.title)")
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "figure.hiking")
                        .foregroundStyle(.tint)
                }
                .font(.subheadline)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the trail, where the hike can be paused or ended.")
            .accessibilityIdentifier("walk-started-pill")

            Button("Dismiss", systemImage: "xmark") {
                session.dismissStartNotice()
            }
            .labelStyle(.iconOnly)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(
                width: AccessibilityMetrics.minimumTapTarget,
                height: AccessibilityMetrics.minimumTapTarget
            )
            .contentShape(.rect)
            .accessibilityIdentifier("walk-started-pill-dismiss")
        }
        .padding(.leading, Self.leadingPadding)
        .frame(minHeight: AccessibilityMetrics.minimumTapTarget)
        .glassSurface(.regular.interactive(), in: .rect(cornerRadius: Self.cornerRadius))
    }
}
