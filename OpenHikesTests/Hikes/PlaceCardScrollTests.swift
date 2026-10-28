//
//  PlaceCardScrollTests.swift
//  OpenHikesTests
//
//  Exercise a real hosted scroll view: a short detent must not freeze the
//  actions above the viewport, and selecting another card starts at its top.
//

import Observation
@testable import OpenHikes
import SwiftUI
import Testing
import UIKit

@Observable
private final class PlaceCardScrollProbeState {
    var selection = 0
    var allowsScrolling = true
}

private struct PlaceCardScrollProbe: View {
    let state: PlaceCardScrollProbeState
    private static let contentHeight: CGFloat = 2000

    var body: some View {
        PlaceCardScroll(selection: state.selection, allowsScrolling: state.allowsScrolling) {
            VStack {
                Text(verbatim: "Title and actions")
                Color.clear.frame(height: Self.contentHeight)
            }
        }
    }
}

@MainActor
@Suite("Place card scrolling")
struct PlaceCardScrollTests {
    @Test("shrinking or changing the place restores its title", arguments: [true, false])
    func restoresTop(shrinking: Bool) async throws {
        let state = PlaceCardScrollProbeState()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 300)
        window.rootViewController = UIHostingController(rootView: PlaceCardScrollProbe(state: state))
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        await settleDelegateHop(until: "the card has a scrollable body") {
            window.layoutIfNeeded()
            return scrollView(in: window)?.contentSize.height ?? 0 > 1000
        }
        let scroll = try #require(scrollView(in: window))
        scroll.setContentOffset(CGPoint(x: 0, y: 500), animated: false)
        #expect(scroll.contentOffset.y > 400, "precondition: the title has scrolled above the viewport")

        if shrinking { state.allowsScrolling = false } else { state.selection += 1 }

        await settleDelegateHop(until: "the card returns to its title and actions") {
            window.layoutIfNeeded()
            return scroll.contentOffset.y <= 1
        }
        #expect(scroll.contentOffset.y <= 1)
        #expect(scroll.isScrollEnabled == !shrinking)
    }

    private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }
}
