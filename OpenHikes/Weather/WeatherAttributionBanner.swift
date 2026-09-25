//
//  WeatherAttributionBanner.swift
//  OpenHikes
//
//  Apple Weather's mark and legal link, as the first row of the weather sheet.
//
//  The credits used to be only at the very bottom of ``WeatherDetailView``,
//  under the hourly strip, the readings, daylight and ten days of forecast:
//  on the screen, as WeatherKit's terms ask, but not where anybody opening the
//  sheet would see them. App Review rejected 1.1 (7) under guideline 5.2.5
//  because it could not find the mark. So the mark now leads the sheet,
//  visible at either detent without scrolling, with the legal link on the same
//  line. The fuller *Data Source* section stays at the bottom, where the
//  wording and Apple's own link title have room.
//
//  Its own file, not a member of the sheet, because the sheet is at both of
//  SwiftLint's length limits.
//

import SwiftUI

struct WeatherAttributionBanner: View {
    private static let spacing: CGFloat = 12

    /// `nil` until WeatherKit answers, and for good if it never does. Handed
    /// in rather than asked for again, since the sheet already holds it.
    let marks: WeatherAttributionMarks?

    @Environment(\.colorScheme)
    private var colorScheme

    var body: some View {
        Section {
            HStack(spacing: Self.spacing) {
                mark
                Spacer(minLength: 0)
                Link(
                    String(localized: "Legal", comment: "Link to Apple Weather's legal attribution page"),
                    destination: marks?.legalPageURL ?? AppleWeatherAttribution.fallbackLegalPageURL
                )
                    .font(.footnote)
                    // The frame on the link rather than padding in its label,
                    // so "Legal" stays level with the mark: in footnote it is
                    // narrower and shorter than the audit's minimum.
                    .minimumTapTarget()
                    // No label of Apple's here: `legalAttributionText` is the
                    // whole data-source list, paragraphs of it, and the bottom
                    // section is where that is shown. VoiceOver reads "Legal"
                    // straight after "Apple Weather", which says what it is.
                    .accessibilityIdentifier("weather-legal-link-top")
            }
            // A caption under the title rather than a row among the readings:
            // no card behind it, and no more height than the mark needs.
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    /// The combined " Weather" mark Apple publishes, or the same words in
    /// text until it arrives, and for good if it never does.
    ///
    /// Text rather than nothing while it loads, unlike the bottom section's
    /// placeholder: there the wording beneath carries the credit, while here
    /// the mark is the only thing on its line.
    private var mark: some View {
        Group {
            if let marks {
                AsyncImage(url: marks.markURL(inDarkMode: colorScheme == .dark)) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: AppleWeatherAttribution.markHeight)
                    } else {
                        textMark
                    }
                }
            } else {
                textMark
            }
        }
        // The audit sizes this element too, button or not, and a mark shorter
        // than the minimum fails it. The frame alone is not enough: the
        // element keeps the image's own bounds until the shape says otherwise.
        .frame(minHeight: AccessibilityMetrics.minimumTapTarget)
        .contentShape(.accessibility, .rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppleWeatherAttribution.serviceName)
        .accessibilityIdentifier("weather-mark")
    }

    /// The trademark as Apple writes it: the Apple glyph, then "Weather".
    private var textMark: some View {
        Text(verbatim: AppleWeatherAttribution.textMark)
            .font(.subheadline.weight(.semibold))
    }
}
