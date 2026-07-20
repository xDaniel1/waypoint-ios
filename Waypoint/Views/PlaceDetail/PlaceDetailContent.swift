import CoreLocation
import MapKit
import SwiftUI

struct PlaceDetailContent: View {
    let result: SearchResult
    let currentLocation: CLLocation?
    let directionsViewModel: DirectionsViewModel
    let onClose: () -> Void

    @State private var viewModel = PlaceDetailViewModel()
    @State private var tab: PlaceDetailTab = .overview

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal)
                .padding(.top, 8)

            if let place = viewModel.place {
                ratingRow(place)
                    .padding(.horizontal)
                    .padding(.top, 4)

                getDirectionsButton
                    .padding(.horizontal)
                    .padding(.top, 12)

                tabPicker(place)
                    .padding(.horizontal)
                    .padding(.top, 16)

                Divider()
                    .padding(.top, 8)

                tabContent(place)
            } else if viewModel.isLoading {
                Spacer(minLength: 0)
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                Spacer(minLength: 0)
            } else if let errorMessage = viewModel.errorMessage {
                getDirectionsButton
                    .padding(.horizontal)
                    .padding(.top, 12)
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                Spacer(minLength: 0)
            }
        }
        .animation(.smooth(duration: 0.25), value: tab)
        .task(id: result.id) {
            tab = .overview
            await viewModel.load(for: result)
        }
    }

    // MARK: Header

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
            .accessibilityIdentifier("closeDetailButton")
        }
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
                if let openNow = place.currentOpeningHours?.openNow {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(openNow ? "Open" : "Closed")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(openNow ? .green : .red)
                }
            }
        }
    }

    private var getDirectionsButton: some View {
        Button(action: openDirections) {
            Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .accessibilityIdentifier("getDirectionsButton")
    }

    // MARK: Tabs

    private func tabPicker(_ place: GooglePlace) -> some View {
        let tabs = availableTabs(place)
        return HStack(spacing: 8) {
            ForEach(tabs, id: \.self) { item in
                TabChip(title: item.title, isSelected: tab == item) {
                    tab = item
                }
            }
        }
    }

    @ViewBuilder
    private func tabContent(_ place: GooglePlace) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch tab {
                case .overview:
                    overviewTab(place)
                case .reviews:
                    reviewsTab(place)
                case .photos:
                    photosTab(place)
                case .menu:
                    menuTab(place)
                }
            }
            .padding(.horizontal)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .transition(.opacity)
    }

    private func availableTabs(_ place: GooglePlace) -> [PlaceDetailTab] {
        var tabs: [PlaceDetailTab] = [.overview]
        if let reviews = place.reviews, !reviews.isEmpty { tabs.append(.reviews) }
        if let photos = place.photos, !photos.isEmpty {
            tabs.append(.photos)
            tabs.append(.menu)
        }
        return tabs
    }

    // MARK: Overview

    @ViewBuilder
    private func overviewTab(_ place: GooglePlace) -> some View {
        if let photos = place.photos, !photos.isEmpty {
            photoCarousel(Array(photos.prefix(10)))
        }
        if let description = place.descriptionText, !description.isEmpty {
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
        if let hours = place.currentOpeningHours {
            hoursSection(hours)
        }
        contactSection(place)
    }

    private func photoCarousel(_ photos: [GooglePlace.Photo]) -> some View {
        TabView {
            ForEach(photos) { photo in
                photoImage(photo, contentMode: .fill)
            }
        }
        .tabViewStyle(.page)
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 16))
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

    // MARK: Reviews

    @ViewBuilder
    private func reviewsTab(_ place: GooglePlace) -> some View {
        if let reviews = place.reviews {
            ForEach(reviews) { review in
                ReviewRow(review: review)
                if review.id != reviews.last?.id {
                    Divider()
                }
            }
        }
    }

    // MARK: Photos

    @ViewBuilder
    private func photosTab(_ place: GooglePlace) -> some View {
        if let photos = place.photos {
            let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(photos) { photo in
                    photoImage(photo, contentMode: .fill)
                        .frame(height: 120)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    // MARK: Menu

    @ViewBuilder
    private func menuTab(_ place: GooglePlace) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let websiteUri = place.websiteUri, let url = URL(string: websiteUri) {
                Button {
                    UIApplication.shared.open(url)
                } label: {
                    Label("View Full Menu on Website", systemImage: "arrow.up.forward.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }

            Text("Menu Photos")
                .font(.headline)
            Text("Photos posted for this place — often including menu boards and dishes. Google's public Places API doesn't provide a structured, itemized menu, so these come straight from the place's photos.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let photos = place.photos {
                let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(photos) { photo in
                        photoImage(photo, contentMode: .fill)
                            .frame(height: 120)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
    }

    // MARK: Shared

    private func photoImage(_ photo: GooglePlace.Photo, contentMode: ContentMode) -> some View {
        Group {
            if let url = viewModel.photoURL(for: photo) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: contentMode)
                    default:
                        Rectangle().fill(.quaternary)
                    }
                }
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .clipped()
    }

    private func openDirections() {
        directionsViewModel.start(destination: result.mapItem, from: currentLocation)
    }
}

enum PlaceDetailTab: Hashable {
    case overview, reviews, photos, menu

    var title: String {
        switch self {
        case .overview: "Overview"
        case .reviews: "Reviews"
        case .photos: "Photos"
        case .menu: "Menu"
        }
    }
}

private struct TabChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if isSelected {
                Button(action: action) { label }
                    .buttonStyle(.glassProminent)
            } else {
                Button(action: action) { label }
                    .buttonStyle(.glass)
            }
        }
        .accessibilityIdentifier("tab-\(title)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var label: some View {
        Text(title)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
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
