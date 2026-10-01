import Foundation

/// One downloaded file in the on-device cache.
public struct CacheEntry: Codable, Sendable, Equatable {
    public var key: String
    public var bytes: Int
    public var lastUsed: Date
    public init(key: String, bytes: Int, lastUsed: Date) { self.key = key; self.bytes = bytes; self.lastUsed = lastUsed }
}

/// Least-recently-used eviction under a byte cap (PLAN.md §2 C6).
public enum CachePolicy {
    /// Keys to delete, oldest first, until the total is at or under `capBytes`. Protected
    /// keys (the current stitch, in-flight downloads, loaded singles) are never returned,
    /// even if that leaves the cache over the cap.
    public static func evictions(_ entries: [CacheEntry], capBytes: Int, protected: Set<String>) -> [String] {
        var total = entries.reduce(0) { $0 + $1.bytes }
        guard total > capBytes else { return [] }
        var out: [String] = []
        for e in entries.sorted(by: { $0.lastUsed < $1.lastUsed }) where !protected.contains(e.key) {
            if total <= capBytes { break }
            out.append(e.key)
            total -= e.bytes
        }
        return out
    }
}
