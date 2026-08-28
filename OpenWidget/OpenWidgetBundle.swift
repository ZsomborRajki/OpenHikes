//
//  OpenWidgetBundle.swift
//  OpenWidget
//
//  Created by Zsombor Rajki on 2026. 08. 10..
//

import SwiftUI
import WidgetKit

@main
struct OpenWidgetBundle: WidgetBundle {
    var body: some Widget {
        TrailWidget()
        // A Live Activity is declared in the widget bundle like any other
        // widget, but the system only ever shows one the app has explicitly
        // requested — see `HikeLiveActivityController` in the app target.
        HikeLiveActivity()
    }
}
