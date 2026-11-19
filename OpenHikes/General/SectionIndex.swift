//
//  SectionIndex.swift
//  OpenHikes
//
//  The index down the trailing edge of a list by name: a letter a section,
//  and a tap or a drag on one jumps to it. SwiftUI draws it from iOS 26;
//  below that a section keeps its header and the list has no index, which
//  costs a hiker a longer scroll and nothing else.
//
//  SwiftUI draws every letter whatever the list's height, and a list too
//  short for them loses the first and the last off its edges, so a list
//  that can be short says when its letters are shown. And it reads the index
//  off a section as the section joins the list: a letter given or withheld
//  afterwards changes nothing. So a section is another section once its
//  letter comes or goes, which the list takes without losing its place.
//  Both measured on iOS 27.2.
//

import SwiftUI

extension View {
    /// Files the section this is put on under `letter` in its list's index,
    /// while `isShown`.
    @ViewBuilder
    func sectionIndexLetter(_ letter: String, isShown: Bool) -> some View {
        if #available(iOS 26.0, *) {
            sectionIndexLabel(isShown ? letter : nil)
                .id(SectionIndexIdentity(letter: letter, isShown: isShown))
        } else {
            self
        }
    }
}

/// What makes a lettered section the one it is: its letter, and whether the
/// index shows it.
private struct SectionIndexIdentity: Hashable {
    let letter: String
    let isShown: Bool
}
