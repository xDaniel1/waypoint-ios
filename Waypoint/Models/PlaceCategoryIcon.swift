import SwiftUI

/// Infers a category glyph/tint from a place's name text.
///
/// MapKit's live search completions (`MKLocalSearchCompletion`) only expose a title and
/// subtitle — no category field — so this can't be a verified lookup. It's a best-effort
/// keyword match against common chain/category names, close enough for a visual cue in
/// the suggestions list without claiming more precision than the data actually supports.
enum PlaceCategoryIcon {
    private static let rules: [(keywords: [String], symbol: String, color: Color)] = [
        (["mcdonald", "burger", "wendy", "kfc", "taco bell", "chick-fil-a", "pizza", "restaurant",
          "grill", "kitchen", "diner", "bbq", "sushi", "chipotle", "subway", "deli"], "fork.knife", .orange),
        (["starbucks", "coffee", "cafe", "café", "espresso", "dunkin"], "cup.and.saucer.fill", .brown),
        (["shell", "chevron", "exxon", "mobil", "bp ", "gas station", "76 ", "arco"], "fuelpump.fill", .blue),
        (["hotel", "inn", "motel", "resort", "suites"], "bed.double.fill", .purple),
        (["hospital", "medical", "clinic", "urgent care", "pharmacy", "cvs", "walgreens"], "cross.case.fill", .red),
        (["bank", "credit union", "atm", "chase", "wells fargo"], "banknote.fill", .green),
        (["school", "university", "college", "academy"], "graduationcap.fill", .indigo),
        (["park", "playground", "trail", "garden"], "tree.fill", .green),
        (["grocery", "market", "supermarket", "walmart", "target", "costco", "trader joe", "whole foods"], "cart.fill", .yellow),
        (["gym", "fitness", "yoga"], "figure.run", .pink),
        (["airport"], "airplane", .cyan),
        (["bar", "pub", "lounge", "brewery", "tavern"], "wineglass.fill", .purple),
        (["theater", "theatre", "cinema", "movie"], "film.fill", .indigo),
    ]

    static func icon(for text: String) -> (symbol: String, color: Color) {
        let lowercased = text.lowercased()
        for rule in rules where rule.keywords.contains(where: lowercased.contains) {
            return (rule.symbol, rule.color)
        }
        return ("mappin.circle.fill", .gray)
    }
}
