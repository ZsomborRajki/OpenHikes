//
//  TrailDraftPhotoCopyTests+Alerts.swift
//  OpenHikesTests
//
//  The failure notice must actually present each queued trail, including a
//  retry that fails while the previous alert is being dismissed.
//

import Foundation
@testable import OpenHikes
import SwiftUI
import Testing

extension TrailDraftPhotoCopyTests {
    @Test("each trail's alert appears, and a refused retry can appear again")
    func queuedAlertsArePresented() async throws {
        let sandbox = PhotoStoreSandbox()
        let copy = TrailDraftPhotoCopy(
            store: sandbox.store,
            libraryWriter: StubPhotoLibraryWriter(),
            save: { _ in throw CocoaError(.fileWriteUnknown) }
        )
        let context = try Fixture.modelContext()
        let counter = BodyCounter()
        let host = try AlertHost(copy: copy, counter: counter)
        defer { host.dismiss() }
        await host.settle(until: "the alert host rendered") { counter.count > 0 }
        let before = counter.count

        await copy.attach(try Self.handOff(of: 1), to: Fixture.hike(in: context, title: "First")).value
        await host.settle(until: "the first trail's alert appeared") {
            host.message?.contains("First") == true
        }
        let firstAlert = host.alert
        await copy.attach(try Self.handOff(of: 1), to: Fixture.hike(in: context, title: "Second")).value
        #expect(host.alert === firstAlert, "a later failure must not replace an unanswered alert")

        copy.skip()
        await host.settle(until: "the second trail's alert appeared") {
            host.alert !== firstAlert && host.message?.contains("Second") == true
        }
        let secondAlert = host.alert

        await copy.retry()?.value
        await host.settle(until: "the refused retry's alert appeared again") {
            host.alert !== secondAlert && host.message?.contains("Second") == true
        }
        copy.skip()
        await host.settle(until: "the last alert closed") { host.alert == nil }
        #expect(counter.count == before, "photo failures must not rebuild the enclosing screen")
    }
}

private struct AlertProbe: View {
    let copy: TrailDraftPhotoCopy
    let counter: BodyCounter

    var body: some View {
        counter.record()
        return Text(verbatim: "Saved trail").trailDraftPhotoCopyAlert(copy)
    }
}

@MainActor
private struct AlertHost {
    private static let width: CGFloat = 390
    private static let height: CGFloat = 844
    let window: UIWindow
    let root: UIViewController

    init(copy: TrailDraftPhotoCopy, counter: BodyCounter) throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: Self.width, height: Self.height)
        root = UIHostingController(rootView: AlertProbe(copy: copy, counter: counter))
        window.rootViewController = root
        window.isHidden = false
        window.layoutIfNeeded()
    }

    var alert: UIAlertController? { root.presentedViewController as? UIAlertController }
    var message: String? { alert?.message }

    func settle(until description: Comment, condition: @escaping @MainActor () -> Bool) async {
        await settleDelegateHop(until: description) {
            root.view.setNeedsLayout()
            window.layoutIfNeeded()
            return condition()
        }
    }

    func dismiss() {
        root.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
    }
}
