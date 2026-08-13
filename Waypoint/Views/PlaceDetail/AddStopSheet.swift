import MapKit
import SwiftUI

/// A small search screen for picking a stop to insert into the active route. Kept independent
/// of the main `SearchViewModel` — that drives the whole home/search sheet's state, and this is
/// a self-contained, one-shot "pick a place" flow that hands the result back.
///
/// Rendered *inline* inside the directions sheet rather than presented as its own sheet. It was a
/// nested `.sheet`, and on this SDK presenting a sheet from content that is already sheet-presented
/// creates the window but never renders anything into it — an accessibility dump showed a
/// full-size second window containing three empty containers and no search field. Apple Maps
/// pushes this screen inside the same sheet anyway.
struct AddStopSheet: View {
    let currentRegion: MKCoordinateRegion?
    let onCancel: () -> Void
    let onAdd: (MKMapItem) -> Void

    @State private var completerService = SearchCompleterService()
    @State private var queryText = ""
    @State private var isResolving = false
    /// `.searchable(isPresented:)` needs a binding it can actually write back to — passing
    /// `.constant(true)` left SwiftUI unable to drive its own presentation state and the search
    /// field never materialised, so the sheet opened onto an empty list.
    @State private var isSearchPresented = true

    var body: some View {
        NavigationStack {
            List {
                ForEach(completerService.suggestions, id: \.title) { suggestion in
                    Button {
                        Task { await resolve(suggestion) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title).foregroundStyle(.primary)
                            if !suggestion.subtitle.isEmpty {
                                Text(suggestion.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(isResolving)
                }
            }
            .listStyle(.plain)
            .searchable(text: $queryText, isPresented: $isSearchPresented, prompt: "Search for a stop")
            .onChange(of: queryText) { _, newValue in
                completerService.updateQuery(newValue)
            }
            .navigationTitle("Add Stop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
            }
            .overlay {
                if isResolving {
                    ProgressView()
                }
            }
        }
        .onAppear {
            if let currentRegion {
                completerService.updateRegion(currentRegion)
            }
        }
    }

    private func resolve(_ completion: MKLocalSearchCompletion) async {
        isResolving = true
        defer { isResolving = false }
        let request = MKLocalSearch.Request(completion: completion)
        do {
            let response = try await MKLocalSearch(request: request).start()
            if let item = response.mapItems.first {
                onAdd(item)
            }
        } catch {
            // Silent — the user can just try another result or cancel.
        }
    }
}
