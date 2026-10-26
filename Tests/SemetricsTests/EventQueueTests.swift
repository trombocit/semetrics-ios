import XCTest
@testable import Semetrics

final class EventQueueTests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private var dbPath: URL { dir.appendingPathComponent("queue.sqlite") }

    func testPeekKeepsEventsUntilDeleted() async {
        let queue = EventQueue(path: dbPath, legacyDefaults: nil)
        for i in 0..<5 { await queue.enqueue(makeEvent("e\(i)")) }

        let first = await queue.peekBatch(2)
        XCTAssertEqual(first.map(\.event.eventName), ["e0", "e1"])
        let again = await queue.peekBatch(2)
        XCTAssertEqual(again.map(\.id), first.map(\.id), "peek не должен удалять события")

        await queue.delete(ids: first.map(\.id))
        let next = await queue.peekBatch(10)
        XCTAssertEqual(next.map(\.event.eventName), ["e2", "e3", "e4"])
        let count = await queue.count
        XCTAssertEqual(count, 3)
    }

    func testEventsSurviveRestart() async {
        do {
            let queue = EventQueue(path: dbPath, legacyDefaults: nil)
            await queue.enqueue(makeEvent("a"))
            await queue.enqueue(makeEvent("b"))
            _ = await queue.peekBatch(2)  // «отправка началась», приложение убили
        }
        let restored = EventQueue(path: dbPath, legacyDefaults: nil)
        let batch = await restored.peekBatch(10)
        XCTAssertEqual(batch.map(\.event.eventName), ["a", "b"])
    }

    func testMaxSizeDropsNewEvents() async {
        let queue = EventQueue(maxSize: 2, path: dbPath, legacyDefaults: nil)
        let r1 = await queue.enqueue(makeEvent("a"))
        let r2 = await queue.enqueue(makeEvent("b"))
        let r3 = await queue.enqueue(makeEvent("c"))
        XCTAssertEqual([r1, r2, r3], [true, true, false])

        let batch = await queue.peekBatch(1)
        await queue.delete(ids: batch.map(\.id))
        let r4 = await queue.enqueue(makeEvent("d"))
        XCTAssertTrue(r4, "после удаления место освобождается")
    }

    func testMigratesLegacyUserDefaultsQueue() async throws {
        let suite = "semetrics.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = [makeEvent("old1"), makeEvent("old2")]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "semetrics_event_queue")

        let queue = EventQueue(path: dbPath, legacyDefaults: defaults)

        let batch = await queue.peekBatch(10)
        XCTAssertEqual(batch.map(\.event.eventName), ["old1", "old2"])
        XCTAssertNil(defaults.data(forKey: "semetrics_event_queue"))
    }

    func testInMemoryQueueWhenNoPath() async {
        let queue = EventQueue(path: nil, legacyDefaults: nil)
        await queue.enqueue(makeEvent("a"))
        let count = await queue.count
        XCTAssertEqual(count, 1)
    }
}

func makeEvent(_ name: String) -> SemetricsEvent {
    SemetricsEvent(
        eventName: name, userId: nil, anonymousId: nil, sessionId: nil,
        sourceId: nil, sourceVersion: nil, platform: "ios", sdkVersion: "test",
        clientTs: Date(timeIntervalSince1970: 1_700_000_000), properties: ["k": AnyCodable(1)]
    )
}
