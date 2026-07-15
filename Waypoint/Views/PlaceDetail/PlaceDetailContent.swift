import MapKit
import SwiftUI

struct PlaceDetailContent: View {
    let result: SearchResult
    let onClose: () -> Void

    @State private var viewModel = PlaceDetailViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if let place = viewModel.place {
                    if let photos = place.photos, !photos.isEmpty {
                        photoCarousel(photos)
                    }
                    ratingRow(place)
                    if let hours = place.currentOpeningHours {
                        hoursSection(hours)
                    }
                    contactSection(place)
                    if let reviews = place.reviews, !reviews.isEmpty {
                        reviewsSection(reviews)
                    }
                } else if viewModel.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }

                getDirectionsButton
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .task(id: result.id) {
            await viewModel.load(for: result)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(result.title)
                    .font(.title2.weight(.semibold))
                if let subtitle = viewModel.place?.primaryTypeDisplayName?.text ?? (result.subtitle.isEmpty ? nil : result.subtitle) {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 8)
    }

    private func photoCarousel(_ photos: [GooglePlace.Photo]) -> some View {
        TabView {
            ForEach(photos) { photo in
                if let url = viewModel.photoURL(for: photo) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            Rectangle().fill(.quaternary)
                        }
                    }
                    .clipped()
                }
            }
        }
        .tabViewStyle(.page)
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func ratingRow(_ place: GooglePlace) -> some View {
        if let rating = place.rating {
            HStack(spacing: 8) {
                RatingStarsView(rating: rating)
                Text(String(format: "%.1f", rating))
                    .font(.subheadline.weight(.semibold))
                if let count = place.userRatingCount {
                    Text("(\(count))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func hoursSection(_ hours: GooglePlace.OpeningHours) -> some View {
        DisclosureGroup {
            if let descriptions = hours.weekdayDescriptions {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(descriptions, id: \.self) { line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
            }
        } label: {
            if let openNow = hours.openNow {
                Text(openNow ? "Open Now" : "Closed")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(openNow ? .green : .red)
            } else {
                Text("Hours")
                    .font(.subheadline.weight(.semibold))
            }
        }
    }

    private func contactSection(_ place: GooglePlace) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let address = place.formattedAddress ?? (result.subtitle.isEmpty ? nil : result.subtitle) {
                Button(action: openDirections) {
                    Label(address, systemImage: "mappin.and.ellipse")
                }
            }
            if let phone = place.internationalPhoneNumber {
                Button {
                    if let url = URL(string: "tel:\(phone.filter { !$0.isWhitespace })") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label(phone, systemImage: "phone")
                }
            }
            if let websiteUri = place.websiteUri, let url = URL(string: websiteUri) {
                Button {
                    UIApplication.shared.open(url)
                } label: {
                    Label(url.host ?? websiteUri, systemImage: "safari")
                }
            }
        }
        .buttonStyle(.plain)
        .font(.subheadline)
        .foregroundStyle(.primary)
    }

    private func reviewsSection(_ reviews: [GooglePlace.Review]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reviews")
                .font(.headline)
            ForEach(reviews) { review in
                ReviewRow(review: review)
            }
        }
    }

    private var getDirectionsButton: some View {
        Button(action: openDirections) {
            Label("Get Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .padding(.top, 8)
    }

    private func openDirections() {
        result.mapItem.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }
}

private struct ReviewRow: View {
    let review: GooglePlace.Review

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let photoUri = review.authorAttribution?.photoUri, let url = URL(string: photoUri) {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            Circle().fill(.quaternary)
                        }
                    }
                    .frame(width: 32, height: 32)
                    .clipShape(Circle())
                } else {
                    Circle().fill(.quaternary).frame(width: 32, height: 32)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(review.authorAttribution?.displayName ?? "Anonymous")
                        .font(.subheadline.weight(.medium))
                    if let rating = review.rating {
                        RatingStarsView(rating: rating, size: 10)
                    }
                }
                Spacer()
                if let relative = review.relativePublishTimeDescription {
                    Text(relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let text = review.text?.text {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct RatingStarsView: View {
    let rating: Double
    var size: CGFloat = 12

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                Image(systemName: symbolName(for: index))
                    .font(.system(size: size))
                    .foregroundStyle(.yellow)
            }
        }
    }

    private func symbolName(for index: Int) -> String {
        let filled = Double(index + 1)
        if rating >= filled {
            return "star.fill"
        } else if rating >= filled - 0.5 {
            return "star.leadinghalf.filled"
        } else {
            return "star"
        }
    }
}
