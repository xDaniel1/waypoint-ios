import SwiftUI

/// Drop-in replacement for `AsyncImage` when loading a Google Places photo URL. Those URLs are
/// on the same iOS-bundle-restricted API key as every other Google call here, but `AsyncImage`
/// has no way to attach the required `X-Ios-Bundle-Identifier` header — so this fetches the
/// image data manually with that header set, then renders it the same way `AsyncImage` would.
enum GooglePhotoImagePhase {
    case empty
    case success(Image)
    case failure
}

struct GooglePhotoImage<Content: View>: View {
    let url: URL?
    @ViewBuilder let content: (GooglePhotoImagePhase) -> Content

    @State private var phase: GooglePhotoImagePhase = .empty

    var body: some View {
        content(phase)
            .task(id: url) {
                phase = .empty
                guard let url else { return }
                var request = URLRequest(url: url)
                GoogleAPIRequest.addBundleIdentifierHeader(to: &request)
                guard let (data, _) = try? await URLSession.shared.data(for: request),
                      let uiImage = UIImage(data: data) else {
                    phase = .failure
                    return
                }
                phase = .success(Image(uiImage: uiImage))
            }
    }
}

extension GooglePhotoImage {
    /// Matches `AsyncImage(url:content:placeholder:)`'s simpler two-closure form.
    init<SuccessContent: View, PlaceholderContent: View>(
        url: URL?,
        @ViewBuilder content: @escaping (Image) -> SuccessContent,
        @ViewBuilder placeholder: @escaping () -> PlaceholderContent
    ) where Content == _ConditionalContent<SuccessContent, PlaceholderContent> {
        self.url = url
        self.content = { phase in
            if case .success(let image) = phase {
                ViewBuilder.buildEither(first: content(image))
            } else {
                ViewBuilder.buildEither(second: placeholder())
            }
        }
    }
}
