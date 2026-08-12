//
//  SheetRoute.swift
//  OpenTrails
//

enum SheetRoute: Hashable {
    case hike(Hike)
    case recording

    static func reopenRecording(in path: inout [SheetRoute]) {
        if let recordingIndex = path.lastIndex(of: .recording) {
            let following = path.index(after: recordingIndex)
            if following < path.endIndex {
                path.removeSubrange(following..<path.endIndex)
            }
        } else {
            path.append(.recording)
        }
    }
}
