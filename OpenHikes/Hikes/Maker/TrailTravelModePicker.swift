import SwiftUI

/// Apple Maps' mode bar: the four modes in one rounded tray, the chosen one
/// filled. Reads only the chosen mode, so a route arriving does not rebuild it.
struct TrailTravelModePicker: View {
    let maker: TrailDraftController

    private static let trayRadius: CGFloat = 14
    private static let trayPadding: CGFloat = 4

    var body: some View {
        let chosen = maker.draft.travelMode
        HStack(spacing: Self.trayPadding) {
            ForEach(TrailTravelMode.allCases, id: \.self) { mode in
                let isChosen = mode == chosen
                Button {
                    maker.setTravelMode(mode)
                } label: {
                    Image(systemName: mode.symbolName)
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(isChosen ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .background {
                    if isChosen {
                        RoundedRectangle(cornerRadius: Self.trayRadius - Self.trayPadding)
                            .fill(Color.accentColor)
                    }
                }
                .accessibilityLabel(mode.label)
                .accessibilityAddTraits(isChosen ? .isSelected : [])
                .accessibilityIdentifier("trail-draft-mode-\(mode.rawValue)")
                .help(mode.label)
            }
        }
        .padding(Self.trayPadding)
        .background(.fill.tertiary, in: .rect(cornerRadius: Self.trayRadius))
        .animation(.snappy, value: chosen)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}
