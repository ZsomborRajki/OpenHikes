//
//  PlaceCardHeader.swift
//  OpenHikes
//
//  The title row of an Apple Maps place card: a bold title over a secondary
//  line, and the screen's own controls on the trailing edge, where Maps puts
//  Share and Close. The hike detail, a walk's summary and the recording screen
//  all open with one, over the stats ``StatSummary`` draws.
//

import SwiftUI

struct PlaceCardHeader<Leading: View, Title: View, Subtitle: View, Trailing: View>: View {
    private static var spacing: CGFloat { 14 }

    private let leading: Leading
    private let title: Title
    private let subtitle: Subtitle
    private let trailing: Trailing

    init(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder title: () -> Title,
        @ViewBuilder subtitle: () -> Subtitle,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.leading = leading()
        self.title = title()
        self.subtitle = subtitle()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: Self.spacing) {
            leading
            VStack(alignment: .leading, spacing: 4) {
                title
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                subtitle
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            trailing
        }
    }
}

extension PlaceCardHeader where Trailing == EmptyView {
    /// A header with nothing to control: a finished walk's, whose actions sit
    /// further down the page.
    init(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder title: () -> Title,
        @ViewBuilder subtitle: () -> Subtitle
    ) {
        self.init(leading: leading, title: title, subtitle: subtitle) { EmptyView() }
    }
}

extension PlaceCardHeader where Leading == EmptyView {
    /// A header with no mark ahead of the title — the recording screen's,
    /// whose status dot is part of the title it colours.
    init(
        @ViewBuilder title: () -> Title,
        @ViewBuilder subtitle: () -> Subtitle,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(leading: { EmptyView() }, title: title, subtitle: subtitle, trailing: trailing)
    }
}

extension View {
    /// A place-card title-row control: a round glass button showing only its
    /// symbol, like Maps' Share and Close. The title is still the button's
    /// accessibility label, so VoiceOver and UI tests find it by name.
    func placeCardControl() -> some View {
        labelStyle(.iconOnly)
            .buttonBorderShape(.circle)
            .controlSize(.large)
    }
}
