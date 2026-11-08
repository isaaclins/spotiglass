import Foundation

/// A dictionary bounded by ``capacity`` that evicts the least recently used entries first.
///
/// Both reading and writing a key count as a use, so an entry that keeps being looked up
/// (a cover on screen, a pinned item, a song that was just mapped again) stays while entries
/// nobody asked for in a long time go. Once the count passes the capacity, the oldest entries
/// are dropped in one batch down to ``trimmedCount``, which keeps eviction cheap: one sort per
/// `capacity - trimmedCount` insertions instead of a scan per insertion.
///
/// Not thread-safe; callers guard it with their own lock.
struct LRUDictionary<Key: Hashable, Value> {
    let capacity: Int
    /// The count left after an eviction batch: 90 % of the capacity.
    let trimmedCount: Int

    private var entries: [Key: (value: Value, lastUse: UInt64)] = [:]
    private var clock: UInt64 = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        self.trimmedCount = max(1, self.capacity - max(1, self.capacity / 10))
    }

    /// The value for `key`, marking it as just used.
    mutating func value(forKey key: Key) -> Value? {
        guard let entry = entries[key] else { return nil }
        clock &+= 1
        entries[key] = (entry.value, clock)
        return entry.value
    }

    /// Changes every value in place; not a use, so nothing moves in the eviction order.
    mutating func updateValues(_ change: (inout Value) -> Void) {
        for key in Array(entries.keys) {
            change(&entries[key]!.value)
        }
    }

    /// Stores `value` under `key` as the most recently used entry, then evicts the least
    /// recently used entries if the capacity is exceeded.
    mutating func setValue(_ value: Value, forKey key: Key) {
        clock &+= 1
        entries[key] = (value, clock)
        guard entries.count > capacity else { return }
        let overflow = entries.count - trimmedCount
        let oldest = entries.lazy
            .map { (key: $0.key, lastUse: $0.value.lastUse) }
            .sorted { $0.lastUse < $1.lastUse }
            .prefix(overflow)
        for entry in oldest { entries.removeValue(forKey: entry.key) }
    }
}
