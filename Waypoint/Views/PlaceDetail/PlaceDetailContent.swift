import CoreLocation
import MapKit
import SwiftUI

struct PlaceDetailContent: View {
    let result: SearchResult
    let currentLocation: CLLocation?
    let directionsViewModel: DirectionsViewModel
    let favoritesStore: FavoritesStore
    let onClose: () -> Void

    @State private var viewModel = PlaceDetailViewModel()
    @State private var lightbox: LightboxSelection?

    var body: some View {
        ZStack(alignment: .top) {
            // Explicitly vertical: without this, any section that measures wider than the sheet
            // lets the whole card pan sideways.
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if let place = viewModel.place {
                        heroHeader(place)
                        titleBlock(place)
                            .padding(.horizontal)
                            .padding(.top, 14)
                        primaryActionRow(place)
                            .padding(.horizontal)
                            .padding(.top, 16)
                        statStrip(place)
                            .padding(.horizontal)
                            .padding(.top, 18)

                        if let photos = place.photos, !photos.isEmpty {
                            photoShowcase(photos)
                                .padding(.top, 20)
                        }

                        aboutSection(place)
                        ratingsSection(place)
                        goodToKnowSection(place)
                        hoursSection(place)
                        detailsSection(place)
                    } else if viewModel.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 80)
                    } else if let errorMessage = viewModel.errorMessage {
                        VStack(spacing: 14) {
                            Text(result.title).font(.title2.weight(.bold))
                            Button(action: openDirections) {
                                Label("Directions", systemImage: "car.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                            }
                            .buttonStyle(.plain)
                            Text(errorMessage)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                        .padding(.top, 40)
                    }
                }
                .padding(.bottom, 40)
                // Pin content to the scroll view's own width so no section can widen the card.
                .containerRelativeFrame(.horizontal)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled(false)

            floatingHeaderControls
        }
        .task(id: result.id) {
            await viewModel.load(for: result)
        }
        .fullScreenCover(item: $lightbox) { selection in
            PhotoLightbox(
                photos: selection.photos,
                startIndex: selection.index,
                urlProvider: { viewModel.photoURL(for: $0, maxWidthPx: 1600) }
            )
        }
    }

    private func openLightbox(_ photos: [DetailedPlace.Photo], at index: Int) {
        lightbox = LightboxSelection(photos: photos, index: index)
    }

    // MARK: Apple-style header

    /// Floating share/close buttons that sit over the hero photo, always reachable.
    private var floatingHeaderControls: some View {
        HStack {
            ShareLink(item: shareText) {
                floatingCircle("square.and.arrow.up")
            }
            .buttonStyle(.plain)
            Spacer()
            Button {
                favoritesStore.toggle(result)
            } label: {
                floatingCircle(isFavorite ? "star.fill" : "star", tint: isFavorite ? .yellow : .primary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("favoriteButton")
            Button(action: onClose) {
                floatingCircle("xmark")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("closeDetailButton")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var isFavorite: Bool {
        favoritesStore.isFavorite(result)
    }

    private func floatingCircle(_ systemName: String, tint: Color = .primary) -> some View {
        Image(systemName: systemName)
            .scaledFont(size: 15, weight: .bold, relativeTo: .subheadline)
            .foregroundStyle(tint)
            .frame(width: 34, height: 34)
            .background(.regularMaterial, in: Circle())
    }

    private var shareText: String {
        [viewModel.place?.displayName?.text ?? result.title, viewModel.place?.formattedAddress]
            .compactMap { $0 }
            .joined(separator: " — ")
    }

    /// Edge-to-edge hero photo with a gradient scrim, like Apple's place cards.
    @ViewBuilder
    private func heroHeader(_ place: DetailedPlace) -> some View {
        if let photo = place.photos?.first {
            Button {
                openLightbox(place.photos ?? [], at: 0)
            } label: {
                photoImage(photo, contentMode: .fill)
                    .frame(height: 210)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .overlay(alignment: .bottom) {
                        LinearGradient(
                            colors: [.clear, Color(uiColor: .systemBackground)],
                            startPoint: .center,
                            endPoint: .bottom
                        )
                        .frame(height: 90)
                    }
            }
            .buttonStyle(.plain)
        } else {
            Color.clear.frame(height: 56)
        }
    }

    /// Name, category · price, and neighborhood.
    private func titleBlock(_ place: DetailedPlace) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(place.displayName?.text ?? result.title)
                .scaledFont(size: 30, weight: .bold, relativeTo: .title)
                .lineLimit(2)
            HStack(spacing: 6) {
                if let type = place.primaryTypeDisplayName?.text {
                    Text(type)
                }
                if let price = place.priceIndicator {
                    Text("·")
                    Text(price)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Directions (filled blue, with ETA when known) + Call + Website, matching Apple.
    private func primaryActionRow(_ place: DetailedPlace) -> some View {
        HStack(spacing: 10) {
            Button(action: openDirections) {
                VStack(spacing: 3) {
                    Image(systemName: "car.fill").scaledFont(size: 17, weight: .semibold, relativeTo: .body)
                    Text("Directions").font(.caption.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
            }
            .accessibilityIdentifier("getDirectionsButton")
            Button {
                favoritesStore.toggle(result)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: favoritesStore.isFavorite(result) ? "star.fill" : "star")
                        .scaledFont(size: 17, weight: .semibold, relativeTo: .body)
                        .foregroundStyle(favoritesStore.isFavorite(result) ? Color.yellow : Color.accentColor)
                    Text(favoritesStore.isFavorite(result) ? "Saved" : "Save")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)

            if let phone = place.internationalPhoneNumber {
                secondaryAction(symbol: "phone.fill", title: "Call") {
                    if let url = URL(string: "tel:\(phone.filter { !$0.isWhitespace })") {
                        UIApplication.shared.open(url)
                    }
                }
            }
            if let website = place.websiteUri.flatMap(URL.init(string:)) {
                secondaryAction(symbol: "safari.fill", title: "Website") {
                    UIApplication.shared.open(website)
                }
            }
        }
    }

    private func secondaryAction(symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).scaledFont(size: 17, weight: .semibold, relativeTo: .body)
                Text(title).font(.caption.weight(.semibold))
            }
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    /// Hours / Rating / Distance columns under the action buttons.
    private func statStrip(_ place: DetailedPlace) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if let openNow = place.currentOpeningHours?.openNow {
                statColumn(title: "Hours") {
                    Text(openNow ? "Open" : "Closed")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(openNow ? .green : .red)
                }
            }
            if let rating = place.rating {
                statColumn(title: "Google (\(place.userRatingCount ?? 0))") {
                    HStack(spacing: 3) {
                        Image(systemName: "star.fill").font(.caption).foregroundStyle(.orange)
                        Text(String(format: "%.1f", rating)).font(.subheadline.weight(.semibold))
                    }
                }
            }
            if let distance = distanceText(place) {
                statColumn(title: "Distance") {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                            .font(.caption2).foregroundStyle(.secondary)
                        Text(distance).font(.subheadline.weight(.semibold))
                    }
                }
            }
        }
    }

    private func statColumn<Content: View>(title: String, @ViewBuilder value: () -> Content) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            value()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        // Equal thirds that shrink text rather than widening the row.
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func distanceText(_ place: DetailedPlace) -> String? {
        guard let currentLocation, let coordinate = place.coordinate else { return nil }
        let meters = currentLocation.distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
        return Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    /// Horizontally scrolling photo cards, mirroring Apple's "From the Business / All Photos".
    private func photoShowcase(_ photos: [DetailedPlace.Photo]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(photos.prefix(10).enumerated()), id: \.element.id) { index, photo in
                    Button {
                        openLightbox(photos, at: index)
                    } label: {
                        photoImage(photo, contentMode: .fill)
                            .frame(width: 200, height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(alignment: .topLeading) {
                                if index == 0 {
                                    Text("All Photos")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .shadow(radius: 3)
                                        .padding(10)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }

    @ViewBuilder
    private func aboutSection(_ place: DetailedPlace) -> some View {
        if let description = place.descriptionText, !description.isEmpty {
            sectionContainer(title: "About") {
                Text(description)
                    .font(.body)
                    .foregroundStyle(.primary)
            }
        }
    }

    @ViewBuilder
    private func ratingsSection(_ place: DetailedPlace) -> some View {
        if let reviews = place.reviews, !reviews.isEmpty {
            sectionContainer(title: "Ratings & Reviews") {
                VStack(spacing: 14) {
                    ForEach(reviews.prefix(5)) { review in
                        ReviewRow(review: review)
                        if review.id != reviews.prefix(5).last?.id { Divider() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func goodToKnowSection(_ place: DetailedPlace) -> some View {
        let items = place.goodToKnow
        if !items.isEmpty {
            sectionContainer(title: "Good to Know") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(items, id: \.label) { item in
                        HStack(spacing: 12) {
                            Image(systemName: item.symbol)
                                .scaledFont(size: 15, relativeTo: .subheadline)
                                .frame(width: 24)
                                .foregroundStyle(.primary)
                            Text(item.label).font(.body)
                            Spacer()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func hoursSection(_ place: DetailedPlace) -> some View {
        if let hours = place.currentOpeningHours, let descriptions = hours.weekdayDescriptions, !descriptions.isEmpty {
            sectionContainer(title: "Hours") {
                VStack(alignment: .leading, spacing: 8) {
                    if let openNow = hours.openNow {
                        Text(openNow ? "Open" : "Closed")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(openNow ? .green : .red)
                    }
                    ForEach(descriptions, id: \.self) { line in
                        Text(line)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func detailsSection(_ place: DetailedPlace) -> some View {
        sectionContainer(title: "Details") {
            VStack(spacing: 0) {
                if let phone = place.internationalPhoneNumber {
                    detailRow(label: "Phone", value: phone, isLink: true) {
                        if let url = URL(string: "tel:\(phone.filter { !$0.isWhitespace })") {
                            UIApplication.shared.open(url)
                        }
                    }
                    Divider()
                }
                if let websiteUri = place.websiteUri, let url = URL(string: websiteUri) {
                    detailRow(label: "Website", value: url.host ?? websiteUri, isLink: true) {
                        UIApplication.shared.open(url)
                    }
                    Divider()
                }
                if let address = place.formattedAddress {
                    detailRow(label: "Address", value: address, isLink: false, action: nil)
                }
            }
        }
    }

    private func detailRow(label: String, value: String, isLink: Bool, action: (() -> Void)?) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Group {
                if let action {
                    Button(action: action) {
                        Text(value)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(isLink ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(value)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.primary)
                }
            }
            .font(.body)
        }
        .padding(.vertical, 12)
    }

    private func sectionContainer<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title2.weight(.bold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.top, 26)
    }

    // MARK: Shared

    private func photoImage(_ photo: DetailedPlace.Photo, contentMode: ContentMode) -> some View {
        Group {
            if let url = viewModel.photoURL(for: photo) {
                GooglePhotoImage(url: url) { phase in
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


/// iOS 26 Maps-style action chip: soft rounded-rect card, icon in a tinted circle up top,
/// label below, evenly filling the row rather than floating bare circles.



private struct ReviewRow: View {
    let review: DetailedPlace.Review

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
