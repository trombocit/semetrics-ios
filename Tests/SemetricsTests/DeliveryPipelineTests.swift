import XCTest
@testable import Semetrics

private final class MockSender: BatchSender {
    var results: [Error?]
    private(set) var sent: [[String]] = []

    init(_ results: [Error?]) { self.results = results }

    func sendBatch(_ events: [SemetricsEvent]) async throws {
        sent.append(events.map(\.eventName))
        let result = results.isEmpty ? nil : results.removeFirst()
        if let result { throw result }
    }
}

final class DeliveryPipelineTests: XCTestCase {

    private func makePipeline(_ sender: MockSender, events: Int, maxRetries: Int = 1) async -> DeliveryPipeline {
        let queue = EventQueue(path: nil, legacyDefaults: nil)
        for i in 0..<events { await queue.enqueue(makeEvent("e\(i)")) }
        return DeliveryPipeline(queue: queue, sender: sender, batchSize: 2, maxRetries: maxRetries, retryDelay: 0)
    }

    func testSuccessDrainsQueue() async {
        let sender = MockSender([])
        let pipeline = await makePipeline(sender, events: 5)

        await pipeline.flush(force: false)

        XCTAssertEqual(sender.sent, [["e0", "e1"], ["e2", "e3"], ["e4"]])
        let count = await pipeline.queue.count
        XCTAssertEqual(count, 0)
    }

    func testNetworkErrorKeepsEventsAndStartsBackoff() async {
        let sender = MockSender([URLError(.cannotFindHost)])
        let pipeline = await makePipeline(sender, events: 3)

        await pipeline.flush(force: false)

        XCTAssertEqual(sender.sent.count, 1, "после сетевой ошибки цикл останавливается")
        let count = await pipeline.queue.count
        XCTAssertEqual(count, 3)
        let failures = await pipeline.backoff.consecutiveFailures
        XCTAssertEqual(failures, 1)

        // Тик таймера во время паузы в сеть не ходит
        await pipeline.flush(force: false)
        XCTAssertEqual(sender.sent.count, 1)

        // Явный flush — идёт, и после успеха очередь пуста, backoff сброшен
        await pipeline.flush(force: true)
        let after = await pipeline.queue.count
        XCTAssertEqual(after, 0)
        let reset = await pipeline.backoff.consecutiveFailures
        XCTAssertEqual(reset, 0)
    }

    func testFastRetriesBeforeGivingUp() async {
        let sender = MockSender([URLError(.timedOut), URLError(.timedOut), nil])
        let pipeline = await makePipeline(sender, events: 1, maxRetries: 3)

        await pipeline.flush(force: false)

        XCTAssertEqual(sender.sent.count, 3)
        let count = await pipeline.queue.count
        XCTAssertEqual(count, 0)
    }

    func testRejectedBatchIsDroppedAndDoesNotBlockQueue() async {
        let sender = MockSender([TransportError.httpError(422)])
        let pipeline = await makePipeline(sender, events: 4, maxRetries: 3)

        await pipeline.flush(force: false)

        XCTAssertEqual(sender.sent, [["e0", "e1"], ["e2", "e3"]], "4xx — без повторов, следующий батч уходит")
        let count = await pipeline.queue.count
        XCTAssertEqual(count, 0)
    }
}
