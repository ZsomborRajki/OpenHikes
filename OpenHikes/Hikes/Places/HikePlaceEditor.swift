//
//  HikePlaceEditor.swift
//  OpenHikes
//
//  Naming, kinding and describing a place the hiker made.
//
//  Offered from a place's screen, and only for the hiker's own places — see
//  ``TrailPlace/isHikersOwn``. The recording screen's *Add Place* asks the
//  same three questions in its own sheet, beside what OpenStreetMap has
//  mapped there; the kind picker is the one piece the two share — see
//  ``TrailPlaceKindPicker``.
//

import OpenHikesData
import SwiftUI

struct HikePlaceEditor: View {
    /// What the form says before the hiker changes anything.
    let place: TrailPlace
    let onSave: (_ name: String, _ symbol: TrailPlaceSymbol?, _ note: String) -> Void

    @Environment(\.dismiss)
    private var dismiss
    @State private var name = ""
    @State private var symbol: TrailPlaceSymbol?
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text(symbol?.label ?? String(localized: "Place")))
                        .accessibilityIdentifier("hike-place-name-field")
                    TrailPlaceKindPicker(selection: $symbol)
                }
                Section("Note") {
                    TextField("What is worth knowing here", text: $note, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("hike-place-note-field")
                }
            }
            .navigationTitle("Edit Place")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(name, symbol, note)
                        dismiss()
                    }
                    .accessibilityIdentifier("hike-place-save")
                }
            }
        }
        .onAppear {
            name = place.name
            symbol = place.symbol
            note = place.note
        }
    }
}
