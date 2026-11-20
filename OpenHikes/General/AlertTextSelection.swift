//
//  AlertTextSelection.swift
//  OpenHikes
//
//  Selects everything in an alert's text field as the alert comes up, so the
//  first key typed replaces what the field opened holding.
//
//  SwiftUI's own way to say that is the field's `selection:` binding, and an
//  alert does not hear it. Measured on iOS 27.2 with the recording's stop
//  alert: the binding held the whole of the offered name before the alert was
//  raised, the field opened with its caret at the end, and "Summit Day" typed
//  into it was added to the name (`RecordingUITests+Stop.swift` is the test
//  that failed on it). An alert's field is a `UITextField` the system builds
//  from the SwiftUI one, and the selection is not among what it copies.
//
//  So the field is asked itself. It begins editing as its alert comes up —
//  an alert's field is the first responder from the start — and says so in a
//  notification that carries it, which is the moment to select its text. The
//  wait is on that event and not on a duration, and nothing is looked for in
//  the view hierarchy.
//
//  Two things keep it to the field it is for. Every text field in the app
//  posts the same notification, so the caller says when its alert is up, and
//  a field that begins editing at any other time is left as it is. And a
//  field can begin editing more than once under one alert — the app coming
//  back to the front gives it the keyboard again — so only a field still
//  holding what it opened with is selected: a name half typed is never
//  selected to be typed over.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

extension View {
    /// Selects all of `text` in a field that begins editing holding it while
    /// `isPresented` is true: the alert this is attached beside, whose field
    /// opens with `text` in it.
    func selectsAlertText(_ text: String?, while isPresented: Bool) -> some View {
        modifier(AlertTextSelection(text: text, isPresented: isPresented))
    }
}

private struct AlertTextSelection: ViewModifier {
    let text: String?
    let isPresented: Bool

    func body(content: Content) -> some View {
        #if canImport(UIKit)
        content.onReceive(
            NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)
        ) { notification in
            guard isPresented,
                  let field = notification.object as? UITextField,
                  field.text == text else { return }
            field.selectAll(nil)
        }
        #else
        content
        #endif
    }
}
