//
//  TrailDraftActions.swift
//  OpenHikes
//
//  The things a hiker can do to a line that is already drawn.
//
//  ## One menu rather than a row of controls
//
//  Five verbs — undo, redo, reverse, close the loop, and clear — over a screen
//  that already carries a route, a switch and two toolbar buttons. Spread
//  across the screen they would be most of it; in a menu they are one glyph,
//  and the two that matter while drawing (a tap on the map, and Save) keep the
//  room.
//
//  ## Reorder is not here any more, and neither is Done
//
//  Both were the cost of reordering being a *mode*: the hiker asked for it from
//  this menu or from a long press on a row, the list went into edit mode, and a
//  Done control took it back out — with a row's tap belonging to the list for
//  as long as it was on. The maker's rows are Apple Maps' directions rows now,
//  which carry their grabbers permanently, so the list is in edit mode from the
//  moment it appears and there is nothing to enter, leave or offer. See
//  ``TrailDraftView``.
//
//  What that removed along with them is the `.contextMenu` this file used to
//  carry — a long press on a row that offered *Reorder Points*, which was the
//  discoverable half of a mode that no longer exists. The finding behind it is
//  still true and is still worth not rediscovering: a `LongPressGesture` on a
//  row that is a `Button` fires the button, and a `.contextMenu` is the
//  platform's own long press and suppresses what is underneath it.
//
//  ## Nothing inside the menu carries an identifier
//
//  Only the menu itself does. A `Menu`'s contents are built by the system when
//  it opens, and an `accessibilityIdentifier` on a button inside one does not
//  survive that — `TrailMakerUITests` looked for them and found nothing. So the
//  entries are reached by their titles, and an identifier here would be a
//  promise the automation cannot keep.
//
//  ## Why *Clear* asks and the rest do not
//
//  Everything else here is one step of undo away. Clear is too — it takes a
//  step like any other edit — but it is the only one whose *whole* effect is
//  to remove work, so a mis-tap on it looks exactly like the app having lost
//  the drawing. The dialog costs a tap on the one verb nobody uses twice.
//

import SwiftUI

/// The maker's edit menu.
///
/// Its own `View` for the reason every other piece of this screen is one: it
/// reads ``TrailDraft/canUndo``, ``TrailDraft/canRedo`` and the two shape
/// questions, and declared inside ``TrailDraftView``'s body those reads would
/// rebuild the whole route every time a stop went down.
struct TrailDraftActionsMenu: View {
    let maker: TrailDraftController
    /// Asked rather than done here, because the dialog that asks belongs to
    /// the screen — a modal presented from a toolbar closure is presented from
    /// the toolbar, which is not inside the sheet's contents. See
    /// ``TrailDraftView``.
    var onClear: () -> Void

    private var draft: TrailDraft { maker.draft }

    var body: some View {
        Menu {
            historySection
            shapeSection
            Section {
                Button("Clear", systemImage: "trash", role: .destructive, action: onClear)
                    .disabled(draft.isEmpty)
            }
        } label: {
            Label("Edit Trail", systemImage: "ellipsis.circle")
        }
        .accessibilityIdentifier("trail-draft-actions")
        .disabled(draft.isEmpty && !draft.canUndo && !draft.canRedo)
    }

    @ViewBuilder private var historySection: some View {
        Section {
            Button("Undo", systemImage: "arrow.uturn.backward", action: maker.undo)
                .disabled(!draft.canUndo)
            Button("Redo", systemImage: "arrow.uturn.forward", action: maker.redo)
                .disabled(!draft.canRedo)
        }
    }

    @ViewBuilder private var shapeSection: some View {
        Section {
            Button("Reverse", systemImage: "arrow.left.arrow.right", action: maker.reverse)
                .disabled(draft.waypoints.isEmpty)
            Button("Close the Loop", systemImage: "arrow.trianglehead.clockwise", action: maker.closeTheLoop)
                .disabled(!draft.canCloseTheLoop)
        }
    }
}
