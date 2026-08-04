import SwiftUI

/// Google-powered discovery rows shown in the focused, empty-query search sheet:
/// a "Suggested Places" carousel and a numbered "Trending Restaurants" carousel.
struct DiscoverSections: View {
    let discover: DiscoverViewModel
    let onSelect: (GooglePlace) -> Void

    var body: some View {
        if !discover.suggestedPlaces.isEmpty {
            Section("Suggested Places") {
                carousel(discover.suggestedPlaces) { place in
                    SuggestedCard(place: place, imageURL: discover.photoURL(for: place)) {
                        onSelect(place)
                    }
                }
            }
        }

        if !discover.trendingRestaurants.isEmpty {
            Section("Trending Restaurants") {
                carousel(Array(discover.trendingRestaurants.enumerated())) { pair in
                    TrendingCard(rank: pair.offset + 1, place: pair.element, imageURL: discover.photoURL(for: pair.element, maxWidthPx: 600)) {
                        onSelect(pair.element)
                    }
                }
            }
        }
    }

    private func carousel<Item, Content: View>(
        _ items: [Item],
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    content(item)
                }
            }
            .padding(.vertical, 4)
        }
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
    }
}

private struct SuggestedCard: View {
    let place: GooglePlace
    let imageURL: URL?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                placeThumbnail(imageURL, size: 56, cornerRadius: 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text(place.displayName?.text ?? "Place")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let type = place.primaryTypeDisplayName?.text {
                        Text(type)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    ratingLine(place)
                }
                .frame(width: 150, alignment: .leading)
            }
            .padding(10)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("suggested-\(place.id)")
    }
}

private struct TrendingCard: View {
    let rank: Int
    let place: GooglePlace
    let imageURL: URL?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                placeThumbnail(imageURL, size: nil, cornerRadius: 16)
                    .frame(width: 240, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                LinearGradient(
                    colors: [.black.opacity(0.6), .clear],
                    startPoint: .bottom, endPoint: .center
                )
                .clipShape(RoundedRectangle(cornerRadius: 16))

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(rank)")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(radius: 3)
                    Spacer()
                    Text(place.displayName?.text ?? "Restaurant")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if let type = place.primaryTypeDisplayName?.text {
                            Text(type)
                        }
                        if let rating = place.rating {
                            Text("· ★ \(String(format: "%.1f", rating))")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                }
                .padding(12)
            }
            .frame(width: 240, height: 150)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("trending-\(rank)")
    }
}

@ViewBuilder
private func placeThumbnail(_ url: URL?, size: CGFloat?, cornerRadius: CGFloat) -> some View {
    GooglePhotoImage(url: url) { phase in
        switch phase {
        case .success(let image):
            image.resizable().aspectRatio(contentMode: .fill)
        default:
            Rectangle().fill(.quaternary)
                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    .clipped()
}

@ViewBuilder
private func ratingLine(_ place: GooglePlace) -> some View {
    if let rating = place.rating {
        HStack(spacing: 3) {
            Image(systemName: "star.fill")
                .font(.caption2)
                .foregroundStyle(.yellow)
            Text(String(format: "%.1f", rating))
                .font(.caption)
            if let count = place.userRatingCount {
                Text("(\(count))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
