import MapKit
import SwiftUI

struct CommunityPlacePicker: View {
    let onChoose: (MKCoordinateRegion, String) -> Void
    @State private var query = ""
    @State private var completer = SearchCompleter()
    @State private var task: Task<Void, Never>?
    @State private var isSearching = false
    @State private var failure: SearchFailure?

    var body: some View {
        NavigationStack {
            List {
                TextField("Town, mountain or region", text: $query)
                    .accessibilityIdentifier("community-place-search")
                    .submitLabel(.search)
                    .onSubmit(searchQuery)
                    .onChange(of: query) { _, value in
                        task?.cancel()
                        isSearching = false
                        failure = nil
                        completer.update(query: value)
                    }
                if isSearching { ProgressView("Finding place…") }
                if let failure { Text(failure.localizedDescription) }
                ForEach(completer.suggestions, id: \.self) { suggestion in
                    Button {
                        resolve(.init(completion: suggestion), name: suggestion.title)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(suggestion.title)
                            Text(suggestion.subtitle).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Search for \(query)", action: searchQuery)
                        .accessibilityIdentifier("community-place-submit")
                }
            }
            .navigationTitle("Choose an area")
            .toolbar { ToolbarItem(placement: .cancellationAction) { DismissButton("Cancel") } }
        }
        .onDisappear { task?.cancel() }
    }

    private func searchQuery() {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        resolve(request, name: query)
    }

    private func resolve(_ request: MKLocalSearch.Request, name: String) {
        task?.cancel()
        isSearching = true
        failure = nil
        task = Task {
            do {
                let place = try await SearchPlace.resolve(request, fallbackName: name)
                try Task.checkCancellation()
                isSearching = false
                onChoose(place.region, place.name)
            } catch {
                guard !Task.isCancelled else { return }
                isSearching = false
                failure = error as? SearchFailure ?? SearchFailure(underlying: error)
            }
        }
    }
}

/// One resolution path for the main field, a place suggestion and the area picker.
enum SearchPlace {
    struct Result {
        let region: MKCoordinateRegion
        let name: String
    }

    static func resolve(_ request: MKLocalSearch.Request, fallbackName: String) async throws -> Result {
        #if DEBUG
        if AppLaunchEnvironment.stubsCommunity {
            return Result(region: CommunitySearchFixture.region, name: fallbackName)
        }
        #endif
        let response = try await MKLocalSearch(request: request).start()
        guard !response.mapItems.isEmpty else { throw SearchFailure(reason: .noResults) }
        return Result(region: response.boundingRegion, name: response.mapItems.first?.name ?? fallbackName)
    }
}
