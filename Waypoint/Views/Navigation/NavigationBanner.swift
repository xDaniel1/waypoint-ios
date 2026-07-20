import SwiftUI

/// Top-of-screen next-maneuver banner during driving navigation. Matches the reference:
/// large "Start on Varet St" with a turn glyph, and a smaller next-step row underneath.
struct NavigationBanner: View {
    let currentInstruction: String
    let nextInstruction: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "arrow.turn.up.right.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.white)
                Text(currentInstruction)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 14)
            .background(Color(white: 0.32))

            if let nextInstruction {
                HStack(spacing: 14) {
                    Image(systemName: "arrow.turn.up.right")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                        .frame(width: 32)
                    Text(nextInstruction)
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Color(white: 0.42))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .padding(.horizontal, 12)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
