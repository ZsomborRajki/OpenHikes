//
//  RouteChecksCard.swift
//  OpenHikes
//
//  The stretches of a recording the hiker can still answer for, on *Edit
//  Route*: where trail matching moved the line onto a mapped trail, found
//  more than one route it could have been, or bridged ground nothing was
//  recorded across.
//
//  These used to be asked one at a time before a recording was saved at all,
//  on the recording's own screen. The recording is saved first now, with each
//  stretch drawn the way that needs no answer, and this is where the answer
//  can be changed: any time, on any device — see ``RouteAssembly``. The
//  wording is that review's own.
//
//  Its own views for the reason everything on this screen is: a stretch's
//  answer is read here and in the map, never by the screen's body.
//

import OpenHikesData
import SwiftUI

struct RouteChecksCard: View {
    let session: RouteTrimSession
    /// Brings a stretch into view on the map above the sheet.
    let onShow: (Int) -> Void

    var body: some View {
        let checks = session.checks
        if !checks.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Sections to Check")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                ForEach(checks) { check in
                    RouteCheckRow(check: check, session: session, onShow: onShow)
                }
            }
        }
    }
}

/// *Looks Good*: the line is right as it is, so the hike stops asking. There
/// only while the hike asks and nothing has been changed, because Save says
/// the same of a line that has.
struct RouteLooksGoodButton: View {
    let session: RouteTrimSession
    let confirm: () -> Void

    var body: some View {
        if session.isOwedALook, !session.hasChanges {
            Button("Looks Good", systemImage: "checkmark", action: confirm)
                .sectionActionButtonStyle()
                .disabled(session.isSaving)
                .accessibilityIdentifier("route-checks-confirm")
        }
    }
}

/// One stretch: what happened there, and each way of drawing it.
struct RouteCheckRow: View {
    let check: RouteCheck
    let session: RouteTrimSession
    let onShow: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                session.focus(onCheck: check.id)
                onShow(check.id)
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    Text(RouteCheckWording.prompt(for: check))
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Image(systemName: "mappin.and.ellipse")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the section on the map")
            .accessibilityIdentifier("route-check-show")
            ForEach(check.availableChoices, id: \.self) { choice in
                choiceButton(choice)
            }
        }
        .padding(.vertical, StatCardMetrics.listPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .placeCardGroup()
    }

    private func choiceButton(_ choice: RouteCheck.Choice) -> some View {
        let isChosen = check.choice == choice
        return Button {
            Task { await session.choose(choice, forCheck: check.id) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isChosen ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(RouteCheckWording.title(for: choice, in: check))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(RouteCheckWording.subtitle(
                        for: choice,
                        in: check,
                        meters: session.choiceMeters[check.id]?[choice] ?? 0
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .frame(minHeight: StatCardMetrics.rowMinimumHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(session.isSaving)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
        .accessibilityIdentifier(RouteCheckWording.identifier(for: choice))
    }
}
