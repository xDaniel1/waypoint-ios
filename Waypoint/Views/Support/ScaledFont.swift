import SwiftUI

/// A system font at a fixed design size that still honours Dynamic Type.
///
/// `Font.system(size:)` is frozen — it ignores the user's text-size setting entirely, which is
/// how every label in this app used to behave. The semantic styles (`.body`, `.title2`) scale
/// correctly but would have resized the whole UI, since the layout is tuned to specific point
/// sizes. `@ScaledMetric` gives both: the design size stays the reference, and it scales along
/// the curve of whichever text style it's declared relative to.
///
/// Pick `relativeTo` to match the role of the text, not just its size — captions and body copy
/// scale on different curves.
extension View {
    func scaledFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        relativeTo textStyle: Font.TextStyle = .body
    ) -> some View {
        modifier(ScaledFontModifier(size: size, weight: weight, design: design, textStyle: textStyle))
    }
}

private struct ScaledFontModifier: ViewModifier {
    @ScaledMetric private var scaledSize: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design

    init(size: CGFloat, weight: Font.Weight, design: Font.Design, textStyle: Font.TextStyle) {
        _scaledSize = ScaledMetric(wrappedValue: size, relativeTo: textStyle)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: scaledSize, weight: weight, design: design))
    }
}
