import CoreLocation
@testable import OpenHikes
import SwiftUI
import Testing

@MainActor
@Suite("Weather recording focus modifier")
struct WeatherFocusModifierTests {
    @Test("initial and newly started recordings own weather without a fix", arguments: [true, false])
    func recordingOwnsWeather(initiallyRecording: Bool) async throws {
        let focus = WeatherFocus()
        let recording = RecordingState(isActive: initiallyRecording)
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(
            rootView: FocusProbe(focus: focus, recording: recording)
        )
        window.isHidden = false
        window.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        await settleDelegateHop(until: "the weather modifier appeared") { recording.appeared }
        recording.isActive = true
        await settleDelegateHop(until: "the recording owns weather") { focus.isPinnedToWalker }

        let coordinate = CLLocationCoordinate2D(latitude: 48.2, longitude: 16.4)
        focus.focus(on: .place(coordinate, name: "Vienna"))
        #expect(focus.subject == nil)
        focus.walkerMoved(to: coordinate)
        #expect(focus.subject == .me(coordinate))

        recording.isActive = false
        await settleDelegateHop(until: "the recording released weather") { !focus.isPinnedToWalker }
        focus.focus(on: .place(coordinate, name: "Vienna"))
        #expect(focus.subject == .place(coordinate, name: "Vienna"))
    }
}

@Observable
private final class RecordingState {
    var isActive: Bool
    var appeared = false

    init(isActive: Bool) {
        self.isActive = isActive
    }
}

private struct FocusProbe: View {
    let focus: WeatherFocus
    let recording: RecordingState

    var body: some View {
        Text(verbatim: "Weather focus")
            .weatherFocus(focus, trail: nil, isRecording: recording.isActive, walker: { nil })
            .onAppear { recording.appeared = true }
    }
}
