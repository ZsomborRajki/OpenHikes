//
//  HikeRecordingControl.swift
//  OpenWidget
//
//  Starts or stops a hike without unlocking the phone.
//

import OpenHikesShared
import SwiftUI
import WidgetKit

enum HikeRecordingControlState: Equatable {
    case idle
    case recording

    init(snapshot: SharedRecordingSnapshot?) {
        self = snapshot == nil ? .idle : .recording
    }

    var title: LocalizedStringResource {
        switch self {
        case .idle: "Start Hike"
        case .recording: "Stop Hike"
        }
    }

    var systemImage: String {
        switch self {
        case .idle: "figure.hiking"
        case .recording: "stop.fill"
        }
    }
}

struct HikeRecordingControlValueProvider: ControlValueProvider {
    let previewValue = HikeRecordingControlState.idle

    func currentValue() async -> HikeRecordingControlState { // swiftlint:disable:this async_without_await
        HikeRecordingControlState(snapshot: SharedStore.loadRecording())
    }
}

struct HikeRecordingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: HikeRecordingControlKind.id,
            provider: HikeRecordingControlValueProvider()
        ) { state in
            ControlWidgetButton(action: ToggleHikeRecordingIntent()) {
                Label(state.title, systemImage: state.systemImage)
            }
            .tint(state == .recording ? .red : .green)
        }
        .displayName("Hike Recording")
        .description("Start or stop recording a hike.")
    }
}
