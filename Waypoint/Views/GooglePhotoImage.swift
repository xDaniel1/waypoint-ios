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

    private var isLoaded: Bool {
        if case .success = phase { return true }
        return false
    }

    @State private var phase: GooglePhotoImagePhase = .empty
    /// Only a photo that had to come off the network fades in. Cross-fading a cache hit would
    /// put a 200ms veil over something that was already ready to draw, which reads as the app
    /// being slower than it is.
    @State private var fadesIn = false

    var body: some View {
        content(phase)
            .animation(fadesIn ? .easeOut(duration: 0.22) : nil, value: isLoaded)
            .task(id: url) {
                guard let url else {
                    phase = .empty
                    return
                }
                // Photos are billed per request, so check the disk cache before spending one.
                if let cached = await PhotoCache.shared.image(for: url) {
                    fadesIn = false
                    phase = .success(Image(uiImage: cached))
                    return
                }
                fadesIn = true
                phase = .empty
                var request = URLRequest(url: url)
                GoogleAPIRequest.addBundleIdentifierHeader(to: &request)
                guard let (data, _) = try? await URLSession.shared.data(for: request),
                      let uiImage = UIImage(data: data) else {
                    phase = .failure
                    return
                }
                // Render the decoded copy the cache just produced — handing SwiftUI the raw
                // `UIImage(data:)` would defer the bitmap decode to the main thread at draw time.
                let ready = await PhotoCache.shared.store(data, image: uiImage, for: url)
                phase = .success(Image(uiImage: ready))
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
