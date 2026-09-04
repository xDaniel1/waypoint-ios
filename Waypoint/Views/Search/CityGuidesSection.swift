import CoreLocation
import SwiftUI

/// Apple's "City Guides" shelf: tall portrait cards for nearby major cities, each opening to that
/// city's top-rated attractions. See `CityGuidesViewModel` for why these are a fixed city list
/// rather than editorial content.
///
/// Hands off to `onOpen` rather than presenting its own sheet — see `GuidesSection` for why.
struct CityGuidesSection: View {
    let cityGuides: CityGuidesViewModel
    let onOpen: (CityGuidesViewModel.CityGuide) -> Void

    var body: some View {
        if !cityGuides.cityGuides.isEmpty {
            Section {
                SectionHeader(title: "City Guides", showsChevron: false)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(cityGuides.cityGuides) { city in
                            CityCard(
                                city: city,
                                imageURL: city.coverPlace.flatMap {
                                    cityGuides.photoURL(for: $0, maxWidthPx: 500)
                                },
                                action: { onOpen(city) }
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

private struct CityCard: View {
    let city: CityGuidesViewModel.CityGuide
    let imageURL: URL?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                if let coverPlace = city.coverPlace {
                    PlaceThumbnail(url: imageURL, place: coverPlace, side: nil, cornerRadius: 18)
                        .frame(width: 170, height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                }

                LinearGradient(
                    colors: [.black.opacity(0.8), .black.opacity(0.1), .clear],
                    startPoint: .bottom, endPoint: .top
                )
                .clipShape(RoundedRectangle(cornerRadius: 18))

                VStack(alignment: .leading, spacing: 2) {
                    Text(city.name)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(city.region)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                .padding(14)
            }
            .frame(width: 170, height: 220)
        }
        .buttonStyle(.pressableCard)
        .accessibilityLabel("\(city.name), \(city.region)")
    }
}
