import CoreLocation
import MapKit
import OSLog
import SwiftUI

// Emoji matched against Apple Maps' own category pills rather than picked for looking
// food-adjacent. `types` are Google Places (New) place types, each verified against the live API
// rather than guessed — the pills *browse* by type the way Apple's do, instead of pushing the
// word through autocomplete. `symbol` is what the results' map pins wear.
private let categories: [(title: String, emoji: String, symbol: String, types: [String])] = [
    ("Restaurants", "🍴", "fork.knife", ["restaurant"]),
    ("Fast Food", "🥪", "takeoutbag.and.cup.and.straw.fill", ["fast_food_restaurant"]),
    ("Gas Stations", "⛽", "fuelpump.fill", ["gas_station"]),
    ("Coffee", "☕", "cup.and.saucer.fill", ["coffee_shop"]),
    ("Groceries", "🛒", "cart.fill", ["supermarket"]),
    ("Movies", "🍿", "popcorn.fill", ["movie_theater"]),
]

extension PresentationDetent {
    /// Where the card rests when the app opens: search bar, the Places row, and the top of
    /// Recents — the same partial height Apple Maps starts at before you pull it up.
    static let home = PresentationDetent.fraction(0.47)

    /// Where the directions card rests. A fixed fraction rather than a measured content height:
    /// a detent whose value moves makes the whole detent set unstable and breaks the drag.
    ///
    /// Sized to the content, not guessed: header ~80 + mode picker ~46 + endpoints ~138 +
    /// route pager 140 + spacing ~24 ≈ 428pt, against ~440pt at 0.46 on a Pro Max.
    ///
    /// The pager needs ~30pt more than the route card itself, because a TabView reserves that
    /// much of its frame for the page indicator. Sizing it to the card alone clips the card's
    /// top corners.
    ///
    /// This is close to the floor. The rows and route card can't shrink much further without
    /// looking cramped, so moving the card lower again means finding the height somewhere else
    /// rather than trimming these again.
    ///
    /// The previous pass had this at 0.50 with ~500pt of content, which overflowed and clipped
    /// the "Directions" header off the top of the card — the content is top aligned, so an
    /// overflow eats the header first.
    ///
    /// A shorter sheet is what moves the whole stack *down* the screen — the content is top
    /// aligned, so lowering the card's top edge carries the mode picker, endpoints and route
    /// card down with it. Shrink the content first if you shrink this further; going tighter
    /// without that clips the route card and drops the page dots onto it.
    static let directionsRest = PresentationDetent.fraction(0.46)
}

struct SearchSheet: View {
    @Bindable var viewModel: SearchViewModel
    @Bindable var directionsViewModel: DirectionsViewModel
    let currentLocation: CLLocation?
    @Binding var detent: PresentationDetent
    @Binding var collapsedHeight: CGFloat
    @Binding var directionsHeight: CGFloat
    /// Swaps the directions card for the stop-picker in place — see `AddStopSheet` for why this
    /// isn't a nested sheet, and MapScreen for why the state lives up there.
    @Binding var isAddingStop: Bool
    let onStartNavigation: (RouteOption) -> Void
    /// Bubbled up to MapScreen, which owns the actual sheet presentation — see the comment on
    /// DirectionsCard's matching properties for why this can't be presented from in here.
    let onShowSteps: (RouteOption) -> Void
    @FocusState private var isFieldFocused: Bool
    /// Every sheet this view presents, as one value — see the `.sheet(item:)` below for why.
    enum ActiveSheet: Identifiable {
        case profile
        case savedList(HomeList)
        case editFavorite(FavoritePlace)
        case guideDetail(GuidesViewModel.Guide)
        case cityGuideDetail(CityGuidesViewModel.CityGuide)

        var id: String {
            switch self {
            case .profile: "profile"
            case .savedList(let list): "list-\(list.id)"
            case .editFavorite(let favorite): "favorite-\(favorite.id)"
            case .guideDetail(let guide): "guide-\(guide.id)"
            case .cityGuideDetail(let city): "city-\(city.id)"
            }
        }
    }

    @State private var activeSheet: ActiveSheet?

    /// Stays true for the whole search session — scrolling dismisses the keyboard but must NOT
    /// drop you back to the map, so the results list is driven by this, not by keyboard focus.
    @State private var isSearching = false
    @State private var isAddingFavorite = false
    /// Which "see all" list the user opened from a section header chevron.
    /// The favorite currently open in the rename/emoji/color editor, from either the home row
    /// or a search-results circle — `SavedListSheet` has its own copy of this for edits started
    /// from the full list, since that's a separate presented sheet.
    @State private var aroundMe = AroundMeViewModel()
    @AppStorage("com.danielguzman.waypoint.hasDismissedVoiceSearchTip") private var hasDismissedTip = false

    enum HomeList: String, Identifiable {
        case places, recents
        var id: String { rawValue }
        var title: String { self == .places ? "Places" : "Recents" }
    }

    var body: some View {
        VStack(spacing: 0) {
            if directionsViewModel.isActive, isAddingStop {
                AddStopSheet(
                    currentRegion: originRegionForAddStop,
                    onCancel: { isAddingStop = false }
                ) { item in
                    directionsViewModel.addStop(item)
                    isAddingStop = false
                }
                .frame(maxHeight: .infinity)
            } else if directionsViewModel.isActive {
                DirectionsCard(
                    viewModel: directionsViewModel,
                    detent: $detent,
                    contentHeight: $directionsHeight,
                    onClose: { directionsViewModel.stop() },
                    onStartNavigation: { route in onStartNavigation(route) },
                    onAddStop: {
                        // Needs the full sheet height to be usable as a search screen.
                        detent = .large
                        isAddingStop = true
                    },
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
                            viewModel.clearCategory()
                            viewModel.queryText = ""
                        } label: {
                            Image(systemName: "xmark")
                                .scaledFont(size: 15, weight: .bold, relativeTo: .subheadline)
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
                // Measured against Apple's card on the same device: their field is inset further
                // from the card edges than ours was, which is what made ours read as wider and
                // more crowded.
                .padding(.horizontal, 16)
                // Enough room for the sheet's drag indicator to clear the field. Measured at
                // ~70px on Apple's card, ~66px on ours — this is already right, so it stays.
                .padding(.top, 16)
                .padding(.bottom, 10)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { newValue in
                    // Hug the bar: just the row plus its own padding, no trailing dead space.
                    // Measured against Apple's collapsed bar, which sits ~12pt shorter than ours
                    // did — the extra slack here was most of that difference.
                    collapsedHeight = newValue + 2
                }

                if isSearching {
                    List {
                        if viewModel.activeCategory != nil {
                            categoryResultsSection
                        } else if viewModel.queryText.isEmpty {
                            tipSection
                            recentsSection
                            DiscoverSections(
                                discover: viewModel.discover,
                                currentLocation: currentLocation
                            ) { place in
                                selectDiscover(place)
                            }
                            GuidesSection(guides: viewModel.guides) { guide in
                                activeSheet = .guideDetail(guide)
                            }
                            CityGuidesSection(cityGuides: viewModel.cityGuides) { city in
                                activeSheet = .cityGuideDetail(city)
                            }
                        } else {
                            suggestionsSection
                        }
                    }
                    .listStyle(.plain)
                    .safeAreaInset(edge: .top, spacing: 0) { categoriesBar }
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
        // Typing anything other than the category's own name means the user has moved on from
        // browsing that category, so the results give way to normal search suggestions.
        .onChange(of: viewModel.queryText) { _, newValue in
            if let active = viewModel.activeCategory, newValue != active {
                viewModel.clearCategory()
            }
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
            // Every mode rests at the same stop now. Transit used to be forced to `.large` here
            // on the theory that its list needed room, but that made picking transit slam the
            // card to full screen instead of resting like driving does — the list scrolls
            // inside the card, so it doesn't need the whole screen.
            if active { detent = .directionsRest }
        }
        .onChange(of: directionsViewModel.mode) { _, _ in
            guard directionsViewModel.isActive else { return }
            // Switching modes keeps the card where it is unless it's parked at the collapsed
            // stop, in which case bring it back to the resting height so the routes are visible.
            if detent != .large, detent != .directionsRest {
                detent = .directionsRest
            }
        }
        .onChange(of: viewModel.speechService.transcript) { _, newValue in
            guard viewModel.speechService.isRecording else { return }
            viewModel.queryText = newValue
        }
        // One `.sheet` per view. Four chained here meant SwiftUI only reliably honoured one of
        // them, which is why "Add Stop" opened nothing — it was the last in the chain and lost to
        // the ones above it. Routing every sheet through a single enum removes the conflict.
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .profile:
                ProfilePlaceholderSheet()
            case .savedList(let list):
                SavedListSheet(
                    list: list,
                    favorites: viewModel.favoritesStore.favorites,
                    recents: viewModel.recentsStore.recents,
                    distanceText: distanceText(to:),
                    onSelectFavorite: { favorite in
                        activeSheet = nil
                        select(favorite: favorite)
                    },
                    onSelectRecent: { recent in
                        activeSheet = nil
                        select(recent: recent)
                    },
                    onRemoveFavorite: { viewModel.favoritesStore.remove($0) },
                    onRemoveRecent: { viewModel.recentsStore.remove($0) },
                    onUpdateFavorite: { favorite, title, emoji, colorHex in
                        viewModel.favoritesStore.update(favorite, title: title, emoji: emoji, colorHex: colorHex)
                    }
                )
            case .editFavorite(let favorite):
                EditFavoriteSheet(favorite: favorite) { title, emoji, colorHex in
                    viewModel.favoritesStore.update(favorite, title: title, emoji: emoji, colorHex: colorHex)
                }
            case .guideDetail(let guide):
                PlaceListDetailSheet(
                    title: guide.title,
                    footer: "Assembled from the highest-rated nearby places on Google — not an editorial guide.",
                    places: guide.places,
                    photoURL: { viewModel.guides.photoURL(for: $0, maxWidthPx: 200) },
                    currentLocation: currentLocation,
                    onSelect: { place in
                        activeSheet = nil
                        selectDiscover(place)
                    },
                    onDismiss: { activeSheet = nil }
                )
            case .cityGuideDetail(let city):
                PlaceListDetailSheet(
                    title: city.name,
                    footer: "Top-rated attractions in \(city.name) on Google — not an editorial guide.",
                    places: city.places,
                    photoURL: { viewModel.cityGuides.photoURL(for: $0, maxWidthPx: 200) },
                    currentLocation: currentLocation,
                    onSelect: { place in
                        activeSheet = nil
                        selectDiscover(place)
                    },
                    onDismiss: { activeSheet = nil }
                )
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
                // No "Around Me" here — Apple's home card is just Places and Recents, and the
                // category shortcuts already live in the pinned pill row once you start a search.
                if !viewModel.recentsStore.recents.isEmpty {
                    recentsCard
                }
                favoritesCollection
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            // Just enough that the last row clears the rounded corner — no safe-area inset here,
            // the card is already lifted off the screen edge and stacking both left an empty
            // band of glass below the content.
            .padding(.bottom, 14)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
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
            sectionHeader("Places") { activeSheet = .savedList(.places) }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(viewModel.favoritesStore.favorites) { favorite in
                        PlaceCircle(
                            title: favorite.displayTitle,
                            subtitle: distanceText(to: favorite.coordinate),
                            symbol: PlaceCategoryIcon.icon(for: favorite.title).symbol,
                            tint: Color(hex: favorite.colorHex) ?? PlaceCategoryIcon.icon(for: favorite.title).color,
                            emoji: favorite.emoji,
                            onEdit: { activeSheet = .editFavorite(favorite) }
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
                            Haptics.select()
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
            sectionHeader("Recents") { activeSheet = .savedList(.recents) }
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
            sectionHeader("Your Places") { activeSheet = .savedList(.places) }
            Button {
                activeSheet = .savedList(.places)
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Image(systemName: "star.fill")
                        .scaledFont(size: 62, relativeTo: .largeTitle)
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
    /// What a category pill shows instead of autocomplete suggestions: the real nearby places
    /// of that type, in the same row style the Suggested Places shelf uses.
    @ViewBuilder
    private var categoryResultsSection: some View {
        if viewModel.isLoadingCategory {
            Section {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .listRowSeparator(.hidden)
            }
        } else if let message = viewModel.categoryErrorMessage {
            Section {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 28)
                    .listRowSeparator(.hidden)
            }
        } else {
            Section {
                ForEach(viewModel.categoryResults) { place in
                    SuggestedRow(
                        place: place,
                        imageURL: viewModel.photoURL(forCategoryResult: place),
                        distance: place.coordinate.flatMap { distanceText(to: $0) }
                    ) {
                        Haptics.select()
                        selectDiscover(place)
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                    .listRowSeparator(.hidden)
                }
            }
        }
    }

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
            activeSheet = .profile
        } label: {
            Image(systemName: "person.crop.circle.fill")
                .scaledFont(size: 32, relativeTo: .title)
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

    /// The category pills, pinned above the results rather than scrolling away with them.
    ///
    /// Apple keeps this row fixed under the search field and lets the whole list travel
    /// underneath it — that pass-under is the entire point of the glass, since there's nothing
    /// to refract if the row scrolls in lockstep with the content behind it. Attached with
    /// `.safeAreaInset`, which pins the row *and* insets the scroll content so the first section
    /// isn't stuck behind it.
    private var categoriesBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // Each pill had its own isolated `.glassEffect`, sampling only its own sliver of
            // whatever scrolled underneath — next to Apple's version, which blends the whole
            // row into one glass surface, ours read as flat, barely-tinted capsules instead of
            // catching color off the content passing beneath. A shared `GlassEffectContainer`,
            // with enough spacing for neighboring pills to actually read as connected, is what
            // makes them merge into one continuous piece of glass instead of six separate ones.
            GlassEffectContainer(spacing: 14) {
                HStack(spacing: 10) {
                    ForEach(categories, id: \.title) { category in
                        Button {
                            Haptics.tap()
                            isFieldFocused = false
                            viewModel.browseCategory(
                                title: category.title,
                                symbol: category.symbol,
                                includedTypes: category.types,
                                near: currentLocation?.coordinate
                            )
                        } label: {
                            HStack(spacing: 6) {
                                Text(category.emoji).font(.callout)
                                Text(category.title).font(.callout.weight(.semibold))
                            }
                            .foregroundStyle(.primary)
                            // A size step up from Apple's own pills, measured on the same
                            // device — ours were reading noticeably daintier next to theirs.
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .glassEffect(
                                viewModel.activeCategory == category.title
                                    ? .regular.tint(.blue.opacity(0.5)).interactive()
                                    : .regular.interactive(),
                                in: Capsule()
                            )
                        }
                        .buttonStyle(.pressableRow)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .scrollClipDisabled()
    }

    @ViewBuilder
    /// Apple's Recents shelf: a grouped rounded card holding two rows, paging sideways through
    /// the rest — not a flat full-length list.
    private var recentsSection: some View {
        if !viewModel.recentsStore.recents.isEmpty {
            let pages = stride(from: 0, to: viewModel.recentsStore.recents.count, by: 2).map {
                Array(viewModel.recentsStore.recents[$0..<min($0 + 2, viewModel.recentsStore.recents.count)])
            }
            Section {
                SectionHeader(title: "Recents", showsChevron: true)
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
            Haptics.commit()
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
                        Text(emoji).scaledFont(size: 28, relativeTo: .title)
                    } else {
                        Image(systemName: symbol)
                            .scaledFont(size: 28, weight: .semibold, relativeTo: .title)
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
                            .scaledFont(size: 56, relativeTo: .largeTitle)
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
