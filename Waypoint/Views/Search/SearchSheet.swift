import CoreLocation
import MapKit
import SwiftUI

private let categories: [(title: String, symbol: String)] = [
    ("Restaurants", "fork.knife"),
    ("Coffee", "cup.and.saucer.fill"),
    ("Gas", "fuelpump.fill"),
    ("Groceries", "cart.fill"),
    ("Hotels", "bed.double.fill"),
]

struct SearchSheet: View {
    @Bindable var viewModel: SearchViewModel
    @Bindable var directionsViewModel: DirectionsViewModel
    let currentLocation: CLLocation?
    @Binding var detent: PresentationDetent
    @Binding var collapsedHeight: CGFloat
    @Binding var sheetHeight: CGFloat
    @FocusState private var isFieldFocused: Bool
    @State private var isShowingProfile = false
    @AppStorage("com.danielguzman.waypoint.hasDismissedVoiceSearchTip") private var hasDismissedTip = false

    var body: some View {
        VStack(spacing: 0) {
            if directionsViewModel.isActive {
                DirectionsCard(viewModel: directionsViewModel) {
                    directionsViewModel.stop()
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if let selected = viewModel.selectedResult, !isFieldFocused {
                PlaceDetailContent(
                    result: selected,
                    currentLocation: currentLocation,
                    directionsViewModel: directionsViewModel
                ) {
                    viewModel.clearSelection()
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                HStack(spacing: 10) {
                    searchField
                    profileButton
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { newValue in
                    collapsedHeight = newValue + 24
                }

                if isFieldFocused {
                    List {
                        if viewModel.queryText.isEmpty {
                            tipSection
                            placesSection
                            categoriesSection
                            DiscoverSections(discover: viewModel.discover) { place in
                                selectDiscover(place)
                            }
                            nearbySection
                            recentsSection
                        } else {
                            suggestionsSection
                        }
                    }
                    .listStyle(.plain)
                    .scrollDismissesKeyboard(.immediately)
                } else {
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.25), value: directionsViewModel.isActive)
        .animation(.easeInOut(duration: 0.25), value: viewModel.selectedResult)
        .animation(.easeInOut(duration: 0.25), value: isFieldFocused)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { newValue in
            sheetHeight = newValue
        }
        .onChange(of: isFieldFocused) { _, focused in
            detent = focused ? .large : (viewModel.selectedResult == nil ? .height(collapsedHeight) : .medium)
            if focused { viewModel.loadDiscover() }
        }
        .onChange(of: viewModel.selectedResult) { _, newValue in
            detent = newValue == nil ? .height(collapsedHeight) : .medium
        }
        .onChange(of: directionsViewModel.isActive) { _, active in
            if active { detent = .large }
        }
        .onChange(of: viewModel.speechService.transcript) { _, newValue in
            guard viewModel.speechService.isRecording else { return }
            viewModel.queryText = newValue
        }
        .sheet(isPresented: $isShowingProfile) {
            ProfilePlaceholderSheet()
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search Maps", text: $viewModel.queryText)
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
    private var nearbySection: some View {
        if !viewModel.nearbyService.nearbyResults.isEmpty {
            Section("Nearby") {
                ForEach(viewModel.nearbyService.nearbyResults) { result in
                    Button {
                        select(nearby: result)
                    } label: {
                        NearbyRow(result: result)
                    }
                    .buttonStyle(.plain)
                }
            }
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
                            FavoriteCircle(favorite: favorite) {
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
                HStack(spacing: 10) {
                    ForEach(categories, id: \.title) { category in
                        Button {
                            viewModel.queryText = category.title
                        } label: {
                            Label(category.title, systemImage: category.symbol)
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.glass)
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private var recentsSection: some View {
        if !viewModel.recentsStore.recents.isEmpty {
            Section {
                ForEach(viewModel.recentsStore.recents) { recent in
                    RecentRow(recent: recent) {
                        select(recent: recent)
                    } onRemove: {
                        viewModel.recentsStore.remove(recent)
                    }
                }
            } header: {
                HStack {
                    Text("Recents")
                    Spacer()
                    Button("Clear") {
                        viewModel.recentsStore.clear()
                    }
                    .font(.caption)
                }
            }
        }
    }

    private var suggestionsSection: some View {
        Section {
            ForEach(viewModel.suggestions, id: \.title) { suggestion in
                Button {
                    Task { await select(suggestion: suggestion) }
                } label: {
                    SuggestionRow(suggestion: suggestion)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func select(suggestion: MKLocalSearchCompletion) async {
        isFieldFocused = false
        await viewModel.select(suggestion)
    }

    private func select(recent: RecentSearch) {
        isFieldFocused = false
        viewModel.selectRecent(recent)
    }

    private func select(nearby result: SearchResult) {
        isFieldFocused = false
        viewModel.selectResult(result)
    }

    private func select(favorite: FavoritePlace) {
        isFieldFocused = false
        viewModel.selectFavorite(favorite)
    }

    private func selectDiscover(_ place: GooglePlace) {
        isFieldFocused = false
        viewModel.selectDiscover(place)
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
                    ZStack {
                        Circle()
                            .fill(.quaternary)
                            .frame(width: 32, height: 32)
                        Image(systemName: "clock")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recent.title)
                            .font(.body)
                            .foregroundStyle(.primary)
                        if !recent.subtitle.isEmpty {
                            Text(recent.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
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

private struct NearbyRow: View {
    let result: SearchResult

    var body: some View {
        let icon = PlaceCategoryIcon.icon(for: result.title)
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(icon.color.opacity(0.2))
                    .frame(width: 32, height: 32)
                Image(systemName: icon.symbol)
                    .font(.subheadline)
                    .foregroundStyle(icon.color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .font(.body)
                Text("Nearby")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct FavoriteCircle: View {
    let favorite: FavoritePlace
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Circle()
                    .fill(Color.indigo.gradient)
                    .frame(width: 44, height: 44)
                    .overlay {
                        Text(favorite.title.prefix(1))
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                Text(favorite.title)
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(width: 60)
            }
        }
        .buttonStyle(.plain)
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
    }
}

private struct ProfilePlaceholderSheet: View {
    @Environment(\.dismiss) private var dismiss

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)
                Text("Accounts aren't built yet")
                    .font(.headline)
                Text("Sign-in and synced favorites are planned for a later version of Waypoint. Recents and favorites are stored on this device only for now.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Spacer()
                Text("Waypoint v\(appVersion)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 40)
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
