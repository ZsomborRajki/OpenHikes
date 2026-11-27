//
//  WeatherCard.swift
//  OpenHikes
//
//  The panel every part of the weather sheet is drawn on, and the pieces the
//  panels share: the small capitals that name one, the row of a label and a
//  value, and the weather glyph with its chance of rain.
//
//  The shapes are Apple Weather's, which is what a hiker's eye already knows
//  how to read: a translucent panel on the sky, a glyph and a word in small
//  capitals at its head, the figure below. The panel's fill is the sky's to
//  say, because the sky under it is anything from a noon blue to a storm at
//  night, and no one fill both darkens the first and lifts the second — see
//  ``WeatherSky/panel``.
//

import SwiftUI

/// The sheet's measurements, named for the reason every other constant in
/// this folder is.
enum WeatherCardMetrics {
    /// Between one panel and the next, and between two tiles side by side.
    static let spacing: CGFloat = 12
    /// Between a panel's edge and what it holds.
    static let padding: CGFloat = 16
    /// Between a panel's heading and its contents.
    static let headingSpacing: CGFloat = 10
    /// Between the sheet's edge and its panels.
    static let margin: CGFloat = 16
    static let cornerRadius: CGFloat = 22
    /// Above and below a row of a label and a value.
    static let rowPadding: CGFloat = 11
    /// As wide as the sheet's column gets. An iPad's sheet is wider than
    /// this, and a forecast stretched across it is a row of figures with a
    /// hand's width between each.
    static let readableWidth: CGFloat = 560
    static let ruleOpacity = 0.16
    static let ruleThickness: CGFloat = 0.5

    static var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }
}

extension ShapeStyle where Self == Color {
    /// What the sheet draws its quieter text in on a panel: the headings,
    /// the values beside their labels, the captions. **Never on the bare
    /// sky**, where text is white — see ``WeatherSky/quietTextOpacity``.
    ///
    /// White, thinned, and spelled as that. The system's own `.secondary`
    /// is the obvious thing to ask for and was the wrong one here: over
    /// this sheet's sky, on iOS 27.2, text in it opened a saturated light
    /// blue and turned grey-white at the first scroll. Why was not run
    /// down. A color is drawn the same both times.
    static var weatherDim: Color { .white.opacity(WeatherSky.quietTextOpacity) }

    /// The chance of rain under a glyph — see ``WeatherSky/rainChanceTint``.
    static var weatherRainChance: Color { Color(hex: WeatherSky.rainChanceTint) ?? .cyan }
}

/// The hairline between two rows of a panel, in a color of its own for the
/// reason the quieter text has one.
struct WeatherRule: View {
    var body: some View {
        Rectangle()
            .fill(.white.opacity(WeatherCardMetrics.ruleOpacity))
            .frame(height: WeatherCardMetrics.ruleThickness)
            .accessibilityHidden(true)
    }
}

extension EnvironmentValues {
    /// The sky the weather sheet is drawn on, which its panels take their
    /// fill from — see ``WeatherSky/panel``.
    @Entry var weatherSky = WeatherSky.unknown
}

extension View {
    /// Draws the sheet's panel behind this view, and keeps what scrolls
    /// inside it within its corners.
    func weatherCardSurface() -> some View {
        modifier(WeatherCardSurface())
    }
}

private struct WeatherCardSurface: ViewModifier {
    @Environment(\.weatherSky) private var sky

    func body(content: Content) -> some View {
        let panel = sky.panel
        content
            .background(
                (Color(hex: panel.tint) ?? .black).opacity(panel.opacity),
                in: WeatherCardMetrics.shape
            )
            .clipShape(WeatherCardMetrics.shape)
    }
}

/// A panel with a heading.
struct WeatherCard<Content: View>: View {
    private let title: LocalizedStringKey
    private let systemImage: String
    private let bleeds: Bool
    private let content: Content

    /// - Parameter bleeds: Whether the contents run to the panel's edges, as
    ///   a strip that scrolls sideways does. The heading keeps its margin.
    init(
        _ title: LocalizedStringKey,
        systemImage: String,
        bleeds: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.bleeds = bleeds
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WeatherCardMetrics.headingSpacing) {
            WeatherCardHeading(title: title, systemImage: systemImage)
                .padding(.horizontal, WeatherCardMetrics.padding)
            content
                .padding(.horizontal, bleeds ? 0 : WeatherCardMetrics.padding)
        }
        .padding(.top, WeatherCardMetrics.padding)
        .padding(.bottom, WeatherCardMetrics.headingSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .weatherCardSurface()
    }
}

/// What a panel is about, in small capitals beside its glyph.
struct WeatherCardHeading: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(.weatherDim)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A label and its value on one line, the value at the trailing edge.
///
/// One accessibility element, the shape ``DetailRow`` takes: a label and a
/// value are one fact.
struct WeatherCardRow: View {
    private static let spacing: CGFloat = 12

    let label: LocalizedStringKey
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Self.spacing) {
            Text(label)
            Spacer(minLength: 0)
            Text(value)
                .foregroundStyle(.weatherDim)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .padding(.vertical, WeatherCardMetrics.rowPadding)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

/// One row of a panel's rows.
struct WeatherRowItem: Identifiable {
    /// What a test finds the row by, and what tells it from the rows
    /// beside it.
    let id: String
    let label: LocalizedStringKey
    let value: String
}

/// Rows of a label and a value, with a hairline between each two.
struct WeatherRows: View {
    let rows: [WeatherRowItem]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                if row.id != rows.first?.id {
                    WeatherRule()
                }
                WeatherCardRow(label: row.label, value: row.value)
                    .accessibilityIdentifier(row.id)
            }
        }
    }
}

/// A panel's text beside its drawing, or above it at an accessibility text
/// size, where the text needs the panel's whole width to be read.
struct WeatherBeside<Leading: View, Trailing: View>: View {
    private let leading: Leading
    private let trailing: Trailing

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: WeatherCardMetrics.spacing) {
                leading
                trailing
            }
        } else {
            HStack(alignment: .center, spacing: WeatherCardMetrics.padding) {
                leading
                trailing
            }
        }
    }
}

/// A sky's glyph, with the chance of rain under it where there is one to
/// speak of.
///
/// The chance is drawn only at or above
/// ``WeatherReadingFormat/precipitationChanceFloor``, and its line is kept
/// either way, so the glyphs stay level along an hourly strip and down the
/// days.
struct WeatherGlyph: View {
    let symbolName: String
    let precipitationChance: Double

    var body: some View {
        VStack(spacing: 1) {
            Image(systemName: symbolName)
                .symbolRenderingMode(.multicolor)
                .font(.title3)
                .accessibilityHidden(true)
            Text(verbatim: WeatherReadingFormat.precipitationChance(precipitationChance) ?? " ")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.weatherRainChance)
                .lineLimit(1)
                .fixedSize()
        }
    }
}
