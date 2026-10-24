//
//  CommunityTabTipView.swift
//  OpenHikes
//
//  The *Community* tab's first-run tip, under the picker it is about.
//
//  Inline rather than a popover, for two reasons. A popover points at the
//  middle of what it is attached to, and the middle of a segmented control is
//  the line between its two segments rather than the one this tip is about —
//  which is also why this one has no arrow, and names the tab instead. And
//  inline is how the sheet already gives its other first-run hint — the empty
//  list's sentence about the buttons on the map — so the sheet says both the
//  same way, without putting anything over the screen.
//
//  A view of its own so the group is read here rather than in
//  ``MapSheetHikes``, whose body is the `@Query`'s — see *Render isolation, in
//  practice* in `AGENTS.md`.
//

import SwiftUI
import TipKit

struct CommunityTabTipView: View {
    @Environment(\.appTips) private var tips

    var body: some View {
        if let tip = tips?.main.currentTip as? CommunityTabTip {
            TipView(tip)
                .padding(.horizontal)
        }
    }
}
