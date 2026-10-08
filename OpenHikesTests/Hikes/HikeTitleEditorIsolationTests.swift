//
//  HikeTitleEditorIsolationTests.swift
//  OpenHikesTests
//
//  A rename writes `HikeDetailInteraction.titleDraft` once per keystroke, and
//  the hike detail screen draws its card inside a `ScrollViewReader` closure,
//  which SwiftUI runs as a body of its own. Whichever body makes the field's
//  binding is re-run by every keystroke, which made the whole card the field's
//  reader until the field became ``HikeTitleEditor``.
//
//  Both halves are pinned on a probe shaped like the card — a counter in the
//  closure, the field inside it — rather than reasoned about, because the
//  premise is SwiftUI's rather than this app's: the old shape is shown to
//  charge the closure, and then the editor is shown not to. Each case waits on
//  the field showing the text before it counts, so a keystroke that never
//  arrived cannot pass for one that cost nothing.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import SwiftUI
import Testing
import UIKit

/// The card's old shape: the field's binding made in the closure the card is
/// drawn in.
private struct InlineFieldProbe: View {
    let interaction: HikeDetailInteraction
    let counter: BodyCounter

    var body: some View {
        ScrollViewReader { _ in
            counter.record()
            return TextField(text: Bindable(interaction).titleDraft) { Text(verbatim: "Name") }
        }
    }
}

/// The card's shape now: the closure holds the editor, which makes the
/// binding itself.
private struct EditorProbe: View {
    let hike: Hike
    let interaction: HikeDetailInteraction
    let counter: BodyCounter

    var body: some View {
        ScrollViewReader { _ in
            counter.record()
            return HikeTitleEditor(hike: hike, interaction: interaction)
        }
    }
}

@MainActor
@Suite("Hike title editor isolation")
struct HikeTitleEditorIsolationTests {
    /// What a rename types, one keystroke at a time.
    private static let keystrokes = ["R", "Re", "Ren", "Rena"]

    private func host(_ view: some View, in container: ModelContainer) throws -> UIWindow {
        let scene = try #require(
            UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first,
            "app-hosted tests run inside the app, which has a scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: view.modelContainer(container))
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }

    private func dismiss(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    /// The text the hosted field is showing, or `nil` before there is one.
    private func fieldText(in window: UIWindow) -> String? {
        func field(in view: UIView) -> UITextField? {
            if let textField = view as? UITextField { return textField }
            return view.subviews.lazy.compactMap(field(in:)).first
        }
        window.layoutIfNeeded()
        return window.rootViewController.flatMap { field(in: $0.view) }?.text
    }

    /// Types each keystroke into the draft and waits for the field to show it.
    private func type(into interaction: HikeDetailInteraction, in window: UIWindow) async {
        for text in Self.keystrokes {
            interaction.titleDraft = text
            await settleDelegateHop(until: "the field shows \"\(text)\"") {
                fieldText(in: window) == text
            }
        }
    }

    @Test("a binding made in the card's closure re-runs it for every keystroke")
    func inlineBindingChargesTheClosure() async throws {
        let container = try Fixture.modelContainer()
        let interaction = HikeDetailInteraction()
        let counter = BodyCounter()
        let window = try host(InlineFieldProbe(interaction: interaction, counter: counter), in: container)
        defer { dismiss(window) }
        await settleDelegateHop(until: "the field is on screen") { fieldText(in: window) != nil }
        let before = counter.count
        #expect(before > 0, "precondition: the probe rendered at all")

        await type(into: interaction, in: window)

        #expect(
            counter.count >= before + Self.keystrokes.count,
            "the premise: the binding read the draft in the closure that made it"
        )
    }

    @Test("the editor keeps keystrokes out of the card's closure")
    func editorKeepsKeystrokesToItself() async throws {
        let container = try Fixture.modelContainer()
        let hike = Fixture.hike(in: container.mainContext)
        let interaction = HikeDetailInteraction()
        interaction.isEditingTitle = true
        let counter = BodyCounter()
        let window = try host(EditorProbe(hike: hike, interaction: interaction, counter: counter), in: container)
        defer { dismiss(window) }
        await settleDelegateHop(until: "the field is on screen") { fieldText(in: window) != nil }
        let before = counter.count
        #expect(before > 0, "precondition: the probe rendered at all")

        await type(into: interaction, in: window)

        #expect(counter.count == before, "a keystroke is the editor's business, not the card's")
    }
}
