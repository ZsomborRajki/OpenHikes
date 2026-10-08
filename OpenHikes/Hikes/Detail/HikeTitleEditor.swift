//
//  HikeTitleEditor.swift
//  OpenHikes
//
//  The hike's name at the top of its detail card, and the field that renames
//  it in place.
//

import OpenHikesData
import SwiftUI

/// The title of ``HikeDetailView``'s card, or the field editing it.
///
/// A view of its own rather than a line of the screen's header, because a
/// rename is a keystroke at a time and every keystroke writes
/// ``HikeDetailInteraction/titleDraft`` — and whichever body *makes* the
/// field's binding is subscribed to that property, which
/// `HikeTitleEditorIsolationTests` pins. Made in the card, that was the
/// `ScrollViewReader` closure the whole card is drawn in, and a rename re-ran
/// all of it per keystroke: the header, the stat strip and list, three
/// place-card lists and every toggle and button in them. Here a keystroke
/// re-runs this view and the field in it.
///
/// The focus lives here for the same reason. `@FocusState` is a dynamic
/// property, and one declared on the detail screen invalidated the whole
/// screen each time the keyboard came up or went down.
struct HikeTitleEditor: View {
    let hike: Hike
    @Bindable var interaction: HikeDetailInteraction

    /// So tapping *Rename* puts the keyboard up on the field rather than
    /// asking for a second tap.
    ///
    /// Raised from the field's own `onAppear` rather than from the button that
    /// flips ``HikeDetailInteraction/isEditingTitle``: the field does not exist
    /// yet at the moment of the tap, and focus asked for before then is
    /// dropped.
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        if interaction.isEditingTitle {
            TextField(hike.title, text: $interaction.titleDraft)
                .accessibilityLabel("Hike name")
                .accessibilityIdentifier("hike-title-field")
                .focused($isFieldFocused)
                .onAppear { isFieldFocused = true }
                // The return key is the whole of how a rename is confirmed
                // here, and the keyboard toolbar that used to carry a *Done*
                // beside it is deliberately gone.
                //
                // A `ToolbarItemGroup(placement: .keyboard)` on this field is
                // what stopped the app ever reporting itself idle, which
                // XCUITest pays for at 60 seconds a gesture. On a simulator in
                // the state that provokes it, `testRenamingAHikeUpdatesItsRow`
                // took 677.9s across eight of those waits; with this accessory
                // removed and nothing else changed, 28.3s. Nothing is spinning
                // — the app sits at 0% CPU throughout — so what is left over is
                // an animation that never reports completion, not work.
                //
                // It is the accessory arriving and leaving *with the field*
                // that does it rather than the accessory itself, and both
                // halves cost 60s. Declared here, the app stalls from the
                // moment the pencil is tapped. Hoisted onto the always-present
                // header and gated on `isEditingTitle`, the keyboard rises
                // clean and the commit stalls instead, because the button
                // leaves as the keyboard does — 138.8s, which is the shape
                // #539 was filed on. ``CommunityReviewView`` keeps its own
                // keyboard *Done*, where it is the only way to reach the
                // decision, and measures clean at 20.5s on the same simulator:
                // there both the field and the accessory are always in the
                // hierarchy.
                .submitLabel(.done)
                .onSubmit(commit)
        } else {
            Text(hike.displayTitle)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func commit() {
        hike.customName = HikeTitle.bounded(interaction.titleDraft)
        isFieldFocused = false
        interaction.isEditingTitle = false
    }
}
