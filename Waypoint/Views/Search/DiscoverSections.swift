import CoreLocation
import SwiftUI

/// The photo-led discovery shelves in the focused, empty-query search sheet, mirroring Apple
/// Maps' own "Suggested Places" and "Trending Restaurants": a grouped card of rows with a photo
/// thumbnail, cuisine, distance, open/closed state and rating, then a horizontally paging strip
/// of large ranked photo cards.
///
/// These are Google-backed (see `DiscoverViewModel`) because MapKit exposes none of the fields
/// this layout is built around. Every field here still renders conditionally — a place with no
/// photo or no rating drops that element rather than showing a placeholder.
struct DiscoverSections: View {
    let discover: DiscoverViewModel
    let currentLocation: CLLocation?
    let onSelect: (DetailedPlace) -> Void

    var body: some View {
        if !discover.suggestedPlaces.isEmpty {
            Section {
                if discover.isUsingFallbackData {
                    // The shelves fell back to MapKit, which returns no photos, ratings or hours.
                    // Saying so beats letting the thinner cards read as a broken layout.
                    Label(
                        "Showing limited results — photos and ratings are unavailable right now.",
                        systemImage: "exclamationmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                }
            }

            Section(header: SectionHeader(title: "Suggested Places", showsChevron: false)) {
                // Apple groups these two-to-a-card and pages sideways through the rest.
                pagedGroups(discover.suggestedPlaces, perPage: 2) { place in
                    SuggestedRow(
                        place: place,
                        imageURL: discover.photoURL(for: place, maxWidthPx: 200),
                        distance: distanceText(to: place),
                        action: { onSelect(place) }
                    )
                }
            }
        }

        if !discover.trendingRestaurants.isEmpty {
            // "Trending" is defensible here: this shelf is ranked by Google's own POPULARITY
            // preference, not just proximity.
            Section(header: SectionHeader(title: "Trending Restaurants", showsChevron: true)) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(discover.trendingRestaurants.enumerated()), id: \.element.id) { index, place in
                            TrendingCard(
                                rank: index + 1,
                                place: place,
                                imageURL: discover.photoURL(for: place, maxWidthPx: 600),
                                distance: distanceText(to: place),
                                action: { onSelect(place) }
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

    /// Rows chunked into full-width grouped cards that page horizontally, the way Apple's
    /// Suggested Places shelf behaves.
    private func pagedGroups<Content: View>(
        _ places: [DetailedPlace],
        perPage: Int,
        @ViewBuilder row: @escaping (DetailedPlace) -> Content
    ) -> some View {
        let pages = stride(from: 0, to: places.count, by: perPage).map {
            Array(places[$0..<min($0 + perPage, places.count)])
        }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(pages.enumerated()), id: \.offset) { _, page in
                    VStack(spacing: 0) {
                        ForEach(Array(page.enumerated()), id: \.element.id) { index, place in
                            row(place)
                            if index < page.count - 1 {
                                Divider().padding(.leading, 78)
                            }
                        }
                    }
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
                    .containerRelativeFrame(.horizontal, count: 1, spacing: 12)
                }
            }
            .scrollTargetLayout()
            .padding(.vertical, 4)
        }
        .scrollTargetBehavior(.viewAligned)
        .safeAreaPadding(.horizontal, 16)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
    }

    /// Real straight-line distance, or nothing when there's no location fix — never a placeholder.
    private func distanceText(to place: DetailedPlace) -> String? {
        guard let currentLocation, let coordinate = place.coordinate else { return nil }
        let meters = currentLocation.distance(
            from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        )
        return Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }
}

private struct SuggestedRow: View {
    let place: DetailedPlace
    let imageURL: URL?
    let distance: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                PlaceThumbnail(url: imageURL, place: place, side: 54, cornerRadius: 10)

                VStack(alignment: .leading, spacing: 3) {
                    Text(place.displayName?.text ?? "Place")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let categoryLine {
                        Text(categoryLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if status != nil || place.rating != nil {
                        HStack(spacing: 4) {
                            if let status {
                                // Apple only tints the not-yet-open case ("Opens 5:30 PM") amber;
                                // an already-open place is plain secondary text, not green.
                                Text(status.text)
                                    .foregroundStyle(status.isOpen ? Color.secondary : Color.orange)
                            }
                            if status != nil, place.rating != nil {
                                Text("·").foregroundStyle(.secondary)
                            }
                            if let rating = place.rating {
                                Image(systemName: "star.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                // Attributed, the way Apple credits Yelp — ours is Google data,
                                // so claiming Yelp would be wrong.
                                Text("\(String(format: "%.1f", rating)) Google")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                        .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "ellipsis")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("suggested-\(place.id)")
    }

    /// "Cafe · 0.4 mi · $$" — only the parts Google actually returned.
    private var categoryLine: String? {
        let parts = [place.primaryTypeDisplayName?.text, distance, place.priceIndicator]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var status: (text: String, isOpen: Bool)? {
        place.currentOpeningHours?.statusLine
    }
}

private struct TrendingCard: View {
    let rank: Int
    let place: DetailedPlace
    let imageURL: URL?
    let distance: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                PlaceThumbnail(url: imageURL, place: place, side: nil, cornerRadius: 18)
                    .frame(width: 240, height: 155)
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                // Keeps the overlaid text legible over whatever the photo happens to be.
                LinearGradient(
                    colors: [.black.opacity(0.75), .black.opacity(0.1), .clear],
                    startPoint: .bottom, endPoint: .top
                )
                .clipShape(RoundedRectangle(cornerRadius: 18))

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(rank)")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(radius: 4)
                    Spacer(minLength: 0)
                    Text(place.displayName?.text ?? "Restaurant")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let categoryLine {
                        Text(categoryLine)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                    }
                    if let statusLine {
                        Text(statusLine)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                    }
                }
                .padding(12)
            }
            .frame(width: 240, height: 155)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("trending-\(rank)")
    }

    /// Apple stacks these as two lines: cuisine · distance, then hours · rating.
    private var categoryLine: String? {
        let parts = [place.primaryTypeDisplayName?.text, distance].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var statusLine: String? {
        var parts: [String] = []
        if let status = place.currentOpeningHours?.statusLine { parts.append(status.text) }
        if let rating = place.rating { parts.append("★ \(String(format: "%.1f", rating))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A place photo, falling back to the place's category glyph rather than an empty grey frame
/// when Google has no photo for it.
/// Shared with the Guides shelf, so it can't be file-private.
struct PlaceThumbnail: View {
    let url: URL?
    let place: DetailedPlace
    /// Square side for row thumbnails; nil lets the card size it (the large trending cards).
    let side: CGFloat?
    let cornerRadius: CGFloat

    var body: some View {
        GooglePhotoImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            default:
                fallback
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .clipped()
    }

    private var fallback: some View {
        let icon = PlaceCategoryIcon.icon(
            for: [place.primaryTypeDisplayName?.text, place.displayName?.text]
                .compactMap { $0 }
                .joined(separator: " ")
        )
        return ZStack {
            Rectangle().fill(icon.color.gradient.opacity(0.85))
            Image(systemName: icon.symbol)
                .font(.system(size: side.map { $0 * 0.4 } ?? 34, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}

/// Apple's shelf headers: bold title, with a chevron only on the shelves that open a fuller list.
struct SectionHeader: View {
    let title: String
    let showsChevron: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .textCase(nil)
        .padding(.top, 4)
        .padding(.horizontal, 16)
    }
}
