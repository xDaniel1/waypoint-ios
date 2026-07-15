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
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 12)

            List {
                if viewModel.queryText.isEmpty {
                    categoriesSection
                    recentsSection
                } else {
                    suggestionsSection
                }
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.immediately)
        }
    }

    private var searchField: some View {
        GlassEffectContainer {
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
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .glassEffect(.regular.interactive(), in: Capsule())
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
