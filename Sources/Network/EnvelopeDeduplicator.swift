import Foundation

/// Shared across transport sessions so a retry cannot execute a command twice
/// merely because it moved from TCP to BLE. Bounded to the process lifetime.
struct EnvelopeDeduplicator {
    private let capacity: Int
    private var ids = Set<String>()
    private var order: [String] = []
    init(capacity: Int = 4096) { precondition(capacity > 0); self.capacity = capacity }
    mutating func insert(_ id: String) -> Bool {
        guard ids.insert(id).inserted else { return false }
        order.append(id)
        if order.count > capacity { ids.remove(order.removeFirst()) }
        return true
    }
    mutating func reset() { ids.removeAll(); order.removeAll() }
}
