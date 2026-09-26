//
//  GPXTrackChoice.swift
//  OpenHikes
//
//  Which tracks of a multi-track file become hikes.
//
//  A file with several `<trk>`s used to be refused with "split the file", the
//  one thing an iPhone has no tool for. Each track is its own hike, so each
//  becomes one — after a short confirmation that lists them by name, length
//  and date, all ticked. It is asked rather than done silently because a
//  region's download of forty walks is not forty hikes anybody wanted in
//  their library, and because the hiker can see from the list what the file
//  actually holds before any of it lands.
//
//  The import awaits the answer: ``ask(fileName:tracks:unplacedWaypoints:)``
//  suspends until the sheet's Import or Cancel resumes it, so the import path
//  reads top to bottom rather than being split across a callback. A second
//  question arriving while one is up waits its turn rather than replacing
//  it: two files opened together from AirDrop or Files import concurrently,
//  and an answer of "none" is what deletes an inbox copy (see
//  ``HikeImportOutcome/discardsSourceCopy``), so ending the first question
//  on the second's arrival would throw away a file the hiker never saw.
//

import DequeModule
import Foundation
import Observation
import OpenHikesData
import SwiftUI

/// One track of the file, as the list shows it.
struct GPXTrackOption: Identifiable, Equatable {
    /// The track's place in the file, which is what the import is answered in.
    let id: Int
    let title: String
    let distanceMeters: Double
    let date: Date?
    var isChosen = true
}

@MainActor
@Observable
final class GPXTrackChoice {
    /// What is on screen, or `nil` for nothing.
    struct Question: Identifiable, Equatable {
        let id = UUID()
        let fileName: String
        var options: [GPXTrackOption]
        /// How many of the file's waypoints lie on none of its tracks and
        /// will not come with any of them — see ``GPXTrackSplit``.
        let unplacedWaypoints: Int

        var chosenCount: Int { options.count(where: \.isChosen) }
    }

    private(set) var question: Question?
    @ObservationIgnored private var answer: CheckedContinuation<[Int], Never>?
    /// Whether a caller holds the turn — from the moment it asks until the
    /// hiker answers. Separate from ``question`` because the turn is handed
    /// straight to the next in ``waiting``, and a question is `nil` for the
    /// moment in between; a newcomer that saw only that would jump the queue.
    @ObservationIgnored private var isAsking = false
    /// The callers queued behind the one on screen, first come first asked —
    /// a `Deque` so handing the turn to the front doesn't shift the rest, the
    /// waiter queue ``TileLoadGate`` keeps too.
    @ObservationIgnored private var waiting: Deque<CheckedContinuation<Void, Never>> = []

    /// How many questions are queued behind the one on screen — for the suite,
    /// which has no other way to know a concurrent ask has reached the queue.
    var waitingCount: Int { waiting.count }

    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    /// Puts the tracks up and waits for the hiker: the indices to import, or
    /// empty for none. Behind any question already up, which keeps the turn
    /// until it is answered.
    func ask(fileName: String, tracks: [GPXImport.Track], unplacedWaypoints: Int) async -> [Int] {
        if isAsking {
            // Resumed by ``answer(with:)`` with the turn already handed over.
            await withCheckedContinuation { waiting.append($0) }
        } else {
            isAsking = true
        }
        let options = tracks.enumerated().map { index, track in
            GPXTrackOption(
                id: index,
                title: HikeTitle.bounded(track.name) ?? "Track \(index + 1)",
                distanceMeters: track.distanceMeters,
                date: track.startTime
            )
        }
        return await withCheckedContinuation { continuation in
            answer = continuation
            question = Question(fileName: fileName, options: options, unplacedWaypoints: unplacedWaypoints)
        }
    }

    func toggle(_ id: Int) {
        guard let index = question?.options.firstIndex(where: { $0.id == id }) else { return }
        question?.options[index].isChosen.toggle()
    }

    /// Import. What is ticked is the answer.
    func confirm() {
        answer(with: question?.options.filter(\.isChosen).map(\.id) ?? [])
    }

    /// Cancel, or the sheet swiped away: none of them.
    func cancel() {
        answer(with: [])
    }

    /// Answers the question on screen and passes the turn on. Nothing to do
    /// with none up — a sheet's dismissal writing `nil` back after Import is
    /// not a second answer, and must not hand the turn on twice.
    private func answer(with chosen: [Int]) {
        guard let pending = answer else { return }
        question = nil
        answer = nil
        pending.resume(returning: chosen)
        if waiting.isEmpty {
            isAsking = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}

extension View {
    /// Presents the track list whenever `choice` has a question — from the
    /// sheet's contents, for the reason every modal on the map screen is
    /// presented from there. See *Present modals from inside the sheet's
    /// contents* in the repository instructions.
    func gpxTrackChoice(_ choice: GPXTrackChoice) -> some View {
        modifier(GPXTrackChoicePresenter(choice: choice))
    }
}

/// A modifier rather than a `.sheet` written at the call site, because a
/// modifier is a render boundary: the question is read here and nowhere above.
private struct GPXTrackChoicePresenter: ViewModifier {
    let choice: GPXTrackChoice

    func body(content: Content) -> some View {
        content.sheet(
            item: Binding(
                get: { choice.question },
                set: { if $0 == nil { choice.cancel() } }
            )
        ) { _ in
            GPXTrackChoiceSheet(choice: choice)
        }
    }
}

struct GPXTrackChoiceSheet: View {
    let choice: GPXTrackChoice

    var body: some View {
        NavigationStack {
            List {
                if let question = choice.question {
                    Section {
                        ForEach(question.options) { option in
                            GPXTrackOptionRow(option: option) { choice.toggle(option.id) }
                        }
                    } header: {
                        Text("Each track becomes a hike of its own.")
                    } footer: {
                        if question.unplacedWaypoints > 0 {
                            Text(Self.unplacedNote(question.unplacedWaypoints))
                        }
                    }
                }
            }
            .navigationTitle(choice.question?.fileName ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { choice.cancel() }
                        .accessibilityIdentifier("gpx-track-choice-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(Self.importTitle(choice.question?.chosenCount ?? 0)) { choice.confirm() }
                        .disabled((choice.question?.chosenCount ?? 0) == 0)
                        .accessibilityIdentifier("gpx-track-choice-import")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private static func importTitle(_ count: Int) -> String {
        count == 1 ? "Import 1 Hike" : "Import \(count) Hikes"
    }

    private static func unplacedNote(_ count: Int) -> String {
        count == 1
            ? "1 waypoint lies on none of these tracks and won't be imported."
            : "\(count) waypoints lie on none of these tracks and won't be imported."
    }
}

/// One track: its name, length and date, and whether it is ticked. A row of
/// its own so a tick redraws one row, not the list.
private struct GPXTrackOptionRow: View {
    let option: GPXTrackOption
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Image(systemName: option.isChosen ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(option.isChosen ? Color.accentColor : .secondary)
                    .imageScale(.large)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(option.title)
        .accessibilityValue(detail)
        .accessibilityAddTraits(option.isChosen ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("gpx-track-\(option.id)")
    }

    private var detail: String {
        let length = Measurement(value: option.distanceMeters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
        guard let date = option.date else { return length }
        return "\(length) · \(date.formatted(date: .abbreviated, time: .omitted))"
    }
}
