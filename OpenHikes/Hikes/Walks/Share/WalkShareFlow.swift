//
//  WalkShareFlow.swift
//  OpenHikes
//
//  *Share* from a walk's summary: choose the photograph, then arrange the
//  card over it.
//
//  The photograph comes first because the card is drawn on it — there is no
//  card without one. The hike's own photographs are offered first, the walk's
//  before the rest, since those are the pictures of this walk; the library is
//  one button below them for a picture the app never filed. Back from the
//  editor is how a different photograph is chosen, and the layout survives
//  the trip because it is remembered rather than held here.
//

import OpenHikesData
import PhotosUI
import SwiftUI

struct WalkShareFlow: View {
    let walk: HikeWalk
    /// The trail's profile, as the summary built it.
    let trail: RouteProfile?
    /// Whether ``trail`` is still the route the walk was walked along. When
    /// it is not, the card draws the trail's outline without the covered
    /// stretches and leaves the climb off — see ``WalkShareFigures``.
    let trailMatchesWalk: Bool
    /// Everything the flow has chosen so far, kept by the sheet so a turn of
    /// the phone does not throw it away — see ``WalkShareSession``.
    @Bindable var session: WalkShareSession
    var store: HikePhotoStore = .shared

    /// For its `defaults`, where the layout is remembered: the app's own, so
    /// a UI-testing launch's are fresh like every other setting it reads.
    @Environment(OpenHikesModel.self) private var appModel
    @State private var pickedItem: PhotosPickerItem?

    private static let thumbnailSide: CGFloat = 104

    private var hike: Hike? { walk.hike }
    /// The profile the walk's stretches are metres along, if it still exists.
    private var walkedProfile: RouteProfile? { trailMatchesWalk ? trail : nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    libraryButton
                    hikePhotos
                }
                .padding()
                // The photographs only, never the bar: a library photo still
                // in iCloud can take a long time to arrive, and Close has to
                // work while it does.
                .disabled(session.isLoading || session.shape == nil)
            }
            .navigationTitle("Choose a Photo")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    DismissButton(role: .close)
                }
            }
            .overlay {
                if session.isLoading || session.shape == nil {
                    ProgressView()
                        .controlSize(.large)
                }
            }
            .navigationDestination(isPresented: $session.isEditing) {
                if let editor = session.editor {
                    WalkShareEditor(model: editor)
                }
            }
            .alert("This photo couldn't be opened.", isPresented: $session.loadFailed) {
                Button("OK", role: .cancel) { /* the alert's own dismissal */ }
            }
        }
        .task(id: walk.id) {
            // Fitted once per share: a flow re-presented after a rotation
            // finds it already here.
            guard session.shape == nil else { return }
            session.shape = await Self.shape(of: walk.coverage.ranges, along: trail, walked: trailMatchesWalk)
        }
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            pickedItem = nil
            Task { await open(item) }
        }
    }

    private var libraryButton: some View {
        PhotosPicker(selection: $pickedItem, matching: .images, photoLibrary: .shared()) {
            Label("Choose from Library", systemImage: "photo.on.rectangle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .accessibilityIdentifier("walk-share-library")
    }

    @ViewBuilder private var hikePhotos: some View {
        let photos = Self.offered(hike?.orderedPhotos ?? [], walkedFrom: walk.startedAt, to: walk.endedAt)
        if !photos.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("This Hike's Photos")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.thumbnailSide), spacing: 4)], spacing: 4) {
                    ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                        Button {
                            Task { await open(photo) }
                        } label: {
                            HikePhotoThumbnail(
                                photo: photo,
                                store: store,
                                size: Self.thumbnailSide,
                                cornerRadius: 6,
                                label: String(localized: "Photo \(index + 1)")
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("walk-share-photo-\(index)")
                    }
                }
            }
        }
    }

    /// The hike's photographs worth offering: the walk's own first, then the
    /// rest, and none that was only ever a place in a `.gpx`.
    static func offered(_ photos: [HikePhoto], walkedFrom start: Date, to end: Date) -> [HikePhoto] {
        let pictures = photos.filter { !$0.recordsPlaceOnly }
        let walked = pictures.filter { (start...max(start, end)).contains($0.capturedAt) }
        let others = pictures.filter { !(start...max(start, end)).contains($0.capturedAt) }
        return walked + others
    }

    private func open(_ photo: HikePhoto) async {
        let generation = session.generation
        session.isLoading = true
        defer { if session.generation == generation { session.isLoading = false } }
        let result = await HikePhotoLoader.display(for: photo, in: store)
        guard session.generation == generation else { return }
        guard case .ready(let loaded) = result else {
            session.loadFailed = true
            return
        }
        edit(on: loaded.image)
    }

    private func open(_ item: PhotosPickerItem) async {
        let generation = session.generation
        session.isLoading = true
        defer { if session.generation == generation { session.isLoading = false } }
        var image: LoadedPhotoImage?
        if let data = try? await item.loadTransferable(type: Data.self) {
            image = await Self.decode(data)
        }
        guard session.generation == generation else { return }
        guard let image else {
            session.loadFailed = true
            return
        }
        edit(on: image.image)
    }

    private func edit(on photo: PhotoImage) {
        guard let shape = session.shape else { return }
        let title = hike?.displayTitle ?? String(localized: "Hike")
        let card = WalkShareCard(
            photo: photo,
            figures: WalkShareFigures(walk: walk, title: title, profile: walkedProfile),
            shape: shape,
            tint: hike?.tintOpaque ?? .green
        )
        session.editor = WalkShareEditorModel(card: card, defaults: appModel.defaults)
        session.isEditing = true
    }

    /// A picked photograph at the size the store keeps its own, upright.
    @concurrent
    private static func decode(_ data: Data) async -> LoadedPhotoImage? {
        guard let image = PhotoDownsampling.image(from: data, maxPixelSize: HikePhotoStore.displayMaxPixelSize) else {
            return nil
        }
        return LoadedPhotoImage(image: PhotoImage(cgImage: image))
    }

    /// The trail's outline with the walk's stretches over it, fitted once.
    ///
    /// Off the main actor: a recorded trail is twenty thousand points, and
    /// the stretches walk the covered part of them again.
    @concurrent
    private static func shape(
        of ranges: [ClosedRange<Double>],
        along trail: RouteProfile?,
        walked: Bool
    ) async -> WalkShareRouteShape {
        guard let trail else { return .empty }
        let stretches = walked ? await WalkHighlight.segments(covering: ranges, along: trail) : []
        return WalkShareRouteShape(fitting: trail.coordinates, walked: stretches)
    }
}
