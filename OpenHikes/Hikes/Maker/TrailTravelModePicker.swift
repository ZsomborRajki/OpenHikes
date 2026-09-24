import OpenHikesData
import SwiftUI

/// Apple Maps' mode bar: the four modes as one segmented control, icons only.
///
/// The platform's own segmented `Picker` rather than a row of hand-drawn
/// buttons, so the selection, its Liquid Glass look, Dynamic Type and the
/// "Hiking, 2 of 4, selected" VoiceOver reading all come from the system
/// instead of being re-implemented here. Each segment is a `Label` so it is
/// *spoken* by its word while it is *drawn* by its symbol.
///
/// Reads only the chosen mode, so a route arriving does not rebuild it. The
/// binding writes through ``TrailDraftController/setTravelMode(_:)`` rather
/// than onto the draft, like every other mutation in this feature.
struct TrailTravelModePicker: View {
    let maker: TrailDraftController

    var body: some View {
        Picker("Travel Mode", selection: selection) {
            ForEach(TrailTravelMode.allCases, id: \.self) { mode in
                Label(mode.label, systemImage: mode.symbolName)
                    .labelStyle(.iconOnly)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier("trail-draft-mode")
        .sensoryFeedback(.selection, trigger: maker.draft.travelMode)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
    }

    private var selection: Binding<TrailTravelMode> {
        Binding(
            get: { maker.draft.travelMode },
            set: { maker.setTravelMode($0) }
        )
    }
}
