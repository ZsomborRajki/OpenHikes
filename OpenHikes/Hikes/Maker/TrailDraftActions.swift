//
//  TrailDraftActions.swift
//  OpenHikes
//
//  The things a hiker can do to a line that is already drawn.
//
//  ## One menu rather than a row of controls
//
//  Seven verbs — undo, redo, reorder, reverse, close the loop, clear, and
//  leaving reorder mode — over a screen that already carries a search field, a
//  switch, a list of points and two toolbar buttons. Spread across the screen
//  they would be most of it; in a menu they are one glyph, and the two that
//  matter while drawing (a tap on the map, and Save) keep the room.
//
//  It is in the navigation bar rather than in the list, and that is not a
//  layout preference. **A `List` in edit mode gives a row's tap to the list**,
//  so the control that turns edit mode *off* cannot be a row inside it — the
//  hiker would be unable to reach the way out. The same trap the hikes list
//  records: see the note on its own Done control in `MapSheetHikes.swift`.
//
//  ## Reorder is reached twice, and the second way is the discoverable one
//
//  From this menu, and from a long press on a row. The long press is a
//  `.contextMenu` rather than a `LongPressGesture` of our own, and that is the
//  finding the hikes list paid for: a long press on a row that is a `Button`
//  still fires the button. A context menu is the platform's own long press and
//  suppresses what is underneath it.
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

/// The maker's edit menu, and the Done control that replaces it while the list
/// is being reordered.
///
/// Its own `View` for the reason every other piece of this screen is one: it
/// reads ``TrailDraft/canUndo``, ``TrailDraft/canRedo`` and the two shape
/// questions, and declared inside ``TrailDraftView``'s body those reads would
/// rebuild the list of points every time a point went down.
struct TrailDraftActionsMenu: View {
    let maker: TrailDraftController
    @Binding var editMode: EditMode
    /// Asked rather than done here, because the dialog that asks belongs to
    /// the screen — a modal presented from a toolbar closure is presented from
    /// the toolbar, which is not inside the sheet's contents. See
    /// ``TrailDraftView``.
    var onClear: () -> Void

    private var draft: TrailDraft { maker.draft }

    var body: some View {
        if editMode == .active {
            Button("Done") { withAnimation { editMode = .inactive } }
                .accessibilityIdentifier("trail-draft-reorder-done")
        } else {
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
            Button("Reorder Points", systemImage: "arrow.up.arrow.down") {
                withAnimation { editMode = .active }
            }
            .disabled(!draft.canBeRearranged)
            Button("Reverse", systemImage: "arrow.left.arrow.right", action: maker.reverse)
                .disabled(!draft.canBeRearranged)
            Button("Close the Loop", systemImage: "arrow.trianglehead.clockwise", action: maker.closeTheLoop)
                .disabled(!draft.canCloseTheLoop)
        }
    }
}

/// The long press on a row that offers to rearrange the line.
///
/// A modifier rather than a `.contextMenu` written into the `ForEach`, so the
/// reason it is a context menu at all travels with it — see the file header.
struct TrailDraftReorderMenu: ViewModifier {
    @Binding var editMode: EditMode

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Reorder Points", systemImage: "arrow.up.arrow.down") {
                withAnimation { editMode = .active }
            }
        }
    }
}

extension View {
    func trailDraftReorderMenu(_ editMode: Binding<EditMode>) -> some View {
        modifier(TrailDraftReorderMenu(editMode: editMode))
    }
}
