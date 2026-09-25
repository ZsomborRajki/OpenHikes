//
//  MapAnnotationReuse.swift
//  OpenHikes
//
//  The first three lines of every annotation view this map draws.
//
//  Photo pins, community hikes and their photos, a trail's places, the maker's
//  stops, dropped pin and route-time bubbles, and the drawn route's highlight
//  dot each dequeued a view of their kind, made one when MapKit had none to
//  hand back, and pointed it at the annotation — eight copies, one of them
//  typed as a subclass. What each draws once it has the view is its own.
//

import MapKit

extension MKMapView {
    /// A recycled `View` for `annotation`, or a new one when MapKit has none
    /// under `reuseIdentifier`, pointed at `annotation` either way.
    ///
    /// The annotation is set on a recycled view as well as a new one because
    /// `dequeueReusableAnnotationView(withIdentifier:)` — unlike the variant
    /// that takes an annotation — hands back a view still pointing at whatever
    /// it last drew. A view of another class under the same identifier is not
    /// reused; a new one is made instead.
    func reusableView<View: MKAnnotationView>(
        _: View.Type,
        for annotation: any MKAnnotation,
        reuseIdentifier: String
    ) -> View {
        let view = dequeueReusableAnnotationView(withIdentifier: reuseIdentifier) as? View
            ?? View(annotation: annotation, reuseIdentifier: reuseIdentifier)
        view.annotation = annotation
        return view
    }
}
