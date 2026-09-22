import SwiftUI

/// Reads only the chosen mode, so a route arriving does not rebuild the selector.
struct TrailTravelModePicker: View {
    let maker: TrailDraftController

    var body: some View {
        HStack(spacing: 8) {
            ForEach(TrailTravelMode.allCases, id: \.self) { mode in
                Button {
                    maker.setTravelMode(mode)
                } label: {
                    Image(systemName: mode.symbolName)
                        .font(.title3)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(maker.draft.travelMode == mode ? Color.white : Color.accentColor)
                .background {
                    if maker.draft.travelMode == mode {
                        Capsule().fill(Color.accentColor)
                    }
                }
                .accessibilityLabel(mode.label)
                .accessibilityAddTraits(maker.draft.travelMode == mode ? .isSelected : [])
                .accessibilityIdentifier("trail-draft-mode-\(mode.rawValue)")
                .help(mode.label)
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}
