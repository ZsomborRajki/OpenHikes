//
//  RouteStepsCard.swift
//  OpenHikes
//
//  What *Edit Route* offers beyond cutting the ends off: a stretch to pick
//  out and change, the things done to the whole line, and *Undo*. See
//  `RouteTrimSession+Steps.swift` for what each does.
//
//  ## Two faces, so the screen never offers both
//
//  The way in is three rows: *Change a Stretch*, a menu of what is done to
//  the whole route, and *Undo* once there is something to take back. Picking
//  a stretch out turns the card to what can be done with it — follow mapped
//  trails, straighten, remove — and *Cancel*. A hiker is asked one thing at
//  a time: which stretch, and then what of it.
//
//  Views of their own for the reason everything on this screen is: what they
//  read — whether a stretch is being picked, whether a path is being asked
//  for — is theirs and not the screen's.
//

import OpenHikesData
import SwiftUI

struct RouteStepsCard: View {
    let session: RouteTrimSession

    var body: some View {
        if session.isSelectingStretch {
            RouteStretchVerbs(session: session)
        } else {
            PlaceCardList {
                Button {
                    Task { await session.beginStretch() }
                } label: {
                    PlaceCardActionLabel(
                        title: String(localized: "Change a Stretch"),
                        systemImage: "point.topleft.down.to.point.bottomright.curvepath"
                    )
                }
                .buttonStyle(.plain)
                .disabled(!session.canMakeSteps)
                .accessibilityIdentifier("route-stretch-begin")
                RouteWholeLineMenu(session: session)
                if session.canUndo {
                    Button {
                        Task { await session.undo() }
                    } label: {
                        PlaceCardActionLabel(
                            title: String(localized: "Undo"),
                            systemImage: "arrow.uturn.backward.circle"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("route-step-undo")
                }
            }
        }
    }
}

/// What is done to the whole route, in one menu: turned round, doubled back,
/// closed, or — a loop — begun somewhere else.
struct RouteWholeLineMenu: View {
    let session: RouteTrimSession

    var body: some View {
        Menu {
            Button("Reverse", systemImage: "arrow.left.arrow.right") {
                Task { await session.reverse() }
            }
            if session.returnsToItsStart {
                // The start handle says where: a loop has no other place to
                // point at one.
                Button {
                    Task { await session.startLoopAtCut() }
                } label: {
                    Label("Start Loop Here", systemImage: "flag")
                    if !session.canStartLoopAtCut {
                        Text("Drag the start handle to the new start first.")
                    }
                }
                .disabled(!session.canStartLoopAtCut)
            } else if !session.keptEndsMeet {
                // A line that already ends where it began, across a pause
                // that moved the walk, has no shape and still nothing to
                // come back from.
                Button("Out and Back", systemImage: "arrow.uturn.right") {
                    Task { await session.goOutAndBack() }
                }
                Button("Close Loop", systemImage: "arrow.triangle.capsulepath") {
                    Task { await session.closeLoop() }
                }
            }
        } label: {
            HStack {
                PlaceCardActionLabel(title: String(localized: "Whole Route"), systemImage: "ellipsis.circle")
                if session.isRouting {
                    ProgressView()
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!session.canMakeSteps)
        .accessibilityIdentifier("route-whole-menu")
    }
}

/// What can be done with the stretch the two handles pick out.
struct RouteStretchVerbs: View {
    let session: RouteTrimSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PlaceCardList(title: String(localized: "Stretch")) {
                row(
                    String(localized: "Follow Trails"),
                    systemImage: "point.bottomleft.forward.to.point.topright.scurvepath",
                    identifier: "route-stretch-follow"
                ) {
                    await session.followTrailsAcrossStretch()
                }
                row(
                    String(localized: "Straighten"),
                    systemImage: "line.diagonal",
                    identifier: "route-stretch-straighten"
                ) {
                    await session.straightenStretch()
                }
                row(String(localized: "Remove"), systemImage: "scissors", identifier: "route-stretch-remove") {
                    await session.takeOutStretch()
                }
                // The whole line taken out would leave no hike.
                .disabled(session.picksWholeLine)
                row(String(localized: "Cancel"), systemImage: "xmark", identifier: "route-stretch-cancel") {
                    await session.endStretch()
                }
            }
            Text("Drag the two handles to the ends of the stretch, here or on the map.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func row(
        _ title: String,
        systemImage: String,
        identifier: String,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack {
                PlaceCardActionLabel(title: title, systemImage: systemImage)
                if session.isRouting, identifier == "route-stretch-follow" {
                    ProgressView()
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!session.canMakeSteps)
        .accessibilityIdentifier(identifier)
    }
}
