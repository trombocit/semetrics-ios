import XCTest
@testable import Semetrics

final class DeliveryBackoffTests: XCTestCase {

    func testDelayGrowsExponentiallyAndIsCapped() async {
        let backoff = DeliveryBackoff(baseDelay: 5, maxDelay: 300)
        var delays: [TimeInterval] = []
        for _ in 0..<10 { delays.append(await backoff.recordFailure()) }

        XCTAssertEqual(delays[0], 5, accuracy: 1)
        XCTAssertEqual(delays[1], 10, accuracy: 2)
        XCTAssertEqual(delays[2], 20, accuracy: 4)
        XCTAssertLessThanOrEqual(delays.max()!, 360)
        XCTAssertGreaterThanOrEqual(delays.last!, 240)
    }

    func testTimerFlushWaitsForBackoffButForcedFlushDoesNot() async {
        var clock = Date(timeIntervalSince1970: 0)
        let backoff = DeliveryBackoff(baseDelay: 5, maxDelay: 300, now: { clock })

        _ = await backoff.recordFailure()
        let blocked = await backoff.tryBegin(force: false)
        XCTAssertFalse(blocked)

        let forced = await backoff.tryBegin(force: true)
        XCTAssertTrue(forced)
        await backoff.end()

        clock = clock.addingTimeInterval(10)
        let afterDelay = await backoff.tryBegin(force: false)
        XCTAssertTrue(afterDelay)
    }

    func testConcurrentFlushIsRejected() async {
        let backoff = DeliveryBackoff()
        let first = await backoff.tryBegin(force: true)
        let second = await backoff.tryBegin(force: true)
        XCTAssertTrue(first)
        XCTAssertFalse(second)
    }

    func testSuccessResetsFailures() async {
        let backoff = DeliveryBackoff()
        _ = await backoff.recordFailure()
        _ = await backoff.recordFailure()
        let failures = await backoff.recordSuccess()
        XCTAssertEqual(failures, 2)
        let next = await backoff.nextAttemptAt
        XCTAssertNil(next)
    }

    func testErrorClassification() {
        XCTAssertTrue(DeliveryBackoff.isRetryable(URLError(.cannotFindHost)))       // -1003, DNS
        XCTAssertTrue(DeliveryBackoff.isRetryable(URLError(.notConnectedToInternet)))
        XCTAssertTrue(DeliveryBackoff.isRetryable(URLError(.timedOut)))
        XCTAssertTrue(DeliveryBackoff.isRetryable(TransportError.httpError(503)))
        XCTAssertTrue(DeliveryBackoff.isRetryable(TransportError.httpError(429)))
        XCTAssertFalse(DeliveryBackoff.isRetryable(TransportError.httpError(401)))
        XCTAssertFalse(DeliveryBackoff.isRetryable(TransportError.httpError(422)))
        XCTAssertFalse(DeliveryBackoff.isRetryable(TransportError.serverError("validation")))
    }
}
