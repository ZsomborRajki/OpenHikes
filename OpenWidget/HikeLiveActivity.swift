//
//  HikeLiveActivity.swift
//  OpenWidget
//
//  The Live Activity itself: one `ActivityConfiguration` covering both things
//  a walker can have running, because ``HikeActivityAttributes`` covers both.
//
//  The app decides when one starts, updates and ends — see
//  `HikeLiveActivityController` in the app target. Everything drawn here comes
//  from `context.state`, and nothing in this file reads the App Group store,
//  asks for a location, or knows what a route profile is. That is the same
//  division the widget keeps, and it is what lets the activity stay correct
//  while the app is suspended: the system holds the last content it was given.
//
//  There are no buttons. A `LiveActivityIntent` runs in the *app's* process,
//  so its type has to be compiled into both the app and this extension — and
//  `OpenHikes/` and `OpenWidget/` are file-system-synchronized groups
//  belonging to different targets, which leaves the shared package as the only
//  place both can see. AppIntents metadata extraction from a SwiftPM library
//  is not something this project has anywhere else, and a pause button that
//  silently does nothing is worse than no pause button: the Lock Screen and
//  Dynamic Island are tap targets that open the recording screen, where the
//  controls already are and already work.
//

import ActivityKit
import OpenHikesShared
import SwiftUI
import WidgetKit

struct HikeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HikeActivityAttributes.self) { context in
            HikeActivityLockScreenView(
                attributes: context.attributes,
                state: context.state
            )
            .padding()
            .activityBackgroundTint(nil)
            .activitySystemActionForegroundColor(
                Color(hex: context.attributes.tintHex)
            )
            // A tap opens the recording screen or the trail's detail view —
            // the same destinations the widget offers, through the same links.
            .widgetURL(context.attributes.deepLink)
        } dynamicIsland: { context in
            dynamicIsland(for: context)
        }
    }

    /// Split out of the builder above so neither closure grows past the point
    /// where it can be read, and so the four regions sit next to each other
    /// rather than nested three deep.
    private func dynamicIsland(
        for context: ActivityViewContext<HikeActivityAttributes>
    ) -> DynamicIsland {
        let presentation = context.attributes.presentation(
            for: context.state,
            metricLimit: HikeActivityLayout.expandedMetricLimit
        )
        let tint = Color(hex: context.attributes.tintHex) ?? .green
        return DynamicIsland {
            DynamicIslandExpandedRegion(.leading) {
                HikeActivityFigure(
                    value: presentation.primaryValue,
                    caption: presentation.primaryCaption
                )
            }
            DynamicIslandExpandedRegion(.trailing) {
                expandedTrailing(presentation)
            }
            DynamicIslandExpandedRegion(.bottom) {
                expandedBottom(presentation, tint: tint)
            }
        } compactLeading: {
            Image(systemName: presentation.symbolName)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
        } compactTrailing: {
            Text(presentation.primaryValue)
                .monospacedDigit()
                .foregroundStyle(tint)
                .accessibilityHidden(true)
        } minimal: {
            Image(systemName: presentation.symbolName)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
        }
        .widgetURL(context.attributes.deepLink)
        .keylineTint(tint)
    }

    /// The clock for a recording, the distance left for a follow, and nothing
    /// at all for a walker who has lost the trail — an empty region collapses,
    /// which is the right answer rather than a dash.
    @ViewBuilder
    private func expandedTrailing(
        _ presentation: HikeActivityPresentation
    ) -> some View {
        if presentation.showsElapsedTimer {
            HikeActivityElapsed(presentation: presentation)
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else if let value = presentation.secondaryValue {
            HikeActivityFigure(
                value: value,
                caption: presentation.secondaryCaption ?? "",
                alignment: .trailing
            )
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// The trail's name, whatever is wrong with the walk, the chips, and the
    /// progress hairline — everything that reads left to right rather than
    /// stacking beside the sensor housing.
    ///
    /// This is also the only region that speaks: the expanded island is read
    /// as one element, so the label and value are attached here where the
    /// whole presentation is in scope.
    private func expandedBottom(
        _ presentation: HikeActivityPresentation,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HikeActivityHeader(presentation: presentation, tint: tint)
            if let progress = presentation.progress {
                TrailWidgetProgressBar(
                    fraction: progress,
                    tint: tint,
                    onMap: false
                )
            }
            TrailWidgetMetricRow(metrics: presentation.metrics, onMap: false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(presentation.accessibilityValue)
    }
}
