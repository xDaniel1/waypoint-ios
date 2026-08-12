import CoreLocation
import MapKit
import SwiftUI

private let categories: [(title: String, emoji: String, query: String)] = [
    ("Fast Food", "🍔", "Fast Food"),
    ("Dinner", "🍽️", "Dinner Restaurants"),
    ("Gas Stations", "⛽", "Gas Station"),
    ("Coffee", "☕", "Coffee Shop"),
    ("Groceries", "🛒", "Grocery Store"),
    ("Movies", "🍿", "Movie Theater"),
]

extension PresentationDetent {
    /// Where the card rests when the app opens: search bar, the Places row, and the top of
    /// Recents — the same partial height Apple Maps starts at before you pull it up.
    static let home = PresentationDetent.fraction(0.45)
}

struct SearchSheet: View {
    @Bindable var viewModel: SearchViewModel
    @Bindable var directionsViewModel: DirectionsViewModel
    let currentLocation: CLLocation?
    @Binding var detent: PresentationDetent
    @Binding var collapsedHeight: CGFloat
    @Binding var sheetHeight: CGFloat
    @Binding var directionsHeight: CGFloat
    let onStartNavigation: (RouteOption) -> Void
    /// Bubbled up to MapScreen, which owns the actual sheet presentation — see the comment on
    /// DirectionsCard's matching properties for why this can't be presented from in here.
    let onShowSteps: (RouteOption) -> Void
    @FocusState private var isFieldFocused: Bool
    @State private var isAddingDirectionsStop = false
    /// Stays true for the whole search session — scrolling dismisses the keyboard but must NOT
    /// drop you back to the map, so the results list is driven by this, not by keyboard focus.
    @State private var isSearching = false
    @State private var isShowingProfile = false
    @State private var isAddingFavorite = false
    /// Which "see all" list the user opened from a section header chevron.
    @State private var expandedList: HomeList?
    /// The favorite currently open in the rename/emoji/color editor, from either the home row
    /// or a search-results circle — `SavedListSheet` has its own copy of this for edits started
    /// from the full list, since that's a separate presented sheet.
    @State private var editingFavorite: FavoritePlace?
    @State private var aroundMe = AroundMeViewModel()
    @AppStorage("com.danielguzman.waypoint.hasDismissedVoiceSearchTip") private var hasDismissedTip = false

    enum HomeList: String, Identifiable {
        case places, recents
        var id: String { rawValue }
        var title: String { self == .places ? "Places" : "Recents" }
    }

    var body: some View {
        VStack(spacing: 0) {
            if directionsViewModel.isActive {
                DirectionsCard(
                    viewModel: directionsViewModel,
                    detent: $detent,
                    contentHeight: $directionsHeight,
                    onClose: { directionsViewModel.stop() },
                    onStartNavigation: { route in onStartNavigation(route) },
                    onAddStop: { isAddingDirectionsStop = true },
                    onShowSteps: onShowSteps
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if let selected = viewModel.selectedResult, !isSearching {
                PlaceDetailContent(
                    result: selected,
                    currentLocation: currentLocation,
                    directionsViewModel: directionsViewModel,
                    favoritesStore: viewModel.favoritesStore
                ) {
                    viewModel.clearSelection()
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                // The sheet's own background is the outer container (same as Apple Maps), so the
                // field and avatar sit directly on it — adding another glass layer here would
                // show as a second banner behind the bar.
                HStack(spacing: 8) {
                    searchField
                    if isSearching {
                        Button {
                            isFieldFocused = false
                            isSearching = false
                            isAddingFavorite = false
                            viewModel.queryText = ""
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.primary)
                                .frame(width: 32, height: 32)
                                .background(.regularMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("cancelSearchButton")
                    } else {
                        profileButton
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { newValue in
                    // Hug the bar: just the row plus its own padding, no trailing dead space.
                    collapsedHeight = newValue + 8
                }

                if isSearching {
                    List {
                        if viewModel.queryText.isEmpty {
                            tipSection
                            placesSection
                            categoriesSection
                            recentsSection
                            DiscoverSections(
                                discover: viewModel.discover,
                                currentLocation: currentLocation
                            ) { place in
                                selectDiscover(place)
                            }
                            GuidesSection(
                                guides: viewModel.guides,
                                currentLocation: currentLocation
                            ) { place in
                                selectDiscover(place)
                            }
                        } else {
                            suggestionsSection
                        }
                    }
                    .listStyle(.plain)
                    // Scrolling puts the keyboard away so you can read results, but the search
                    // page itself stays up until you pick something or close it.
                    .scrollDismissesKeyboard(.immediately)
                } else {
                    homeContent
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(.smooth(duration: 0.3), value: directionsViewModel.isActive)
        .animation(.smooth(duration: 0.3), value: viewModel.selectedResult)
        .animation(.smooth(duration: 0.3), value: isSearching)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { newValue in
            sheetHeight = newValue
        }
        .onChange(of: isFieldFocused) { _, focused in
            // Gaining focus enters search mode; losing it (e.g. from scrolling) does not leave it.
            guard focused else { return }
            isSearching = true
            detent = .large
            viewModel.loadDiscover()
        }
        // The place card rests at the same partial height as the home card — Apple Maps reuses
        // the one middle stop for both, so a single pull from either goes to full screen.
        .onChange(of: isSearching) { _, searching in
            if !searching { detent = .home }
        }
        .onChange(of: viewModel.selectedResult) { _, _ in
            detent = .home
        }
        .onChange(of: directionsViewModel.isActive) { _, active in
            // Content height isn't measured yet on the very first frame the card appears, so
            // .medium is a reasonable placeholder until DirectionsCard reports its real height
            // and this re-fires — the .height(directionsHeight) below then takes over.
            if active { detent = directionsViewModel.mode == .transit ? .large : .medium }
        }
        .onChange(of: directionsViewModel.mode) { _, newMode in
            guard directionsViewModel.isActive else { return }
            // Transit shows a scrollable list of options, so give it room; other modes size to
            // the card's own measured content instead of a fixed fraction of the screen.
            detent = newMode == .transit ? .large : .height(directionsHeight)
        }
        .onChange(of: directionsHeight) { _, newValue in
            guard directionsViewModel.isActive, directionsViewModel.mode != .transit, detent != .large else { return }
            detent = .height(newValue)
        }
        .onChange(of: viewModel.speechService.transcript) { _, newValue in
            guard viewModel.speechService.isRecording else { return }
            viewModel.queryText = newValue
        }
        .sheet(isPresented: $isShowingProfile) {
            ProfilePlaceholderSheet()
        }
        .sheet(item: $expandedList) { list in
            SavedListSheet(
                list: list,
                favorites: viewModel.favoritesStore.favorites,
                recents: viewModel.recentsStore.recents,
                distanceText: distanceText(to:),
                onSelectFavorite: { favorite in
                    expandedList = nil
                    select(favorite: favorite)
                },
                onSelectRecent: { recent in
                    expandedList = nil
                    select(recent: recent)
                },
                onRemoveFavorite: { viewModel.favoritesStore.remove($0) },
                onRemoveRecent: { viewModel.recentsStore.remove($0) },
                onUpdateFavorite: { favorite, title, emoji, colorHex in
                    viewModel.favoritesStore.update(favorite, title: title, emoji: emoji, colorHex: colorHex)
                }
            )
        }
        .sheet(item: $editingFavorite) { favorite in
            EditFavoriteSheet(favorite: favorite) { title, emoji, colorHex in
                viewModel.favoritesStore.update(favorite, title: title, emoji: emoji, colorHex: colorHex)
            }
        }
        .sheet(isPresented: $isAddingDirectionsStop) {
            AddStopSheet(currentRegion: originRegionForAddStop) { item in
                directionsViewModel.addStop(item)
            }
        }
    }

    // MARK: - Home card (no search, nothing selected)

    /// What the card shows at rest: Places, Recents, and your saved collection. Scrolling it
    /// pulls the sheet up to full height, exactly like Apple Maps' home card.
    private var homeContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                placesRow
                aroundMeSection
                if !viewModel.recentsStore.recents.isEmpty {
                    recentsCard
                }
                favoritesCollection
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 36)
        }
        .scrollIndicators(.hidden)
    }

    private func sectionHeader(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var placesRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Places") { expandedList = .places }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(viewModel.favoritesStore.favorites) { favorite in
                        PlaceCircle(
                            title: favorite.displayTitle,
                            subtitle: distanceText(to: favorite.coordinate),
                            symbol: PlaceCategoryIcon.icon(for: favorite.title).symbol,
                            tint: Color(hex: favorite.colorHex) ?? PlaceCategoryIcon.icon(for: favorite.title).color,
                            emoji: favorite.emoji,
                            onEdit: { editingFavorite = favorite }
                        ) {
                            select(favorite: favorite)
                        }
                    }
                    PlaceCircle(
                        title: "Add",
                        subtitle: nil,
                        symbol: "plus",
                        tint: .secondary,
                        isPlaceholder: true
                    ) {
                        isAddingFavorite = true
                        isSearching = true
                        isFieldFocused = true
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
        }
    }

    /// Quick-category shortcuts (Gas, Food, EV Charging) — tapping one runs a real Google
    /// Places Nearby Search around the user's current location and expands into a result strip,
    /// rather than just filling the search query like the pills inside the results list do.
    private var aroundMeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeaderText("Around Me")
            HStack(spacing: 10) {
                ForEach(AroundMeViewModel.Category.allCases) { category in
                    AroundMeChip(
                        category: category,
                        isSelected: aroundMe.selectedCategory == category
                    ) {
                        guard let coordinate = currentLocation?.coordinate else { return }
                        aroundMe.select(category, near: coordinate)
                    }
                }
            }
            if let category = aroundMe.selectedCategory {
                aroundMeResults(for: category)
            }
        }
    }

    @ViewBuilder
    private func aroundMeResults(for category: AroundMeViewModel.Category) -> some View {
        if aroundMe.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
        } else if let errorMessage = aroundMe.errorMessage {
            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if aroundMe.results.isEmpty {
            Text("No \(category.title.lowercased()) found nearby.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(aroundMe.results) { place in
                        AroundMeResultCard(
                            place: place,
                            imageURL: aroundMe.photoURL(for: place),
                            distanceText: place.coordinate.map { distanceText(to: $0) ?? "" }
                        ) {
                            selectDiscover(place)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
        }
    }

    private func sectionHeaderText(_ title: String) -> some View {
        Text(title)
            .font(.title3.weight(.bold))
            .foregroundStyle(.primary)
    }

    private var recentsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Recents") { expandedList = .recents }
            let shown = Array(viewModel.recentsStore.recents.prefix(3))
            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, recent in
                    HomeRecentRow(recent: recent) {
                        select(recent: recent)
                    } onRemove: {
                        viewModel.recentsStore.remove(recent)
                    }
                    if index < shown.count - 1 {
                        Divider().padding(.leading, 56)
                    }
                }
            }
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    /// Waypoint's equivalent of Apple's "Your Guides": the places you've saved on this device.
    private var favoritesCollection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Your Places") { expandedList = .places }
            Button {
                expandedList = .places
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 62))
                        .foregroundStyle(.yellow.gradient)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Favorites")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(favoritesCountText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .frame(width: 190, height: 190, alignment: .bottomLeading)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("yourPlacesTile")
        }
    }

    private var favoritesCountText: String {
        let count = viewModel.favoritesStore.favorites.count
        return count == 1 ? "1 place" : "\(count) places"
    }

    /// Straight-line distance — honest about what it is: it's not a routed driving distance.
    private func distanceText(to coordinate: CLLocationCoordinate2D) -> String? {
        guard let currentLocation else { return nil }
        let meters = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            .distance(from: currentLocation)
        return Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(isAddingFavorite ? "Search to Add Favorite" : "Search Maps", text: $viewModel.queryText)
                .focused($isFieldFocused)
                .submitLabel(.search)
                .accessibilityIdentifier("searchField")
            if !viewModel.queryText.isEmpty {
                Button {
                    viewModel.queryText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                Task { await viewModel.toggleVoiceSearch() }
            } label: {
                Image(systemName: viewModel.speechService.isRecording ? "mic.fill" : "mic")
                    .foregroundStyle(viewModel.speechService.isRecording ? Color.red : Color.secondary)
            }
            .accessibilityIdentifier("micButton")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassEffect(.regular.interactive(), in: Capsule())
        // The glass capsule's own interactive touch-tracking wins the first tap for its press
        // animation, so the TextField only picks up first-responder on a second tap. A
        // simultaneous gesture fires alongside that (never blocking it) and sets focus directly,
        // so the keyboard appears on the very first tap.
        .simultaneousGesture(TapGesture().onEnded { isFieldFocused = true })
    }

    private var originRegionForAddStop: MKCoordinateRegion? {
        guard let coordinate = currentLocation?.coordinate else { return nil }
        return MKCoordinateRegion(center: coordinate, latitudinalMeters: 8000, longitudinalMeters: 8000)
    }

    private var profileButton: some View {
        Button {
            isShowingProfile = true
        } label: {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityIdentifier("profileButton")
    }

    @ViewBuilder
    private var tipSection: some View {
        if !hasDismissedTip {
            Section {
                TipCard(
                    symbol: "mic.fill",
                    title: "Try Voice Search",
                    message: "Tap the microphone in the search bar to search hands-free."
                ) {
                    hasDismissedTip = true
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private var placesSection: some View {
        let canAddSelection = viewModel.selectedResult.map { !viewModel.favoritesStore.isFavorite($0) } ?? false
        if !viewModel.favoritesStore.favorites.isEmpty || canAddSelection {
            Section("Places") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(viewModel.favoritesStore.favorites) { favorite in
                            FavoriteCircle(favorite: favorite, onEdit: { editingFavorite = favorite }) {
                                select(favorite: favorite)
                            }
                        }
                        if let selected = viewModel.selectedResult, canAddSelection {
                            AddFavoriteCircle {
                                viewModel.favoritesStore.toggle(selected)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
            }
        }
    }

    private var categoriesSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(categories, id: \.title) { category in
                        Button {
                            viewModel.queryText = category.query
                        } label: {
                            HStack(spacing: 6) {
                                Text(category.emoji).font(.subheadline)
                                Text(category.title).font(.subheadline.weight(.semibold))
                            }
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.quaternary.opacity(0.8), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    /// Apple's Recents shelf: a grouped rounded card holding two rows, paging sideways through
    /// the rest — not a flat full-length list.
    private var recentsSection: some View {
        if !viewModel.recentsStore.recents.isEmpty {
            let pages = stride(from: 0, to: viewModel.recentsStore.recents.count, by: 2).map {
                Array(viewModel.recentsStore.recents[$0..<min($0 + 2, viewModel.recentsStore.recents.count)])
            }
            Section(header: SectionHeader(title: "Recents", showsChevron: true)) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(pages.enumerated()), id: \.offset) { _, page in
                            VStack(spacing: 0) {
                                ForEach(Array(page.enumerated()), id: \.element.id) { index, recent in
                                    RecentRow(recent: recent) {
                                        select(recent: recent)
                                    } onRemove: {
                                        viewModel.recentsStore.remove(recent)
                                    }
                                    if index < page.count - 1 {
                                        Divider().padding(.leading, 52)
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
        }
    }

    private var suggestionsSection: some View {
        Section {
            ForEach(Array(viewModel.suggestions.enumerated()), id: \.element.title) { index, suggestion in
                if index == 0 {
                    TopSuggestionCard(
                        suggestion: suggestion,
                        onSelect: { Task { await select(suggestion: suggestion) } },
                        onDirections: { Task { await selectAndRouteToDirections(suggestion: suggestion) } }
                    )
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                    .listRowSeparator(.hidden)
                } else {
                    Button {
                        Task { await select(suggestion: suggestion) }
                    } label: {
                        SuggestionRow(suggestion: suggestion)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func handleSelectionForFavorites() {
        if isAddingFavorite, let result = viewModel.selectedResult {
            viewModel.favoritesStore.toggle(result)
            isAddingFavorite = false
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    private func select(suggestion: MKLocalSearchCompletion) async {
        isFieldFocused = false
        isSearching = false
        await viewModel.select(suggestion)
        handleSelectionForFavorites()
    }

    /// Resolves the suggestion, then jumps straight to directions — the one-tap "Directions"
    /// pill under the top search result, matching Apple Maps.
    private func selectAndRouteToDirections(suggestion: MKLocalSearchCompletion) async {
        isFieldFocused = false
        isSearching = false
        await viewModel.select(suggestion)
        guard let result = viewModel.selectedResult else { return }
        directionsViewModel.start(destination: result.mapItem, from: currentLocation)
    }

    private func select(recent: RecentSearch) {
        isFieldFocused = false
        isSearching = false
        viewModel.selectRecent(recent)
    }

    private func select(favorite: FavoritePlace) {
        isFieldFocused = false
        isSearching = false
        viewModel.selectFavorite(favorite)
    }

    private func selectDiscover(_ place: DetailedPlace) {
        isFieldFocused = false
        isSearching = false
        viewModel.selectDiscover(place)
        handleSelectionForFavorites()
    }
}

// MARK: - Home card pieces

/// One circle in the Places row: a big tinted disc, the place name, and how far away it is.
private struct PlaceCircle: View {
    let title: String
    let subtitle: String?
    let symbol: String
    let tint: Color
    var emoji: String? = nil
    var isPlaceholder = false
    var onEdit: (() -> Void)? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    if isPlaceholder {
                        Circle()
                            .strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [5]))
                    } else {
                        Circle().fill(tint.gradient)
                    }
                    if let emoji, !emoji.isEmpty {
                        Text(emoji).font(.system(size: 28))
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(isPlaceholder ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(.white))
                    }
                }
                .frame(width: 68, height: 68)

                Text(title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 78)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let onEdit {
                Button(action: onEdit) {
                    Label("Edit", systemImage: "pencil")
                }
            }
        }
    }
}

/// A row inside the grouped Recents card on the home sheet.
private struct HomeRecentRow: View {
    let recent: RecentSearch
    let onSelect: () -> Void
    let onRemove: () -> Void

    var body: some View {
        let icon = PlaceCategoryIcon.icon(for: recent.title)
        HStack(spacing: 12) {
            Button(action: onSelect) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(icon.color.gradient).frame(width: 32, height: 32)
                        Image(systemName: icon.symbol)
                            .font(.caption)
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(recent.title)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if !recent.subtitle.isEmpty {
                            Text(recent.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button(role: .destructive, action: onRemove) {
                    Label("Remove", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// The full list behind a section header's chevron — every saved place or every recent.
private struct SavedListSheet: View {
    let list: SearchSheet.HomeList
    let favorites: [FavoritePlace]
    let recents: [RecentSearch]
    let distanceText: (CLLocationCoordinate2D) -> String?
    let onSelectFavorite: (FavoritePlace) -> Void
    let onSelectRecent: (RecentSearch) -> Void
    let onRemoveFavorite: (FavoritePlace) -> Void
    let onRemoveRecent: (RecentSearch) -> Void
    let onUpdateFavorite: (FavoritePlace, String, String?, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var editingFavorite: FavoritePlace?

    var body: some View {
        NavigationStack {
            List {
                switch list {
                case .places:
                    if favorites.isEmpty {
                        emptyState("No saved places yet", detail: "Tap the star on any place to save it here.")
                    }
                    ForEach(favorites) { favorite in
                        Button {
                            onSelectFavorite(favorite)
                        } label: {
                            row(
                                title: favorite.displayTitle,
                                subtitle: distanceText(favorite.coordinate) ?? favorite.subtitle,
                                emoji: favorite.emoji,
                                colorOverride: Color(hex: favorite.colorHex)
                            )
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) { onRemoveFavorite(favorite) } label: {
                                Label("Remove", systemImage: "trash")
                            }
                            Button { editingFavorite = favorite } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                    }
                case .recents:
                    if recents.isEmpty {
                        emptyState("No recents yet", detail: "Places you look up show up here.")
                    }
                    ForEach(recents) { recent in
                        Button {
                            onSelectRecent(recent)
                        } label: {
                            row(title: recent.title, subtitle: recent.subtitle)
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) { onRemoveRecent(recent) } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle(list.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .sheet(item: $editingFavorite) { favorite in
            EditFavoriteSheet(favorite: favorite) { title, emoji, colorHex in
                onUpdateFavorite(favorite, title, emoji, colorHex)
            }
        }
    }

    private func row(title: String, subtitle: String, emoji: String? = nil, colorOverride: Color? = nil) -> some View {
        let icon = PlaceCategoryIcon.icon(for: title)
        return HStack(spacing: 12) {
            ZStack {
                Circle().fill((colorOverride ?? icon.color).gradient).frame(width: 34, height: 34)
                if let emoji, !emoji.isEmpty {
                    Text(emoji).font(.caption)
                } else {
                    Image(systemName: icon.symbol).font(.caption).foregroundStyle(.white)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).foregroundStyle(.primary)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func emptyState(_ title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .listRowSeparator(.hidden)
    }
}

/// The elevated top-match card shown above the rest of the results — icon, name, address, and
/// quick-action pills (Directions) beneath, matching Apple Maps' search results layout.
private struct TopSuggestionCard: View {
    let suggestion: MKLocalSearchCompletion
    let onSelect: () -> Void
    let onDirections: () -> Void

    var body: some View {
        let icon = PlaceCategoryIcon.icon(for: suggestion.title)
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onSelect) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(icon.color.opacity(0.2))
                            .frame(width: 40, height: 40)
                        Image(systemName: icon.symbol)
                            .font(.subheadline)
                            .foregroundStyle(icon.color)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(suggestion.title)
                            .font(.body.weight(.semibold))
                        if !suggestion.subtitle.isEmpty {
                            Text(suggestion.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)

            Button(action: onDirections) {
                Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.glass)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }
}

private struct SuggestionRow: View {
    let suggestion: MKLocalSearchCompletion

    var body: some View {
        let icon = PlaceCategoryIcon.icon(for: suggestion.title)
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(icon.color.opacity(0.2))
                    .frame(width: 36, height: 36)
                Image(systemName: icon.symbol)
                    .font(.subheadline)
                    .foregroundStyle(icon.color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.title)
                    .font(.body)
                if !suggestion.subtitle.isEmpty {
                    Text(suggestion.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct RecentRow: View {
    let recent: RecentSearch
    let onSelect: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSelect) {
                HStack(spacing: 12) {
                    // Apple marks recent *searches* with a magnifying glass, not a clock.
                    Image(systemName: "magnifyingglass")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                    // Title and locality sit on one line there — "Half Moon · New York".
                    HStack(spacing: 4) {
                        Text(recent.title)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if !recent.subtitle.isEmpty {
                            Text("· \(recent.subtitle)")
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Menu {
                Button(role: .destructive, action: onRemove) {
                    Label("Remove", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
        }
        // Inside a grouped card now, so the row owns its own insets — Apple's rows breathe
        // considerably more than the default List spacing did.
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
    }
}

private struct TipCard: View {
    let symbol: String
    let title: String
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
    }
}

private struct AroundMeChip: View {
    let category: AroundMeViewModel.Category
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: category.symbol)
                Text(category.title)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(isSelected ? .white : .primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary.opacity(0.6)),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("aroundMeCategory-\(category.rawValue)")
    }
}

private struct AroundMeResultCard: View {
    let place: DetailedPlace
    let imageURL: URL?
    let distanceText: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.6))
                    if let imageURL {
                        GooglePhotoImage(url: imageURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.clear
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        Image(systemName: "mappin.circle.fill").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 3) {
                    Text(place.displayName?.text ?? "Place")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if let rating = place.rating {
                            Image(systemName: "star.fill").font(.caption2).foregroundStyle(.orange)
                            Text(String(format: "%.1f", rating)).font(.caption).foregroundStyle(.secondary)
                        }
                        if let distanceText {
                            if place.rating != nil { Text("·").font(.caption).foregroundStyle(.secondary) }
                            Text(distanceText).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 140, alignment: .leading)
            }
            .padding(10)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("aroundMeResult-\(place.id)")
    }
}

private struct FavoriteCircle: View {
    let favorite: FavoritePlace
    var onEdit: (() -> Void)? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Circle()
                    .fill((Color(hex: favorite.colorHex) ?? .indigo).gradient)
                    .frame(width: 44, height: 44)
                    .overlay {
                        if let emoji = favorite.emoji, !emoji.isEmpty {
                            Text(emoji).font(.callout)
                        } else {
                            Text(favorite.title.prefix(1))
                                .font(.headline)
                                .foregroundStyle(.white)
                        }
                    }
                Text(favorite.displayTitle)
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(width: 60)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let onEdit {
                Button(action: onEdit) {
                    Label("Edit", systemImage: "pencil")
                }
            }
        }
    }
}

private struct AddFavoriteCircle: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Circle()
                    .strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [4]))
                    .frame(width: 44, height: 44)
                    .overlay {
                        Image(systemName: "plus")
                            .foregroundStyle(.secondary)
                    }
                Text("Add")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("addFavoriteButton")
    }
}

private struct ProfilePlaceholderSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let diagnostics = CrashReportingService.shared

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.secondary)
                        Text("Accounts aren't built yet")
                            .font(.headline)
                        Text("Sign-in isn't available yet, but Favorites and Recents already sync across your devices via iCloud — no account needed for that part.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .listRowSeparator(.hidden)
                }

                diagnosticsSection

                Section {
                    Text("Waypoint v\(appVersion)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var diagnosticsSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: lastRunSymbol)
                    .foregroundStyle(lastRunTint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last Session").font(.subheadline.weight(.medium))
                    Text(lastRunDescription).font(.caption).foregroundStyle(.secondary)
                }
            }

            if diagnostics.reports.isEmpty {
                Text("No crash or hang reports recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(diagnostics.reports) { report in
                    HStack(spacing: 10) {
                        Image(systemName: report.kind.symbol).foregroundStyle(.red).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(report.kind.label).font(.subheadline.weight(.medium))
                            Text(report.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text("\(report.date.formatted(date: .abbreviated, time: .shortened)) · v\(report.appVersion) · iOS \(report.osVersion)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Button("Clear Reports", role: .destructive) { diagnostics.clearReports() }
                    .font(.caption)
            }

            if !diagnostics.isDetailedReportingAvailable {
                Text("Detailed crash/hang diagnostics need iOS 27 or later. The last-session status above still works on this OS version.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Collected on-device via MetricKit — nothing is sent off this phone.")
        }
    }

    private var lastRunSymbol: String {
        switch diagnostics.lastRunEndedCleanly {
        case .some(true): "checkmark.circle.fill"
        case .some(false): "exclamationmark.triangle.fill"
        case nil: "questionmark.circle"
        }
    }

    private var lastRunTint: Color {
        switch diagnostics.lastRunEndedCleanly {
        case .some(true): .green
        case .some(false): .orange
        case nil: .secondary
        }
    }

    private var lastRunDescription: String {
        switch diagnostics.lastRunEndedCleanly {
        case .some(true): "Ended normally"
        case .some(false): "Didn't shut down normally — may have crashed or been force-quit"
        case nil: "Not enough history yet"
        }
    }
}
