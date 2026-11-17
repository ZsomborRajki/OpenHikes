//
//  AutoPauseEvidence.swift
//  OpenHikesShared
//
//  What a recording was shown, written down so that ``AutoPauseWatch`` can be
//  shown it again (#1470).
//
//  The recording's journal keeps the fixes that joined the track and nothing
//  else, so no recording says what the inside of a shop looked like to Core
//  Location: the fixes too loose to keep, the ones that never came, and what
//  the motion sensors made of it. The radius and the minutes in
//  ``AutoPausePolicy`` are a first guess until some real stops have been
//  looked at. A `DEBUG` build of the app writes one line here for every fix
//  it is delivered and every change of motion, and ``replay(_:policy:)`` runs
//  a candidate policy over them, timer included, so a threshold is chosen
//  from walks that happened and held to them by a test.
//
//  Lines of text, one record each, because the file is read by a person
//  first: comma-separated, times as seconds since 1970, an absent figure left
//  empty.
//

import Foundation

public enum AutoPauseEvidence {
    public enum Record: Sendable, Equatable {
        /// A fix as it was delivered, and whether the recorder kept it for
        /// the track.
        case fix(AutoPauseWatch.Fix, kept: Bool)
        /// The motion sensors' answer changed.
        case motion(AutoPauseWatch.Motion, at: Date)

        var date: Date {
            switch self {
            case let .fix(fix, _): fix.timestamp
            case let .motion(_, date): date
            }
        }
    }

    /// What the watch said, and when the recorder would have heard it.
    public struct Decision: Sendable, Equatable {
        public let at: Date
        public let event: AutoPauseWatch.Event
    }

    private static let fixTag = "fix"
    private static let motionTag = "motion"
    private static let fixFieldCount = 9
    private static let motionFieldCount = 3

    public static func line(for record: Record) -> String {
        switch record {
        case let .fix(fix, kept):
            [
                fixTag,
                number(fix.timestamp.timeIntervalSince1970),
                number(fix.latitude),
                number(fix.longitude),
                number(fix.horizontalAccuracy),
                fix.elevation.map(number) ?? "",
                fix.speed.map(number) ?? "",
                fix.motion.rawValue,
                kept ? "1" : "0",
            ].joined(separator: ",")
        case let .motion(motion, date):
            [motionTag, number(date.timeIntervalSince1970), motion.rawValue].joined(separator: ",")
        }
    }

    /// The record a line holds, or `nil` for one that is not a record: a
    /// blank line, a heading, a line cut short by the process ending.
    public static func record(from line: String) -> Record? {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        switch fields.first {
        case fixTag where fields.count == fixFieldCount:
            guard let time = Double(fields[1]),
                  let latitude = Double(fields[2]),
                  let longitude = Double(fields[3]),
                  let accuracy = Double(fields[4]),
                  let motion = AutoPauseWatch.Motion(rawValue: fields[7]) else { return nil }
            let fix = AutoPauseWatch.Fix(
                latitude: latitude,
                longitude: longitude,
                timestamp: Date(timeIntervalSince1970: time),
                horizontalAccuracy: accuracy,
                elevation: Double(fields[5]),
                speed: Double(fields[6]),
                motion: motion
            )
            return .fix(fix, kept: fields[8] == "1")
        case motionTag where fields.count == motionFieldCount:
            guard let time = Double(fields[1]),
                  let motion = AutoPauseWatch.Motion(rawValue: fields[2]) else { return nil }
            return .motion(motion, at: Date(timeIntervalSince1970: time))
        default:
            return nil
        }
    }

    /// Shows a watch every record in order, as the recorder shows it them
    /// live: each fix, a look at each change of motion, and the timer the
    /// recorder sets by ``AutoPauseWatch/decisionDate``.
    public static func replay(
        _ records: [Record],
        policy: AutoPausePolicy = .standard
    ) -> [Decision] {
        var watch = AutoPauseWatch(policy: policy)
        var motion = AutoPauseWatch.Motion.unknown
        var decisions: [Decision] = []
        for record in records {
            // The timer would have rung before this record arrived.
            if let due = watch.decisionDate, due <= record.date,
               let event = watch.tick(at: due, motion: motion) {
                decisions.append(Decision(at: due, event: event))
            }
            let event: AutoPauseWatch.Event?
            switch record {
            case let .fix(fix, _):
                event = watch.observe(fix)
            case let .motion(changed, date):
                motion = changed
                event = watch.tick(at: date, motion: changed)
            }
            if let event {
                decisions.append(Decision(at: record.date, event: event))
            }
        }
        return decisions
    }

    /// Every digit a `Double` has, so a replayed position is the recorded
    /// one.
    private static func number(_ value: Double) -> String {
        "\(value)"
    }
}
