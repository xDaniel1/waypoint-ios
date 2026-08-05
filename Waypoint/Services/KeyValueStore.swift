import Foundation

/// `UserDefaults` and `NSUbiquitousKeyValueStore` already share this exact method shape —
/// this just names it so stores can be built against either one and swapped in tests.
protocol KeyValueStore: AnyObject {
    func data(forKey defaultName: String) -> Data?
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: KeyValueStore {}
extension NSUbiquitousKeyValueStore: KeyValueStore {}
