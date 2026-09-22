//
//  MapAnnotationKeyCodingTests.swift
//  OpenHikesTests
//
//  Every annotation this app puts on a map answers to `title` and `subtitle`.
//
//  `MKAnnotation` makes both optional to Swift and neither optional to
//  Objective-C, where they are keys MapKit reads with `valueForKey:` while it
//  is laying a marker's label out. An annotation class that simply leaves one
//  out compiles, draws, and then takes the process down with
//  `valueForUndefinedKey:` — but only once there is a second pin on the map to
//  make MapKit measure labels at all, which is why it is not a crash the
//  feature's own tests find. ``TrailDraftDroppedPin`` reached a hiker that way.
//
//  So the claim is made once, for every class at once, and by class rather
//  than by instance: none of these needs to exist for the question to have an
//  answer, and building seven fixtures to ask it would be seven reasons for
//  this file to go stale.
//

import Foundation
import MapKit
@testable import OpenHikes
import Testing

/// The two keys MapKit reads off an annotation, on every annotation this app
/// defines.
@Suite("Map annotation key coding")
struct MapAnnotationKeyCodingTests {
    /// Every `MKAnnotation` in the app. A new one belongs here; the list is
    /// short because the map's pins are, and a missing entry is a class this
    /// suite cannot speak for.
    private static let annotationClasses: [(name: String, type: NSObject.Type)] = [
        ("TrailDraftDroppedPin", TrailDraftDroppedPin.self),
        ("TrailDraftWaypointAnnotation", TrailDraftWaypointAnnotation.self),
        ("TrailPlaceAnnotation", TrailPlaceAnnotation.self),
        ("TrailPointCandidateAnnotation", TrailPointCandidateAnnotation.self),
        ("CommunityMapAnnotation", CommunityMapAnnotation.self),
        ("CommunityPhotoMapAnnotation", CommunityPhotoMapAnnotation.self),
        ("PhotoMapAnnotation", PhotoMapAnnotation.self),
    ]

    @Test("every annotation answers to title")
    func everyAnnotationAnswersToTitle() {
        for annotation in Self.annotationClasses {
            #expect(
                annotation.type.instancesRespond(to: NSSelectorFromString("title")),
                "\(annotation.name) is not key value coding-compliant for title"
            )
        }
    }

    /// The one that crashed. A pin with nothing to say under its heading says
    /// it with `nil`, not by leaving the key undeclared.
    @Test("every annotation answers to subtitle")
    func everyAnnotationAnswersToSubtitle() {
        for annotation in Self.annotationClasses {
            #expect(
                annotation.type.instancesRespond(to: NSSelectorFromString("subtitle")),
                "\(annotation.name) is not key value coding-compliant for subtitle"
            )
        }
    }
}
