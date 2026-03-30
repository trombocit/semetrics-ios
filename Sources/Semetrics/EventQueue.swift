import Foundation

private let userDefaultsKey = "semetrics_event_queue"

/// Thread-safe очередь событий с персистентностью через UserDefaults.
actor EventQueue {

    private var events: [SemetricsEvent] = []
    private let maxSize: Int

    init(maxSize: Int = 10_000) {
        self.maxSize = maxSize
        self.events = Self.loadFromDisk()
    }

    // MARK: - Публичный интерфейс

    func enqueue(_ event: SemetricsEvent) {
        guard events.count < maxSize else {
            return  // очередь переполнена — дропаем
        }
        events.append(event)
        saveToDisk()
    }

    func dequeueBatch(_ size: Int) -> [SemetricsEvent] {
        let count = min(size, events.count)
        guard count > 0 else { return [] }
        let batch = Array(events.prefix(count))
        events.removeFirst(count)
        saveToDisk()
        return batch
    }

    func requeueBatch(_ batch: [SemetricsEvent]) {
        events.insert(contentsOf: batch, at: 0)
        saveToDisk()
    }

    var count: Int { events.count }

    // MARK: - Персистентность

    private func saveToDisk() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }

    private static func loadFromDisk() -> [SemetricsEvent] {
        guard
            let data = UserDefaults.standard.data(forKey: userDefaultsKey),
            let events = try? JSONDecoder().decode([SemetricsEvent].self, from: data)
        else { return [] }
        return events
    }
}
