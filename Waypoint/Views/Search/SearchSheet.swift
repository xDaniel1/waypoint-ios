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
    @Binding var detent: PresentationDetent
    @FocusState private var isFieldFocused: Bool
    @State private var isShowingProfile = false
    @AppStorage("com.danielguzman.waypoint.hasDismissedVoiceSearchTip") private var hasDismissedTip = false

    var body: some View {
        VStack(spacing: 0) {
            if let selected = viewModel.selectedResult, !isFieldFocused {
                PlaceDetailContent(result: selected) {
                    viewModel.clearSelection()
                }
            } else {
                HStack(spacing: 10) {
                    searchField
                    profileButton
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 12)

                if isFieldFocused {
                    List {
                        if viewModel.queryText.isEmpty {
                            tipSection
                            placesSection
                            categoriesSection
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
        .onChange(of: isFieldFocused) { _, focused in
            detent = focused ? .large : (viewModel.selectedResult == nil ? .height(120) : .medium)
        }
        .onChange(of: viewModel.selectedResult) { _, newValue in
            detent = newValue == nil ? .height(120) : .medium
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassEffect(.regular.tint(.blue.opacity(0.3)).interactive(), in: Capsule())
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
                    Button {
                        select(recent: recent)
                    } label: {
                        RecentRow(recent: recent)
                    }
                    .buttonStyle(.plain)
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
}

private struct SuggestionRow: View {
    let suggestion: MKLocalSearchCompletion

    var body: some View {
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

private struct RecentRow: View {
    let recent: RecentSearch

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
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
        HStack(spacing: 12) {
            Image(systemName: "mappin.circle.fill")
                .foregroundStyle(.red)
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
