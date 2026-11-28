//
//  LibraryTotalsView.swift
//  OpenHikes
//
//  *Totals*: how far the hiker has walked this year, against last year, and
//  in all — see ``LibraryTotals`` for what counts and why.
//
//  The sums are worked out when the screen opens, off the main actor, and not
//  kept: a library changes by a hike at a time and re-summing one on open is
//  cheaper than keeping a second copy of every figure in step with it.
//
//  A library that could not be read says so, with *Try Again*, rather than
//  showing the zeroes an empty one would: nothing is summed from half a read.
//  A library in which nothing counts yet says what would.
//
//  The screen is drawn the way Apple draws a year of activity, in Health and
//  in Fitness: cards, each a measurement with its figure in rounded numerals
//  — see `TotalsCard.swift` for the pieces, ``TotalsDistanceCard`` for the
//  year's distance and its months, ``TotalsYearTiles`` for the year's other
//  figures and `TotalsRowCards.swift` for everything walked and the records.
//

import OpenHikesData
import os
import SwiftData
import SwiftUI

struct LibraryTotalsView: View {
    private static let logger = Logger(subsystem: "OpenHikes", category: "LibraryTotals")
    /// Above whatever stands in the figures' place: the wait, a failed read
    /// or an empty library.
    private static let noticeTopPadding: CGFloat = 40

    /// Opens one of the records, the way a row of the library does.
    var onOpenHike: (Hike) -> Void = { _ in /* no-op default */ }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @State private var totals: LibraryTotals?
    @State private var couldNotRead = false
    /// Bumped by *Try Again*, which re-runs the sum.
    @State private var attempt = 0

    private struct SumRequest: Hashable {
        let attempt: Int
        let calendar: Calendar

        init(attempt: Int, calendar: Calendar, timeZone: TimeZone) {
            self.attempt = attempt
            var calendar = calendar
            calendar.timeZone = timeZone
            self.calendar = calendar
        }
    }

    var body: some View {
        let request = SumRequest(attempt: attempt, calendar: calendar, timeZone: timeZone)
        ScrollView {
            if let totals, totals.allTime.outings > 0 {
                LibraryTotalsContent(totals: totals, onOpenHike: open)
                    .padding()
            } else if totals != nil {
                LibraryTotalsEmpty()
                    .padding(.top, Self.noticeTopPadding)
            } else if couldNotRead {
                ContentUnavailableView {
                    Label("Couldn’t Add Up Your Hikes", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Your library couldn’t be read just now.")
                } actions: {
                    Button("Try Again") { attempt += 1 }
                        .glassButtonStyle()
                        .accessibilityIdentifier("library-totals-retry")
                }
                .padding(.top, Self.noticeTopPadding)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, Self.noticeTopPadding)
            }
        }
        // What the side panel stands as tall as — see ``SidePanelFit``.
        .fitsSidePanel()
        .navigationTitle("Totals")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: request) { await sum(in: request.calendar) }
    }

    /// Replaces the figures with a fresh sum, or with the failure: figures
    /// from an earlier read are not left up as if they were this one's.
    private func sum(in calendar: Calendar) async {
        couldNotRead = false
        let date = Date.now
        do {
            let sum = try await LibraryTotalsSweep.totals(
                from: modelContext.container,
                asOf: date,
                calendar: calendar
            )
            try Task.checkCancellation()
            totals = sum
        } catch {
            guard !Task.isCancelled else { return }
            Self.logger.error(
                "The library could not be read for its totals: \(error.localizedDescription, privacy: .public)"
            )
            totals = nil
            couldNotRead = true
        }
    }

    /// The record's hike, fetched here where the context is, or nothing for
    /// one deleted since the figures were summed.
    private func open(_ hikeID: UUID) {
        let descriptor = FetchDescriptor<Hike>(predicate: #Predicate { $0.id == hikeID })
        guard let hike = try? modelContext.fetch(descriptor).first else { return }
        onOpenHike(hike)
    }
}

/// The figures, once there are some. Its own view so the loading state above
/// is the only thing the screen's own body decides.
///
/// The year first: its distance over the months, then its other four
/// measurements a tile each. Everything walked in all and the records
/// follow, and what counts is said at the foot.
private struct LibraryTotalsContent: View {
    private static let footnoteSpacing: CGFloat = 8

    let totals: LibraryTotals
    let onOpenHike: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: TotalsMetrics.sectionSpacing) {
            section(Text(verbatim: String(totals.year)), isProminent: true) {
                TotalsDistanceCard(totals: totals)
                TotalsYearTiles(totals: totals)
            }
            section(Text("All Time")) {
                TotalsAllTimeCard(figures: totals.allTime)
            }
            if totals.longest != nil {
                section(Text("Records")) {
                    TotalsRecordsCard(totals: totals, onOpenHike: onOpenHike)
                }
            }
            VStack(alignment: .leading, spacing: Self.footnoteSpacing) {
                LibraryTotalsCountingNote()
                if totals.allTime.outingsWithoutClimb > 0 {
                    Text("""
                    Climb, Highest and Steepest leave out activities along trails \
                    that have changed since you hiked them.
                    """)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private func section(
        _ title: Text,
        isProminent: Bool = false,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: TotalsMetrics.cardSpacing) {
            TotalsSectionHeading(title: title, isProminent: isProminent)
            content()
        }
    }
}

/// What counts as walked, in the one place it is worded: under the figures,
/// and in their place while there are none.
private struct LibraryTotalsCountingNote: View {
    var body: some View {
        Text("""
        Recordings, GPX files with times and hikes along saved trails count. \
        A trail you drew or saved counts once you hike it.
        """)
    }
}

/// A library in which nothing counts yet: what would count, where a year
/// of zeroes over an empty chart used to stand.
private struct LibraryTotalsEmpty: View {
    var body: some View {
        ContentUnavailableView {
            Label("No hikes yet", systemImage: "chart.bar.xaxis")
        } description: {
            LibraryTotalsCountingNote()
        }
    }
}
