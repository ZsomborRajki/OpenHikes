//
//  HikePhotoViewer.swift
//  OpenHikes
//
//  One photo, as large as the sheet will allow, with a way to the next and the
//  previous one.
//
//  Pushed onto the sheet's own navigation stack rather than presented as a
//  full-screen cover. A cover over a detented sheet tears the sheet down when
//  it dismisses — the same iOS behaviour `OpenHikesView` already works around
//  for the GPX importer — and pushing keeps the back gesture, the toolbar and
//  the sheet's glass instead of fighting them. The push raises the detent to
//  `.large`, so "as large as the sheet will allow" is the whole screen.
//
//  Paging is a horizontally paged `ScrollView` rather than a `TabView`, so a
//  swipe and the two buttons drive the same `scrollPosition` and cannot
//  disagree about which photo is showing.
//

import CoreLocation
import MapKit
import SwiftUI

struct HikePhotoViewer: View {
    let hike: Hike
    /// The photo the gallery strip was tapped on. Only the initial position —
    /// paging afterwards is this view's own state.
    let startID: UUID
    var highlight: RouteHighlight
    var mapController: MapController
    var store: HikePhotoStore = .shared

    @Environment(\.dismiss)
    private var dismiss

    @State private var currentID: UUID?
    @State private var didRestoreStart = false

    private var photos: [HikePhoto] { hike.orderedPhotos }

    private var currentIndex: Int? {
        guard let currentID else { return nil }
        return photos.firstIndex { $0.id == currentID }
    }

    private var current: HikePhoto? {
        currentIndex.map { photos[$0] }
    }

    var body: some View {
        // A photo is shown against black everywhere in iOS, and the strip's
        // tiles are letterboxed here rather than cropped, so the backdrop is
        // doing real work: it's what the un-filled edges of a portrait shot on
        // a landscape screen become.
        ZStack {
            Color.black.ignoresSafeArea()
            if photos.isEmpty {
                emptyState
            } else {
                pages
            }
        }
        .overlay(alignment: .bottom) { controls }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        // The backdrop is black whatever the device is set to, so the bar has
        // to be told that: without this the title renders in the light
        // scheme's label colour and is black on black.
        .toolbarColorScheme(.dark, for: .navigationBar)
        #endif
        .toolbar { toolbarContent }
        .accessibilityIdentifier("photo-viewer")
        .onAppear {
            // Assigning the scroll position before the scroll view exists is
            // ignored, so the opening photo is set on the first appearance and
            // never again — a re-entry after a delete keeps whatever the user
            // was last looking at.
            guard !didRestoreStart else { return }
            didRestoreStart = true
            currentID = photos.contains { $0.id == startID }
                ? startID
                : photos.first?.id
        }
        // A viewer with nothing left to view is a dead end; deleting the last
        // photo returns to the hike.
        .onChange(of: photos.isEmpty) { _, isEmpty in
            if isEmpty { dismiss() }
        }
    }

    // MARK: - Pages

    private var pages: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(photos) { photo in
                    HikePhotoPage(photo: photo, store: store)
                        .containerRelativeFrame(.horizontal)
                        .id(photo.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollPosition(id: $currentID)
        .ignoresSafeArea(edges: .bottom)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Photos",
            systemImage: "photo.on.rectangle.angled",
            description: Text("Photos you take on this hike appear here.")
        )
    }

    // MARK: - Controls

    /// Previous and next, merged into one pill.
    ///
    /// Disabled rather than hidden at the two ends: a control that disappears
    /// moves the one beside it, and at the end of a gallery that would shift
    /// the button the user is about to press.
    private var controls: some View {
        GlassStack(spacing: 6) {
            HStack(spacing: 6) {
                stepButton(
                    systemImage: "chevron.left",
                    label: "Previous photo",
                    identifier: "previous-photo-button",
                    offset: -1
                )
                stepButton(
                    systemImage: "chevron.right",
                    label: "Next photo",
                    identifier: "next-photo-button",
                    offset: 1
                )
            }
        }
        .padding(.bottom, 20)
        .opacity(photos.count > 1 ? 1 : 0)
        .accessibilityHidden(photos.count <= 1)
    }

    private func stepButton(
        systemImage: String,
        label: LocalizedStringKey,
        identifier: String,
        offset: Int
    ) -> some View {
        Button {
            step(by: offset)
        } label: {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .minimumTapTarget()
        }
        .glassButtonStyle()
        .buttonBorderShape(.circle)
        .disabled(destination(from: currentIndex, by: offset) == nil)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if let current, let coordinate = current.coordinate {
                Button {
                    show(coordinate)
                } label: {
                    Image(systemName: "mappin.and.ellipse")
                }
                .accessibilityLabel("Show where this photo was taken")
                .accessibilityIdentifier("photo-show-on-map-button")
            }
            if let current {
                Button(role: .destructive) {
                    delete(current)
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Delete photo")
                .accessibilityIdentifier("photo-delete-button")
            }
        }
    }

    // MARK: - Titles

    private var title: String {
        guard let index = currentIndex else { return String(localized: "Photo") }
        return String(localized: "\(index + 1) of \(photos.count)")
    }

    // MARK: - Actions

    /// The index `offset` steps away, or `nil` at either end.
    private func destination(from index: Int?, by offset: Int) -> Int? {
        guard let index else { return nil }
        let target = index + offset
        return photos.indices.contains(target) ? target : nil
    }

    private func step(by offset: Int) {
        guard let target = destination(from: currentIndex, by: offset) else { return }
        withAnimation { currentID = photos[target].id }
    }

    /// Moves the map's selection dot to the photo's place on the trail and
    /// gets out of the way so it can be seen.
    ///
    /// The camera is framed on the coordinate at a fixed, close span rather
    /// than re-fitted to the whole route: the point of the button is to see
    /// where one photo was taken, and a route-wide fit would put it back in
    /// the middle of everything.
    private func show(_ coordinate: CLLocationCoordinate2D) {
        highlight.move(to: coordinate)
        mapController.show(
            MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: Self.photoRegionMeters,
                longitudinalMeters: Self.photoRegionMeters
            )
        )
        dismiss()
    }

    /// Close enough to see the bend in the trail the photo was taken from.
    private static let photoRegionMeters: CLLocationDistance = 500

    private func delete(_ photo: HikePhoto) {
        // Step off the photo first: removing the one the scroll view is
        // resting on leaves `scrollPosition` pointing at an id that no longer
        // exists, and the view stays blank until something else moves it.
        let successor = destination(from: currentIndex, by: 1)
            ?? destination(from: currentIndex, by: -1)
        currentID = successor.map { photos[$0].id }
        HikePhotoImport.remove(photo, from: hike, store: store)
    }
}

/// One full-bleed page.
///
/// Separate from the viewer so paging redraws a page rather than the toolbar,
/// the title and the button pill with it — and so the `.task(id:)` that
/// decodes belongs to the page that needs it and is cancelled when that page
/// is recycled.
private struct HikePhotoPage: View {
    let photo: HikePhoto
    let store: HikePhotoStore

    @State private var image: PhotoImage?

    var body: some View {
        ZStack {
            if let image {
                Image(photoImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement()
        .accessibilityLabel(Self.label(for: photo))
        .task(id: photo.id) {
            image = await HikePhotoLoader.displayImage(for: photo, in: store)?.image
        }
    }

    /// VoiceOver cannot describe a photograph, so it gets what the app does
    /// know about it: when it was taken, and whether it has a place on the
    /// trail.
    private static func label(for photo: HikePhoto) -> String {
        let taken = photo.capturedAt.formatted(date: .abbreviated, time: .shortened)
        return photo.isAnchored
            ? String(localized: "Photo taken \(taken), pinned to the trail")
            : String(localized: "Photo taken \(taken)")
    }
}
