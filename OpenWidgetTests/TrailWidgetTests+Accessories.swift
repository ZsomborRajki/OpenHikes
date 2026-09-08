//
//  TrailWidgetTests+Accessories.swift
//  OpenWidgetTests
//
//  What the Lock Screen families say. They draw a glyph, a progress ring or a
//  single line — nothing here can check pixels, and every one of those three
//  is decoration hidden from VoiceOver — so the thing worth pinning is
//  `TrailWidgetAccessorySubject`, which is where the label, the value and the
//  recording-outranks-trail precedence are decided.
//
//  A blank one of those is not a cosmetic problem: it is a Lock Screen widget
//  that reads as nothing at all.
//
//  An extension rather than more of `TrailWidgetTests` for the same reason
//  `TrailWidgetTests+Recording.swift` is one — the suite had reached its
//  body-length limit. `init()` there still resets the App Group before every
//  test below.
//

import Foundation
import OpenHikesShared
import Testing
import WidgetKit

extension TrailWidgetTests {
    /// The Lock Screen families draw a glyph, a ring or one line of text —
    /// all of which are hidden from VoiceOver — so what a reader actually
    /// gets is the label and value ``TrailWidgetAccessorySubject`` supplies.
    /// A blank one is a Lock Screen widget that says nothing at all.
    @Test("every accessory state speaks a name and a status")
    func accessorySubjectAlwaysSpeaks() {
        let subjects: [TrailWidgetAccessorySubject] = [
            .trail(Self.snapshot()),
            .recording(Self.recordingSnapshot()),
            .recording(Self.recordingSnapshot(isCapturingFixes: false)),
            .empty,
        ]

        for subject in subjects {
            #expect(!subject.title.isEmpty, "\(subject)")
            #expect(!subject.status.isEmpty, "\(subject)")
        }
    }

    /// The same rule `TrailWidgetEntry.init`, `HikeLiveActivityController` and
    /// `HikeRecordingControlState` apply: a live recording takes the surface,
    /// paused or not. The initializer already clears the trail, so this pins
    /// both halves — the entry drops it, and the accessory asks in an order
    /// that would still be right if it ever stopped.
    @Test("a recording outranks the trail on the Lock Screen too")
    func accessorySubjectPrefersARecording() {
        let recording = Self.recordingSnapshot(isCapturingFixes: false)
        let entry = TrailWidgetEntry(
            date: .now,
            snapshot: Self.snapshot(title: "Ridge Loop"),
            recordingSnapshot: recording
        )

        #expect(entry.snapshot == nil, "the entry clears the trail")
        #expect(TrailWidgetAccessorySubject(entry: entry) == .recording(recording))
        #expect(TrailWidgetAccessorySubject(entry: entry).title == recording.title)
    }

    /// The name leads and the status follows, matching the system families —
    /// a reader moving a widget between the Home and Lock Screens hears the
    /// same two facts in the same order.
    @Test("an accessory speaks the trail's name then its status")
    func accessorySubjectSpeaksTheTrail() {
        let stored = Self.snapshot(title: "Ridge Loop")
        let entry = TrailWidgetEntry(date: .now, snapshot: stored)
        let subject = TrailWidgetAccessorySubject(entry: entry)

        #expect(subject == .trail(stored))
        #expect(subject.title == stored.title)
        #expect(subject.status == stored.statusText)
    }

    /// Nothing selected is a state the Lock Screen can sit in for days, so it
    /// has to say what to do about it rather than read as a broken widget.
    @Test("an empty accessory says what to do about it")
    func accessorySubjectSaysWhatToDo() {
        let subject = TrailWidgetAccessorySubject(entry: TrailWidgetEntry(date: .now, snapshot: nil))

        #expect(subject == .empty)
        #expect(subject.status.localizedCaseInsensitiveContains("trail"))
    }
}
