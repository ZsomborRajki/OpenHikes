//
//  OfflineCountriesBar.swift
//  OpenHikes
//
//  What stands over *Offline Maps*' list and does not scroll with it: the
//  field that searches the areas by name, in the capsule the sheet's own
//  search field is drawn in, and beside it the order the list is in, in the
//  hikes list's capsule (``SortMenu``).
//
//  The order steps aside while the field has the keyboard or holds a query:
//  a search lists what answers it best first, whatever the order, and the
//  field takes the whole width to type in.
//

import OpenHikesShared
import SwiftUI

struct OfflineCountriesBar: View {
    @Binding var query: String
    var isSearchFocused: FocusState<Bool>.Binding
    /// The order the list is in, and the ones to offer.
    let sort: OfflineCountrySort
    /// The order the hiker picked, which the haptic answers rather than
    /// ``sort``: the list opens by name and turns nearest first as the
    /// hiker's position is read, a pass later, and that is no choice to feel.
    let chosenSort: OfflineCountrySort?
    let orders: [OfflineCountrySort]
    let onSort: (OfflineCountrySort) -> Void

    private static let spacing: CGFloat = 10
    private static let fieldPadding: CGFloat = 10

    var body: some View {
        let isSearching = isSearchFocused.wrappedValue || !query.isEmpty
        GlassStack {
            HStack(spacing: Self.spacing) {
                searchField
                if !isSearching { sortMenu }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .animation(.snappy, value: isSearching)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search", text: $query)
                .accessibilityIdentifier("offline-maps-search")
                .focused(isSearchFocused)
                .autocorrectionDisabled()
                .submitLabel(.search)
                #if os(iOS)
                .textInputAutocapitalization(.words)
                #endif
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("offline-maps-clear-search")
            }
        }
        .padding(Self.fieldPadding)
        .glassSurface(.regular, in: .capsule)
    }

    private var sortMenu: some View {
        SortMenu(
            options: orders.map { SortMenuOption(value: $0, title: $0.title, symbol: $0.symbol) },
            selection: Binding(
                get: { sort },
                set: { chosen in
                    if let chosen { onSort(chosen) }
                }
            ),
            title: sort.title,
            label: "Sort offline maps",
            identifier: "offline-maps-order-button"
        )
        .sensoryFeedback(HapticMoment.choiceChanged.feedback, trigger: chosenSort)
        .transition(.opacity)
    }
}
