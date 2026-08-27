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
    private var memory = NSCache<NSString, UIImage>()

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

    func image(for url: URL) -> UIImage? {
        let key = filename(for: url)
        if let hit = memory.object(forKey: key as NSString) { return hit }
        guard let directory else { return nil }
        let file = directory.appendingPathComponent(key)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let modified = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < ttl,
              let data = try? Data(contentsOf: file),
              let image = UIImage(data: data) else { return nil }
        memory.setObject(image, forKey: key as NSString)
        return image
    }

    func store(_ data: Data, image: UIImage, for url: URL) {
        let key = filename(for: url)
        memory.setObject(image, forKey: key as NSString)
        guard let directory else { return }
        try? data.write(to: directory.appendingPathComponent(key), options: .atomic)
    }
}
