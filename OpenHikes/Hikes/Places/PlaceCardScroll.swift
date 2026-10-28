//
//  PlaceCardScroll.swift
//  OpenHikes
//
//  Small detents leave dragging to the sheet. Returning to one, or choosing
//  another place on the map, always brings the card's title and actions back.
//  At the largest detent, accessibility text can scroll through every fact.
//

import SwiftUI

struct PlaceCardScroll<Selection: Equatable, Content: View>: View {
    let selection: Selection
    let allowsScrolling: Bool
    @ViewBuilder let content: Content

    var body: some View {
        ScrollViewReader { position in
            ScrollView {
                content.id("place-card-top")
            }
            .scrollDisabled(!allowsScrolling)
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: selection) { position.scrollTo("place-card-top", anchor: .top) }
            .onChange(of: allowsScrolling) { position.scrollTo("place-card-top", anchor: .top) }
        }
    }
}
