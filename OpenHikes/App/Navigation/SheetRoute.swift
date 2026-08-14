//
//  SheetRoute.swift
//  OpenHikes
//

enum SheetRoute: Hashable {
    case hike(Hike)
    case recording

    static func reopenRecording(in path: inout [Self]) {
        path = [.recording]
    }

    static func openRecording(
        hike: Hike?,
        selectedHike: inout Hike?,
        in path: inout [Self]
    ) {
        if let hike {
            selectedHike = hike
        }
        reopenRecording(in: &path)
    }
}
