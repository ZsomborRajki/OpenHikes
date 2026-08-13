//
//  SheetRoute.swift
//  OpenTrails
//

enum SheetRoute: Hashable {
    case hike(Hike)
    case recording

    static func reopenRecording(in path: inout [SheetRoute]) {
        path = [.recording]
    }

    static func openRecording(
        hike: Hike?,
        selectedHike: inout Hike?,
        in path: inout [SheetRoute]
    ) {
        if let hike {
            selectedHike = hike
        }
        reopenRecording(in: &path)
    }
}
