//
//  MapSheetPresenterTests.swift
//  OpenHikesTests
//
//  The map screen's sheet, presented by `presentsMapSheet(_:content:)` and
//  steered by the layout reader's reports, in a real window — the arrangement
//  `OpenHikesView` has, without the rest of the screen.
//
//  The bug these hold: a launch into a window that takes the side panel
//  presented the sheet too, and took it down about a second later. The sheet
//  was asked for in the first body pass, before anything had read the window,
//  and its contents — the hikes list, its `@Query`, its rows — were built for
//  nothing beside the panel's own copy. Watched on an iPad Pro 13-inch
//  simulator; the window below is that iPad's size, and the rule never sees
//  a device, only the window's width.
//

@testable import OpenHikes
import SwiftUI
import Testing

/// What the root view does with the sheet: present it, and have the window's
/// shape read beside it.
private struct PresenterProbe: View {
    let presentation: SheetPresentation
    let metrics: SheetMetrics
    let counter: BodyCounter

    var body: some View {
        Color.clear
            .presentsMapSheet(presentation) { SheetContentProbe(counter: counter) }
            .background { SheetLayoutReader(presentation: presentation, metrics: metrics) }
    }
}

/// Stands in for `MapSheet`, and counts the times the sheet builds it.
private struct SheetContentProbe: View {
    let counter: BodyCounter

    var body: some View {
        counter.record()
        return Text(verbatim: "Sheet")
    }
}

@MainActor
private struct PresenterHost {
    private static let iPadWidth: CGFloat = 1032
    private static let iPadHeight: CGFloat = 1376
    private static let phoneWidth: CGFloat = 390
    private static let phoneHeight: CGFloat = 844
    static let panelWindow = CGSize(width: iPadWidth, height: iPadHeight)
    static let phoneWindow = CGSize(width: phoneWidth, height: phoneHeight)

    let window: UIWindow
    let root: UIViewController

    init(size: CGSize, presentation: SheetPresentation, counter: BodyCounter) throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first,
            "app-hosted tests run inside the app, which has a scene"
        )
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        root = UIHostingController(
            rootView: PresenterProbe(presentation: presentation, metrics: SheetMetrics(), counter: counter)
        )
        window.rootViewController = root
        window.isHidden = false
        window.layoutIfNeeded()
    }

    var presentsSheet: Bool { root.presentedViewController != nil }

    func resize(to size: CGSize) {
        window.frame = CGRect(origin: .zero, size: size)
    }

    /// Lays the window out until `condition` holds: a `GeometryReader` reports
    /// nothing until something lays it out.
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

@MainActor
@Suite("Map sheet presenter")
struct MapSheetPresenterTests {
    /// The window is then narrowed to a phone's width, which must present the
    /// sheet and build its contents. That is the control that makes the zero
    /// before it mean something: the same probe, in the same window, does
    /// count a sheet that is really there.
    @Test("a launch into a panel window never presents the sheet or builds its contents")
    func panelWindowNeverPresentsTheSheet() async throws {
        let presentation = SheetPresentation()
        let counter = BodyCounter()
        let host = try PresenterHost(size: PresenterHost.panelWindow, presentation: presentation, counter: counter)
        defer { host.dismiss() }

        await host.settle(until: "the window's shape was read") { presentation.layout == .sidePanel }

        #expect(host.presentsSheet == false)
        #expect(counter.count == 0, "the sheet's contents belong to the panel in this window, built once there")

        host.resize(to: PresenterHost.phoneWindow)
        await host.settle(until: "the sheet came up in a phone-wide window") {
            host.presentsSheet && counter.count > 0
        }
    }

    @Test("a phone-wide window presents the sheet once its shape is read")
    func phoneWindowPresentsTheSheet() async throws {
        let presentation = SheetPresentation()
        let counter = BodyCounter()
        let host = try PresenterHost(size: PresenterHost.phoneWindow, presentation: presentation, counter: counter)
        defer { host.dismiss() }

        await host.settle(until: "the sheet came up") { host.presentsSheet && counter.count > 0 }

        #expect(presentation.layout == .bottomSheet)
        #expect(presentation.isSheetPresented)
    }

    /// The GPX document picker tears the sheet down as it closes, and SwiftUI
    /// writes that back through the binding. Where the window wants a sheet,
    /// the sheet is the whole of the app's surface, so it goes straight back up.
    @Test("a sheet taken down from under a phone-wide window is put back")
    func takenDownSheetComesBack() async throws {
        let presentation = SheetPresentation()
        let counter = BodyCounter()
        let host = try PresenterHost(size: PresenterHost.phoneWindow, presentation: presentation, counter: counter)
        defer { host.dismiss() }
        await host.settle(until: "the sheet came up") { host.presentsSheet }

        presentation.isSheetPresented = false

        await host.settle(until: "the sheet was put back") {
            presentation.isSheetPresented && host.presentsSheet
        }
    }
}
