//
//  HikeWalkHistory.swift
//  OpenHikes
//
//  The History face of the hike detail: this trail's walks, partial or full,
//  newest first, each row pushing its summary.
//
//  Its own `@Query` for the reason `MapSheetHikes` has one: a write to the
//  `Hike` — a title edit, a tint change, the auto-follow toggle — does not
//  re-rank walks, and a walk finishing redraws this list and not the Details
//  body. It filters on `HikeWalk.hikeID`, a column of its own, rather than
//  through the relationship, so the query never touches the host row.
//

import SwiftData
import SwiftUI

struct HikeWalkHistory: View {
    @Query private var walks: [HikeWalk]

    let hike: Hike
    let onOpen: (HikeWalk) -> Void

    init(hike: Hike, onOpen: @escaping (HikeWalk) -> Void) {
        self.hike = hike
        self.onOpen = onOpen
        let hikeID = hike.id
        _walks = Query(
            filter: #Predicate<HikeWalk> { walk in walk.hikeID == hikeID },
            sort: [SortDescriptor(\HikeWalk.startedAt, order: .reverse)]
        )
    }

    var body: some View {
        // Where a walk ending lands: this body, and not `HikeDetailBody`.
        RenderSignpost.mark("HikeWalkHistoryBody", "\(walks.count) walks")
        return Group {
            if walks.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(walks) { walk in
                        Button {
                            onOpen(walk)
                        } label: {
                            WalkRow(walk: walk, tint: hike.tintOpaque)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "figure.walk")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No walks yet")
                .font(.headline)
            Text("Turn on Follow This Trail in Details, then set off along the trail. Finished walks are kept here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .accessibilityIdentifier("walk-history-empty")
    }
}
