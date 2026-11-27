//
//  WeatherAttributionBanner.swift
//  OpenHikes
//
//  Apple Weather's credits on the weather sheet: the mark and the legal link
//  at its head, and the fuller wording at its foot.
//
//  The credits used to be only at the very bottom of ``WeatherDetailView``,
//  under the hours, the readings, daylight and the days: on the screen, as
//  WeatherKit's terms ask, but not where anybody opening the sheet would see
//  them. App Review rejected 1.1 (7) under guideline 5.2.5 because it could
//  not find the mark. So the mark leads the sheet, above the temperature and
//  every panel, with the legal link on the same line: the first thing in
//  the sheet, so it is on screen without scrolling at either height and at
//  every text size. Set under the temperature, which is set large, it was
//  not: a half sheet at the largest text size opened with the mark below
//  the screen. `testTheWeatherSheetOpensOnAppleWeathersCredits` holds it
//  there, at that size and at both heights. The fuller credit stays at the
//  foot, where the wording and Apple's own link title have room.
//
//  Both are drawn light on the sheet's sky at every hour, so both take
//  Apple's mark for dark backgrounds: the sheet's own color scheme says so —
//  see ``WeatherSky``.
//

import SwiftUI

struct WeatherAttributionBanner: View {
    private static let spacing: CGFloat = 14

    /// `nil` until WeatherKit answers, and for good if it never does. Handed
    /// in rather than asked for again, since the sheet already holds it.
    let marks: WeatherAttributionMarks?

    var body: some View {
        HStack(spacing: Self.spacing) {
            WeatherAttributionMark(marks: marks, showsTextUntilLoaded: true)
                // The audit sizes this element too, button or not, and a
                // mark shorter than the minimum fails it. The frame alone is
                // not enough: the element keeps the image's own bounds until
                // the shape says otherwise.
                .frame(minHeight: AccessibilityMetrics.minimumTapTarget)
                .contentShape(.accessibility, .rect)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(AppleWeatherAttribution.serviceName)
                .accessibilityIdentifier("weather-mark")
            Link(destination: marks?.legalPageURL ?? AppleWeatherAttribution.fallbackLegalPageURL) {
                // Underlined on the text itself: the sheet's links are white
                // like everything else on it, so the line is what says this
                // one can be tapped, and set on the link it was drawn on iOS
                // 27 and not on iOS 18.
                Text(String(localized: "Legal", comment: "Link to Apple Weather's legal attribution page"))
                    .underline()
            }
                .font(.footnote.weight(.medium))
                // The frame on the link rather than padding in its label,
                // so "Legal" stays level with the mark: in footnote it is
                // narrower and shorter than the audit's minimum.
                .minimumTapTarget()
                // No label of Apple's here: `legalAttributionText` is the
                // whole data-source list, paragraphs of it, and the foot of
                // the sheet is where that is shown. VoiceOver reads "Legal"
                // straight after "Apple Weather", which says what it is.
                .accessibilityIdentifier("weather-legal-link-top")
        }
        .frame(maxWidth: .infinity)
    }
}

/// Apple Weather's credits in full, which the WeatherKit terms require on
/// the screen presenting its data.
///
/// Every branch here still shows the words "Apple Weather" and still offers
/// the legal link. The mark is an improvement on that floor, not a
/// precondition for it: it arrives over the network from a service that has
/// just failed to deliver a forecast often enough that treating it as
/// reliable would mean shipping a sheet that is sometimes blank.
struct WeatherDataSource: View {
    private static let spacing: CGFloat = 6
    private static let topPadding: CGFloat = 12

    let marks: WeatherAttributionMarks?

    var body: some View {
        VStack(spacing: Self.spacing) {
            // Nothing while it loads, unlike the banner's mark: the wording
            // below already carries the attribution, so a stand-in here
            // would only advertise that something is missing. And not
            // announced, because the mark says "Apple Weather" and so does
            // the line beneath it.
            WeatherAttributionMark(marks: marks, showsTextUntilLoaded: false)
                .accessibilityHidden(true)

            Text("Weather data provided by \(AppleWeatherAttribution.serviceName)")
                .font(.footnote)
                .accessibilityIdentifier("weather-attribution")

            // Apple's own wording where it has sent it, which is its whole
            // list of sources, paragraphs of it: set as the small print it
            // is, and still the link it always was. Until then, and for good
            // if it never comes, a title of ours that looks like a link.
            // White like every word on the bare sky, small print included —
            // see ``WeatherSky/quietTextOpacity``.
            Link(destination: marks?.legalPageURL ?? AppleWeatherAttribution.fallbackLegalPageURL) {
                if let marks {
                    Text(marks.linkTitle)
                        .font(.caption2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, Self.spacing)
                } else {
                    Text(WeatherAttributionMarks.defaultLinkTitle)
                        .font(.footnote.weight(.medium))
                        .underline()
                }
            }
            .minimumTapTarget()
            .accessibilityIdentifier("weather-legal-link")
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, Self.topPadding)
        .padding(.horizontal, WeatherCardMetrics.padding)
    }
}

/// The combined " Weather" mark Apple publishes.
private struct WeatherAttributionMark: View {
    let marks: WeatherAttributionMarks?
    /// Whether the same words stand in as text until the mark arrives, and
    /// for good if it never does. The banner's mark is the only thing on its
    /// line, so there they do.
    let showsTextUntilLoaded: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let marks {
            AsyncImage(url: marks.markURL(inDarkMode: colorScheme == .dark)) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(height: AppleWeatherAttribution.markHeight)
                } else {
                    textMark
                }
            }
            // As wide as the mark and no wider, so the line it is on can
            // be centered: left to itself the image takes the row.
            .fixedSize()
        } else {
            textMark
        }
    }

    /// The trademark as Apple writes it: the Apple glyph, then "Weather".
    @ViewBuilder private var textMark: some View {
        if showsTextUntilLoaded {
            Text(verbatim: AppleWeatherAttribution.textMark)
                .font(.subheadline.weight(.semibold))
        }
    }
}
