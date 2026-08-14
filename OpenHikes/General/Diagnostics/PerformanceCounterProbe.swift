//
//  PerformanceCounterProbe.swift
//  OpenHikes
//
//  The one thing a headless render-budget test cannot get from the log file:
//  the tally *while the app is still running*. UI automation lives in a
//  separate process with its own container, so it cannot read what
//  ``PerformanceLog`` writes; the file is for the report afterwards, not for
//  the assertion.
//
//  So the tally is also published as the accessibility value of a one-point
//  view. That makes it readable through the same channel the tests already use
//  for `recording-point-count`, and — crucially — it is *pulled*, not pushed:
//  `accessibilityValue` is a computed override on a plain `UIView`, so
//  UIKit asks for it only when an accessibility client actually reads it.
//
//  A SwiftUI `.accessibilityValue(...)` would have been the obvious spelling
//  and is exactly wrong here: its argument is captured at body-evaluation
//  time, so the value would either go stale or have to be refreshed by
//  re-rendering — a render counter that causes renders measures itself.
//
//  Present only when the launch asked for a performance log, so an ordinary
//  run has no extra accessibility element and no extra view.
//

import SwiftUI

#if DEBUG
struct PerformanceCounterProbe: View {
    static let identifier = "performance-counters"

    var body: some View {
        #if os(iOS)
        if PerformanceLog.shared != nil {
            Representable()
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
        }
        #endif
    }
}

#if os(iOS)
private extension PerformanceCounterProbe {
    struct Representable: UIViewRepresentable {
        func makeUIView(context: Context) -> ProbeView {
            let view = ProbeView()
            view.isAccessibilityElement = true
            view.accessibilityIdentifier = PerformanceCounterProbe.identifier
            view.accessibilityLabel = "Performance counters"
            view.isUserInteractionEnabled = false
            return view
        }

        func updateUIView(_ uiView: ProbeView, context: Context) {
            // Nothing to push: the value is read out of the view, not written
            // into it. This exists so the representable has no reason to make
            // a parent body pass do work.
        }
    }

    final class ProbeView: UIView {
        override var accessibilityValue: String? {
            get { PerformanceLog.shared?.snapshotDescription }
            set { super.accessibilityValue = newValue }
        }
    }
}
#endif
#endif
