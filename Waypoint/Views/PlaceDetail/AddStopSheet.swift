import MapKit
import SwiftUI

/// A small search sheet for picking a stop to insert into the active route. Kept independent
/// of the main `SearchViewModel` — that drives the whole home/search sheet's state, and this is
/// a self-contained, one-shot "pick a place" flow that hands the result back and dismisses.
struct AddStopSheet: View {
    let currentRegion: MKCoordinateRegion?
    let onAdd: (MKMapItem) -> Void

    @State private var completerService = SearchCompleterService()
    @State private var queryText = ""
    @State private var isResolving = false
    @Environment(\.dismiss) private var dismiss

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
            .searchable(text: $queryText, isPresented: .constant(true), prompt: "Search for a stop")
            .onChange(of: queryText) { _, newValue in
                completerService.updateQuery(newValue)
            }
            .navigationTitle("Add Stop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
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
                dismiss()
            }
        } catch {
            // Silent — the user can just try another result or cancel.
        }
    }
}
