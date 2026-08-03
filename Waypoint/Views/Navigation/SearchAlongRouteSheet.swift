import CoreLocation
import SwiftUI

/// Category chips (Gas/Food/Coffee/EV Charging/Parking) plus results, matching Apple Maps'
/// search-along-route panel. Tapping a result adds it as a stop on the active trip.
struct SearchAlongRouteSheet: View {
    let remainingCoordinates: [CLLocationCoordinate2D]
    let onAddStop: (CLLocationCoordinate2D) -> Void

    @State private var viewModel = SearchAlongRouteViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                categoryRow
                Divider()
                resultsList
            }
            .navigationTitle("Search Along Route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var categoryRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(SearchAlongRouteViewModel.Category.allCases) { category in
                    Button {
                        viewModel.select(category, along: remainingCoordinates)
                    } label: {
                        Label(category.label, systemImage: category.symbol)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("alongRouteCategory-\(category.rawValue)")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private var resultsList: some View {
        if viewModel.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = viewModel.errorMessage {
            Text(errorMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.selectedCategory == nil {
            Text("Pick a category to see what's ahead on your route.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(viewModel.results) { place in
                AlongRouteResultRow(place: place) {
                    guard let coordinate = place.coordinate else { return }
                    onAddStop(coordinate)
                    dismiss()
                }
            }
            .listStyle(.plain)
        }
    }
}

private struct AlongRouteResultRow: View {
    let place: GooglePlace
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            let icon = PlaceCategoryIcon.icon(for: place.displayName?.text ?? "")
            ZStack {
                Circle().fill(icon.color.gradient).frame(width: 40, height: 40)
                Image(systemName: icon.symbol).font(.subheadline).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(place.displayName?.text ?? "Unknown")
                    .font(.body)
                    .lineLimit(1)
                if let address = place.formattedAddress {
                    Text(address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let rating = place.rating {
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                        Text(String(format: "%.1f", rating)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button("Add", action: onAdd)
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("addAlongRouteStop-\(place.id)")
        }
        .padding(.vertical, 4)
    }
}
