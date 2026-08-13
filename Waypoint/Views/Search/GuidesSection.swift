import CoreLocation
import SwiftUI

/// Apple's "Guides" shelf: a horizontally scrolling strip of large photo cards, each opening to a
/// list of the places inside.
///
/// Apple's own guides are licensed editorial with no public API, so these are assembled from
/// top-rated nearby places instead — and the card says exactly that rather than dressing an
/// algorithm up as a curator.
///
/// Opening a card hands off to the parent (`onOpen`) rather than presenting its own `.sheet`.
/// This shelf and `CityGuidesSection` are siblings in the same List, and two independent
/// `.sheet(item:)` modifiers mounted on sibling rows were not reliably both driveable — the
/// second one presented an empty window. `SearchSheet` owns one sheet for both, the same fix
/// already applied to its profile/favorites/saved-list sheets.
struct GuidesSection: View {
    let guides: GuidesViewModel
    let onOpen: (GuidesViewModel.Guide) -> Void

    var body: some View {
        if !guides.guides.isEmpty {
            Section(header: SectionHeader(title: "Guides", showsChevron: false)) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(guides.guides) { guide in
                            GuideCard(
                                guide: guide,
                                imageURL: guide.coverPlace.flatMap {
                                    guides.photoURL(for: $0, maxWidthPx: 600)
                                },
                                action: { onOpen(guide) }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
                .safeAreaPadding(.horizontal, 16)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
            }
        }
    }
}

private struct GuideCard: View {
    let guide: GuidesViewModel.Guide
    let imageURL: URL?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                if let coverPlace = guide.coverPlace {
                    PlaceThumbnail(url: imageURL, place: coverPlace, side: nil, cornerRadius: 18)
                        .frame(width: 260, height: 170)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                }

                LinearGradient(
                    colors: [.black.opacity(0.8), .black.opacity(0.15), .clear],
                    startPoint: .bottom, endPoint: .top
                )
                .clipShape(RoundedRectangle(cornerRadius: 18))

                VStack(alignment: .leading, spacing: 3) {
                    Image(systemName: guide.symbol)
                        .scaledFont(size: 18, weight: .semibold, relativeTo: .body)
                        .foregroundStyle(.white)
                        .shadow(radius: 3)
                    Spacer(minLength: 0)
                    Text(guide.title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(guide.subtitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                }
                .padding(14)
            }
            .frame(width: 260, height: 170)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(guide.title), \(guide.subtitle)")
    }
}

/// The places inside a guide or city guide, ordered by rating — which is the whole premise of
/// both shelves, so the rating is shown on every row rather than hidden. Shared by `GuidesSection`
/// and `CityGuidesSection` since the two lists are identical apart from title/footer copy.
struct PlaceListDetailSheet: View {
    let title: String
    let footer: String
    let places: [DetailedPlace]
    let photoURL: (DetailedPlace) -> URL?
    let currentLocation: CLLocation?
    let onSelect: (DetailedPlace) -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(places) { place in
                        Button {
                            onSelect(place)
                        } label: {
                            HStack(spacing: 12) {
                                PlaceThumbnail(url: photoURL(place), place: place, side: 56, cornerRadius: 10)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(place.displayName?.text ?? "Place")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    if let detail = detailLine(for: place) {
                                        Text(detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text(footer)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDismiss)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Rating, category and distance — each dropped individually when the place doesn't have it.
    private func detailLine(for place: DetailedPlace) -> String? {
        var parts: [String] = []
        if let rating = place.rating {
            let count = place.userRatingCount.map { " (\($0))" } ?? ""
            parts.append(String(format: "★ %.1f", rating) + count)
        }
        if let category = place.primaryTypeDisplayName?.text {
            parts.append(category)
        }
        if let currentLocation, let location = place.location {
            let meters = currentLocation.distance(
                from: CLLocation(latitude: location.latitude, longitude: location.longitude)
            )
            let miles = meters / 1609.34
            parts.append(miles < 0.2 ? "Nearby" : String(format: "%.1f mi", miles))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
