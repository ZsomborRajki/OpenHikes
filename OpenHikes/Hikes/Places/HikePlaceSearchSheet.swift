//
//  HikePlaceSearchSheet.swift
//  OpenHikes
//
//  *Find Places Along Trail*: what OpenStreetMap has mapped on a finished
//  trail's line, offered as a list to keep or leave.
//
//  Every place found starts ticked, because a place the line passes is what
//  the maker's own save keeps without asking — see
//  ``TrailPlaceCorridorSearch``. The list is there for the hiker who does not
//  want the car park at the trailhead, not to make them choose each spring.
//

import OpenHikesData
import SwiftData
import SwiftUI

struct HikePlaceSearchSheet: View {
    let hike: Hike
    let source: any TrailPointSourcing
    /// The kinds a search asks for: the maker's switches, which are app-wide.
    let symbols: Set<TrailPlaceSymbol>

    @Environment(\.modelContext)
    private var modelContext
    @Environment(\.dismiss)
    private var dismiss
    @State private var search = HikePlaceSearch()
    /// Set when *Add*'s save was refused. The sheet stays up under it, with
    /// the same places ticked, so tapping *Add* again is the retry.
    @State private var refusal: HikePlaceSearchRefusal?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Places Along Trail")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") {
                            do throws(HikePlaceSearchRefusal) {
                                try search.add(to: hike, in: modelContext)
                                dismiss()
                            } catch {
                                refusal = error
                            }
                        }
                        .disabled(!search.canAdd)
                        .accessibilityIdentifier("hike-place-search-add")
                    }
                }
                .alert(isPresented: showingRefusal, error: refusal) {
                    Button("OK", role: .cancel) { /* dismisses */ }
                }
        }
        .task { search.start(for: hike, source: source, showing: symbols) }
        .onDisappear { search.cancel() }
    }

    private var showingRefusal: Binding<Bool> {
        Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })
    }

    @ViewBuilder private var content: some View {
        switch search.phase {
        case .searching:
            ProgressView("Looking along the trail…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let outage):
            ContentUnavailableView {
                Label("Couldn't Search", systemImage: "exclamationmark.triangle")
            } description: {
                Text(TrailPointNotice.outage(outage).caption.text)
            } actions: {
                // The community page's retry, and for the reason it has one: a
                // bare text button here is a 64 × 18 pt target (#662).
                Button("Try Again") { search.start(for: hike, source: source, showing: symbols) }
                    .glassButtonStyle()
            }
        case let .found(rows, outage):
            if rows.isEmpty {
                ContentUnavailableView(
                    "Nothing Else Mapped",
                    systemImage: "mappin.slash",
                    description: Text("OpenStreetMap has nothing more on this trail's line.")
                )
            } else {
                list(rows, outage: outage)
            }
        }
    }

    /// How far off the line a kept place may be, in the hiker's units.
    private static var reach: String {
        Measurement(value: TrailPlaceAnchor.touchedOffRouteMeters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    private func list(_ rows: [TrailPlaceRow], outage: CuratedTrailOutage?) -> some View {
        List {
            Section {
                ForEach(rows) { row in
                    Button { search.toggle(row.id) } label: {
                        HStack {
                            TrailPlaceRowView(row: row)
                            let isChosen = search.chosen.contains(row.id)
                            Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isChosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                .accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(search.chosen.contains(row.id) ? .isSelected : [])
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        """
                        Places within \(Self.reach) of the trail, from OpenStreetMap. \
                        Kinds turned off in the trail maker are left out.
                        """
                    )
                    if let outage {
                        Text(TrailPointNotice.outage(outage).caption.text)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .accessibilityIdentifier("hike-place-search-list")
    }
}
