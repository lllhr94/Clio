import Foundation

/// Thread-safe O(1) bounded LRU cache guarded by `NSLock`.
final class BoundedLRUCache<Key: Hashable, Value>: @unchecked Sendable {
    private final class Node {
        let key: Key
        var value: Value
        var cost: Int
        weak var prev: Node?
        var next: Node?

        init(key: Key, value: Value, cost: Int) {
            self.key = key
            self.value = value
            self.cost = cost
        }
    }

    private let lock = NSLock()
    private let countLimit: Int
    private let totalCostLimit: Int
    private var map: [Key: Node] = [:]
    private var head: Node?
    private var tail: Node?
    private var totalCost = 0

    init(countLimit: Int, totalCostLimit: Int = Int.max) {
        self.countLimit = max(1, countLimit)
        self.totalCostLimit = max(1, totalCostLimit)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return map.count
    }

    func get(_ key: Key) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard let node = map[key] else { return nil }
        moveToFront(node)
        return node.value
    }

    func set(_ value: Value, for key: Key, cost: Int = 1) {
        let safeCost = max(1, cost)
        guard safeCost <= totalCostLimit else { return }
        lock.lock()
        defer { lock.unlock() }
        if let existing = map[key] {
            totalCost = max(0, totalCost - existing.cost) + safeCost
            existing.value = value
            existing.cost = safeCost
            moveToFront(existing)
        } else {
            let node = Node(key: key, value: value, cost: safeCost)
            map[key] = node
            insertAtFront(node)
            totalCost += safeCost
        }
        while map.count > countLimit || totalCost > totalCostLimit {
            guard let victim = tail else { break }
            removeNode(victim)
            map.removeValue(forKey: victim.key)
            totalCost = max(0, totalCost - victim.cost)
        }
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        var current = head
        while let node = current {
            let next = node.next
            node.prev = nil
            node.next = nil
            current = next
        }
        map.removeAll(keepingCapacity: false)
        head = nil
        tail = nil
        totalCost = 0
    }

    func removeAll(where predicate: (Key) -> Bool) {
        lock.lock()
        defer { lock.unlock() }
        for node in Array(map.values) where predicate(node.key) {
            removeNode(node)
            map.removeValue(forKey: node.key)
            totalCost = max(0, totalCost - node.cost)
        }
    }

    private func insertAtFront(_ node: Node) {
        node.prev = nil
        node.next = head
        head?.prev = node
        head = node
        if tail == nil { tail = node }
    }

    private func removeNode(_ node: Node) {
        let prev = node.prev
        let next = node.next
        if let prev { prev.next = next } else { head = next }
        if let next { next.prev = prev } else { tail = prev }
        node.prev = nil
        node.next = nil
    }

    private func moveToFront(_ node: Node) {
        guard head !== node else { return }
        removeNode(node)
        insertAtFront(node)
    }
}
