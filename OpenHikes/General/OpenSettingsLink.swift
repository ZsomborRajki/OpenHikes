//
//  OpenSettingsLink.swift
//  OpenHikes
//
//  The way back into Settings after a permission was turned off.
//
//  Four screens offer it — location refused, the camera refused, the photo
//  library refused, and a recording that failed for want of location — and
//  each wrote the URL, the unwrap, the label and the platform guard out for
//  itself. One of them spelled it as a button that opened the URL by hand,
//  which is the one spelling the others had argued against.
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

enum OpenSettingsLink {
    /// *Open Settings*, or nothing at all where there is no Settings app to
    /// open.
    ///
    /// A `Link` rather than a `Button`: an alert button that runs
    /// `UIApplication.open` dismisses first and leaves without a trace if the
    /// URL fails, while a `Link` is inert when there is nowhere to go. That is
    /// what the recording's failure alert used to do, and why it no longer
    /// does.
    ///
    /// A `@ViewBuilder` property rather than a `View` of its own, so an alert's
    /// actions see exactly the `Link` they were given before: an alert builds
    /// its buttons from the views it is handed, and this keeps that structure
    /// the same wherever it is used.
    @ViewBuilder static var link: some View {
        #if os(iOS)
        if let settings = URL(string: UIApplication.openSettingsURLString) {
            Link("Open Settings", destination: settings)
        }
        #endif
    }
}
