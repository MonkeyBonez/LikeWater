import Foundation

/// Flat binary min-heap of (key, node) pairs with lazy deletion.
struct MinHeap {
    private var keys: [Double] = []
    private var vals: [Int32] = []

    var isEmpty: Bool { keys.isEmpty }
    var count: Int { keys.count }

    mutating func reserve(_ n: Int) { keys.reserveCapacity(n); vals.reserveCapacity(n) }
    mutating func removeAll() { keys.removeAll(keepingCapacity: true); vals.removeAll(keepingCapacity: true) }

    mutating func push(_ key: Double, _ val: Int32) {
        keys.append(key); vals.append(val)
        var i = keys.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            if keys[parent] <= keys[i] { break }
            keys.swapAt(parent, i); vals.swapAt(parent, i)
            i = parent
        }
    }

    mutating func pop() -> (key: Double, val: Int32)? {
        guard let topKey = keys.first else { return nil }
        let topVal = vals[0]
        let last = keys.count - 1
        keys[0] = keys[last]; vals[0] = vals[last]
        keys.removeLast(); vals.removeLast()
        var i = 0
        let n = keys.count
        while true {
            let l = 2 * i + 1, r = l + 1
            var smallest = i
            if l < n && keys[l] < keys[smallest] { smallest = l }
            if r < n && keys[r] < keys[smallest] { smallest = r }
            if smallest == i { break }
            keys.swapAt(smallest, i); vals.swapAt(smallest, i)
            i = smallest
        }
        return (topKey, topVal)
    }
}
