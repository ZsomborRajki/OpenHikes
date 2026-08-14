//
//  RecordingRouteReviewControls.swift
//  OpenHikes
//
//  The screen a finished recording has to pass through before it becomes a
//  `Hike`: one section at a time, the hiker keeps the trail the matcher found
//  or hands the section back to the GPS that recorded it.
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
    private let choiceOpacity: Double = 0.08

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
            .accessibilityIdentifier("review-section-title")

            Text(prompt(for: section))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ForEach(
                Array(section.availableChoices.enumerated()),
                id: \.offset
            ) { _, choice in
                choiceButton(choice, in: section)
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
            .disabled(!review.canMoveBackward)
            .accessibilityIdentifier("review-previous-section")
            Spacer()
            Button("Next") {
                recorder.moveToNextReviewSection()
            }
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
        .buttonStyle(.borderedProminent)
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
        .background(
            .secondary.opacity(choiceOpacity),
            in: RoundedRectangle(cornerRadius: choiceRadius)
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
            "The highlighted section was moved onto a mapped trail."

        case .ambiguous:
            "The highlighted section has more than one plausible route."
        }
    }

    func title(
        for choice: TrailRouteChoice,
        in section: RouteReviewSection
    ) -> String {
        switch choice {
        case .matched:
            section.trailName.map { "Use \($0)" } ?? "Use the mapped trail"

        case .gps:
            "Use GPS only"

        case .alternative(let alternativeID):
            "Option \(Self.optionLabel(alternativeID))"
        }
    }

    func subtitle(
        for choice: TrailRouteChoice,
        in section: RouteReviewSection
    ) -> String {
        switch choice {
        case .matched:
            "Snapped to the trail · "
                + Self.formatted(section.matchedDistanceMeters)

        case .gps:
            "Keep the recorded line · "
                + Self.formatted(section.rawDistanceMeters)

        case .alternative(let alternativeID):
            section.alternatives
                .first { $0.id == alternativeID }
                .map(Self.alternativeSubtitle) ?? ""
        }
    }

    static func optionLabel(_ index: Int) -> String {
        guard index >= 0, index < alphabetCount,
              let scalar = UnicodeScalar(uppercaseAScalar + index) else {
            return "\(index + 1)"
        }
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
