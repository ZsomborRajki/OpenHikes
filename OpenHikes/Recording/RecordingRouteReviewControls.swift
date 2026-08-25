//
//  RecordingRouteReviewControls.swift
//  OpenHikes
//
//  The screen a recording the matcher moved — or found ambiguous — has to pass
//  through before it is saved: one section at a time, the hiker keeps the
//  trail the matcher found or hands the section back to the GPS that recorded
//  it.
//
//  Accessibility identifiers stay on the leaves UI automation taps: SwiftUI
//  pushes a container's identifier down onto every descendant, which would
//  leave the whole review answering to one name.
//

import os
import SwiftUI

struct RecordingRouteReviewControls: View {
    let recorder: HikeRecorder
    let review: RecordingRouteReview
    var onSaved: (Hike) -> Void

    private let choicePadding: CGFloat = 10
    private let choiceRadius: CGFloat = 10
    /// Matches the surrounding stack, so the cards keep the rhythm they had.
    private let choiceSpacing: CGFloat = 12
    /// Under `choiceSpacing`, so the cards stay separate targets at rest.
    private let choiceGlassSpacing: CGFloat = 10

    var body: some View {
        if let section = review.current {
            sectionContent(for: section)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func sectionContent(
        for section: RouteReviewSection
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                "Section \(review.currentIndex + 1) of "
                    + "\(review.sections.count)"
            )
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("review-section-title")

            Text(prompt(for: section))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // One container for the stack of choice cards: they sample the
            // screen once between them rather than once each, and blend at
            // their edges the way a set of related controls should.
            GlassStack(spacing: choiceGlassSpacing) {
                VStack(alignment: .leading, spacing: choiceSpacing) {
                    ForEach(
                        Array(section.availableChoices.enumerated()),
                        id: \.offset
                    ) { _, choice in
                        choiceButton(choice, in: section)
                    }
                }
            }

            navigationButtons
            saveReviewedHikeButton
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var navigationButtons: some View {
        HStack {
            Button("Previous") {
                recorder.moveToPreviousReviewSection()
            }
            .glassButtonStyle()
            .disabled(!review.canMoveBackward)
            .accessibilityIdentifier("review-previous-section")
            Spacer()
            Button("Next") {
                recorder.moveToNextReviewSection()
            }
            .glassButtonStyle()
            .disabled(!review.canMoveForward)
            .accessibilityIdentifier("review-next-section")
        }
    }

    private var saveReviewedHikeButton: some View {
        Button("Save Reviewed Hike") {
            Task {
                do {
                    onSaved(try await recorder.saveReviewedRecording())
                } catch {
                    HikeRecorder.logger.error(
                        "Reviewed recording save failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
        .prominentGlassButtonStyle()
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("review-save-hike")
    }

    private func choiceButton(
        _ choice: TrailRouteChoice,
        in section: RouteReviewSection
    ) -> some View {
        Button {
            recorder.selectRouteChoice(choice)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(
                    systemName: review.choice(for: section) == choice
                        ? "checkmark.circle.fill"
                        : "circle"
                )
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(for: choice, in: section))
                        .font(.subheadline.weight(.semibold))
                    Text(subtitle(for: choice, in: section))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(choicePadding)
        // Glass, and tinted with the accent when it is the chosen one: the
        // selection used to be carried only by a checkmark glyph, and the card
        // behind it was the same flat wash either way.
        .glassSurface(
            review.choice(for: section) == choice
                ? .regular.tint(.accentColor).interactive()
                : .regular.interactive(),
            in: .rect(cornerRadius: choiceRadius)
        )
        .accessibilityIdentifier(Self.identifier(for: choice))
        .accessibilityAddTraits(
            review.choice(for: section) == choice ? [.isSelected] : []
        )
    }

    static func identifier(for choice: TrailRouteChoice) -> String {
        switch choice {
        case .matched: "review-choice-trail"
        case .gps: "review-choice-gps"
        case .alternative(let id): "review-choice-alternative-\(id)"
        }
    }
}

// MARK: - Copy

private extension RecordingRouteReviewControls {
    private static let alphabetCount = 26
    private static let uppercaseAScalar = 65

    func prompt(for section: RouteReviewSection) -> String {
        switch section.kind {
        case .snapped:
            return "The highlighted section was moved onto a mapped trail."
        case .ambiguous:
            return Self.unobservedPrefix(section)
                + "The highlighted section has more than one plausible route."
        case .gap:
            return Self.unobservedPrefix(section) + (
                section.isBridged
                    ? "The highlighted line follows a mapped trail across the gap."
                    : "No mapped route fits the gap, so the line is drawn straight across it."
            )
        }
    }

    /// Leads with the fact the hiker has no other way of learning: that the
    /// recording stopped producing fixes here, and for how long. Everything
    /// after it is about what the app did with that.
    static func unobservedPrefix(_ section: RouteReviewSection) -> String {
        guard let duration = section.unobservedDuration else { return "" }
        return "No position was recorded for \(HikeFormat.duration(duration)). "
    }

    func title(
        for choice: TrailRouteChoice,
        in section: RouteReviewSection
    ) -> String {
        switch choice {
        case .matched: section.trailName.map { "Use \($0)" } ?? "Use the mapped trail"
        case .gps: section.kind == .gap ? "Draw a straight line" : "Use GPS only"
        case .alternative(let alternativeID): "Option \(Self.optionLabel(alternativeID))"
        }
    }

    func subtitle(
        for choice: TrailRouteChoice,
        in section: RouteReviewSection
    ) -> String {
        switch choice {
        case .matched: "Snapped to the trail · " + Self.formatted(section.matchedDistanceMeters)
        case .gps: (
            section.kind == .gap
                ? "Straight across the gap · "
                : "Keep the recorded line · "
        ) + Self.formatted(section.rawDistanceMeters)
        case .alternative(let alternativeID): section.alternatives
            .first { $0.id == alternativeID }
            .map(Self.alternativeSubtitle) ?? ""
        }
    }

    static func optionLabel(_ index: Int) -> String {
        guard index >= 0, index < alphabetCount,
              let scalar = UnicodeScalar(uppercaseAScalar + index) else { return "\(index + 1)" }
        return String(Character(scalar))
    }

    static func alternativeSubtitle(
        _ alternative: TrailMatchAlternative
    ) -> String {
        let names = alternative.trailNames.isEmpty
            ? "Unnamed trail"
            : alternative.trailNames.joined(separator: ", ")
        return "\(names) · \(formatted(alternative.distanceMeters))"
    }

    static func formatted(_ meters: Double) -> String {
        Measurement(
            value: meters,
            unit: UnitLength.meters
        ).formatted(.measurement(width: .abbreviated, usage: .road))
    }
}
