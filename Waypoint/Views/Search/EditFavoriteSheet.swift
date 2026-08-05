import SwiftUI

/// Lets the user rename a saved place and give it a custom pin emoji/color instead of the
/// auto-derived `PlaceCategoryIcon` look every favorite starts with.
struct EditFavoriteSheet: View {
    let favorite: FavoritePlace
    let onSave: (_ title: String, _ emoji: String?, _ colorHex: String?) -> Void

    @State private var title: String
    @State private var emoji: String
    @State private var color: Color
    @Environment(\.dismiss) private var dismiss

    private static let presetEmoji = [
        "📍", "⭐️", "❤️", "🏠", "🏢", "🎓",
        "☕️", "🍕", "🛒", "⛽️", "🅿️", "🏋️",
        "🏖️", "✈️", "🏥", "🐾",
    ]
    private static let columns = Array(repeating: GridItem(.flexible()), count: 6)

    init(favorite: FavoritePlace, onSave: @escaping (_ title: String, _ emoji: String?, _ colorHex: String?) -> Void) {
        self.favorite = favorite
        self.onSave = onSave
        _title = State(initialValue: favorite.displayTitle)
        _emoji = State(initialValue: favorite.emoji ?? "")
        _color = State(initialValue: Color(hex: favorite.colorHex) ?? PlaceCategoryIcon.icon(for: favorite.title).color)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField(favorite.title, text: $title)
                        .accessibilityIdentifier("editFavoriteTitleField")
                }

                Section("Pin") {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle().fill(color.gradient).frame(width: 44, height: 44)
                            if emoji.isEmpty {
                                Image(systemName: PlaceCategoryIcon.icon(for: favorite.title).symbol)
                                    .foregroundStyle(.white)
                            } else {
                                Text(emoji).font(.title3)
                            }
                        }
                        TextField("Emoji (optional)", text: $emoji)
                            .onChange(of: emoji) { _, newValue in
                                // Only one glyph makes sense on a pin — keep the last one typed.
                                if let last = newValue.last { emoji = String(last) } else { emoji = "" }
                            }
                        Spacer()
                        ColorPicker("", selection: $color, supportsOpacity: false)
                            .labelsHidden()
                    }
                    LazyVGrid(columns: Self.columns, spacing: 10) {
                        ForEach(Self.presetEmoji, id: \.self) { candidate in
                            Button {
                                emoji = candidate
                            } label: {
                                Text(candidate)
                                    .font(.title2)
                                    .frame(maxWidth: .infinity, minHeight: 36)
                                    .background(
                                        emoji == candidate ? Color.accentColor.opacity(0.2) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                    if !emoji.isEmpty {
                        Button("Clear Emoji", role: .destructive) { emoji = "" }
                    }
                }
            }
            .navigationTitle("Edit Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(title, emoji.isEmpty ? nil : emoji, color.hexString)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
