import CryptoKit
import Foundation
import UIKit

/// Disk cache for Google Places photos.
///
/// Photos are billed per request and are by far the highest-volume call this app makes — the
/// search page alone shows dozens of cards, and every one was re-fetched on each cold launch
/// because `URLSession.shared`'s default cache doesn't reliably hold these (the media endpoint
/// redirects, and the URL carries an API key). Storing the decoded bytes ourselves makes a
/// relaunch cost nothing.
///
/// A photo for a given place never changes, so entries only age out to reclaim space.
actor PhotoCache {
    static let shared = PhotoCache()

    private let ttl: TimeInterval = 14 * 24 * 3600
    private let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        // Unbounded, an NSCache of decoded bitmaps will happily sit on tens of MB of thumbnails
        // after a long scroll and then get purged all at once under pressure — which shows up as
        // every card reloading at the same moment. A explicit byte budget keeps eviction gradual.
        cache.countLimit = 250
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    /// Forces the bitmap decode now, off the main thread.
    ///
    /// `UIImage(data:)` doesn't actually decode — it defers that until the image is first drawn,
    /// which happens on the main thread mid-scroll. That's a per-image hitch on a list of photo
    /// cards, and it's the single biggest cause of the scrolling not feeling like Apple's.
    private static func decoded(_ image: UIImage) async -> UIImage {
        await image.byPreparingForDisplay() ?? image
    }

    /// Rough byte cost of a decoded bitmap, so `totalCostLimit` is in real memory rather than
    /// counting every image as 1 regardless of size.
    private static func cost(of image: UIImage) -> Int {
        let size = image.cgImage.map { $0.bytesPerRow * $0.height }
        return size ?? Int(image.size.width * image.size.height * image.scale * image.scale * 4)
    }

    private var directory: URL? {
        guard let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("waypoint-photos", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// The URL carries the API key as a query item, so it's hashed rather than used verbatim —
    /// that keeps the key out of the filesystem and gives a fixed-length filename.
    private func filename(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func image(for url: URL) async -> UIImage? {
        let key = filename(for: url)
        // A memory hit is already decoded, so it can go straight back without another pass.
        if let hit = memory.object(forKey: key as NSString) { return hit }
        guard let directory else { return nil }
        let file = directory.appendingPathComponent(key)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let modified = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < ttl,
              let data = try? Data(contentsOf: file),
              let image = UIImage(data: data) else { return nil }
        let ready = await Self.decoded(image)
        memory.setObject(ready, forKey: key as NSString, cost: Self.cost(of: ready))
        return ready
    }

    /// Returns the decoded image so the caller renders the same bitmap that got cached, rather
    /// than handing SwiftUI an undecoded one and paying for the decode on the main thread anyway.
    @discardableResult
    func store(_ data: Data, image: UIImage, for url: URL) async -> UIImage {
        let key = filename(for: url)
        let ready = await Self.decoded(image)
        memory.setObject(ready, forKey: key as NSString, cost: Self.cost(of: ready))
        guard let directory else { return ready }
        try? data.write(to: directory.appendingPathComponent(key), options: .atomic)
        return ready
    }
}
