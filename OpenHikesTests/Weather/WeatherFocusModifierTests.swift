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
        let window = try host(FocusProbe(focus: focus, recording: recording, counter: BodyCounter()))
        defer { dismiss(window) }

        await settleDelegateHop(until: "the weather modifier appeared") { recording.appeared }
        recording.isActive = true
        await settleDelegateHop(until: "the recording owns weather") { focus.isPinnedToHiker }

        let coordinate = CLLocationCoordinate2D(latitude: 48.2, longitude: 16.4)
        focus.focus(on: .place(coordinate, name: "Vienna"))
        #expect(focus.subject == nil)
        focus.hikerMoved(to: coordinate)
        #expect(focus.subject == .me(coordinate))

        recording.isActive = false
        await settleDelegateHop(until: "the recording released weather") { !focus.isPinnedToHiker }
        focus.focus(on: .place(coordinate, name: "Vienna"))
        #expect(focus.subject == .place(coordinate, name: "Vienna"))
    }

    /// The root view applies this modifier, and the recorder's `isActive`
    /// reads its phase, which moves at every pause and at every stop
    /// Auto-Pause calls. Read by the modifier's own body, a change re-runs the
    /// modifier and leaves the view that applied it alone. Watched failing
    /// with the read moved back into the probe's body: two passes, one per
    /// write.
    @Test("a recording starting or stopping re-runs the modifier, not the view that applies it")
    func recordingChangesStayInTheModifier() async throws {
        let focus = WeatherFocus()
        let recording = RecordingState(isActive: false)
        let counter = BodyCounter()
        let window = try host(FocusProbe(focus: focus, recording: recording, counter: counter))
        defer { dismiss(window) }
        await settleDelegateHop(until: "the weather modifier appeared") { recording.appeared }
        let before = counter.count

        recording.isActive = true
        await settleDelegateHop(until: "the recording owns weather") { focus.isPinnedToHiker }
        recording.isActive = false
        await settleDelegateHop(until: "the recording released weather") { !focus.isPinnedToHiker }

        #expect(before > 0, "precondition: the probe rendered at all")
        #expect(counter.count == before, "the view applying the modifier reads no recording")
    }

    private func host(_ probe: FocusProbe) throws -> UIWindow {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: probe)
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }

    private func dismiss(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
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
    let counter: BodyCounter

    var body: some View {
        counter.record()
        return Text(verbatim: "Weather focus")
            .weatherFocus(focus, trail: nil, isRecording: { recording.isActive }, hiker: { nil })
            .onAppear { recording.appeared = true }
    }
}
