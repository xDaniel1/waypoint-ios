import SwiftUI

/// Identifies which photo set (and starting photo) the full-screen viewer should open with.
struct LightboxSelection: Identifiable {
    let id = UUID()
    let photos: [DetailedPlace.Photo]
    let index: Int
}

/// Full-screen photo viewer: swipe between photos, pinch/double-tap to zoom, drag down to dismiss.
struct PhotoLightbox: View {
    let photos: [DetailedPlace.Photo]
    let startIndex: Int
    let urlProvider: (DetailedPlace.Photo) -> URL?

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var dragOffset: CGFloat = 0

    init(photos: [DetailedPlace.Photo], startIndex: Int, urlProvider: @escaping (DetailedPlace.Photo) -> URL?) {
        self.photos = photos
        self.startIndex = startIndex
        self.urlProvider = urlProvider
        _index = State(initialValue: startIndex)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black
                .opacity(backgroundOpacity)
                .ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { i, photo in
                    ZoomablePhoto(url: urlProvider(photo))
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: photos.count > 1 ? .always : .never))
            .offset(y: dragOffset)

            header
        }
        .statusBarHidden()
        .gesture(
            DragGesture()
                .onChanged { value in
                    // Only track downward drags so this never fights the paging gesture.
                    guard value.translation.height > 0 else { return }
                    dragOffset = value.translation.height
                }
                .onEnded { value in
                    if value.translation.height > 120 {
                        dismiss()
                    } else {
                        withAnimation(.smooth(duration: 0.3)) { dragOffset = 0 }
                    }
                }
        )
    }

    private var backgroundOpacity: Double {
        max(0.4, 1 - Double(dragOffset) / 400)
    }

    private var header: some View {
        HStack {
            Spacer()
            if photos.count > 1 {
                Text("\(index + 1) of \(photos.count)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                Spacer()
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .scaledFont(size: 15, weight: .bold, relativeTo: .subheadline)
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("closeLightboxButton")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }
}

/// A single photo that supports pinch-to-zoom and double-tap-to-toggle-zoom.
private struct ZoomablePhoto: View {
    let url: URL?

    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            GooglePhotoImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale * pinch)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .gesture(
                            MagnifyGesture()
                                .updating($pinch) { value, state, _ in state = value.magnification }
                                .onEnded { value in
                                    scale = min(max(scale * value.magnification, 1), 4)
                                }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation(.smooth(duration: 0.25)) {
                                scale = scale > 1 ? 1 : 2.5
                            }
                        }
                case .failure:
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: proxy.size.width, height: proxy.size.height)
                default:
                    ProgressView()
                        .tint(.white)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
        }
    }
}
