import Foundation

/// Отправка батча на сервер (абстракция над `NetworkTransport` для тестов).
protocol BatchSender: AnyObject {
    func sendBatch(_ events: [SemetricsEvent]) async throws
}

extension NetworkTransport: BatchSender {}

/// Цикл доставки: читает батчи из очереди, отправляет, удаляет после ответа сервера.
final class DeliveryPipeline {

    let queue: EventQueue
    let backoff: DeliveryBackoff
    private let sender: BatchSender
    private let batchSize: Int
    private let maxRetries: Int
    private let retryDelay: TimeInterval

    init(
        queue: EventQueue,
        sender: BatchSender,
        backoff: DeliveryBackoff = DeliveryBackoff(),
        batchSize: Int,
        maxRetries: Int,
        retryDelay: TimeInterval = 1
    ) {
        self.queue = queue
        self.sender = sender
        self.backoff = backoff
        self.batchSize = batchSize
        self.maxRetries = max(1, maxRetries)
        self.retryDelay = retryDelay
    }

    /// Отправить очередь целиком. `force` — явный вызов, игнорирует паузу backoff.
    func flush(force: Bool) async {
        guard await backoff.tryBegin(force: force) else { return }

        while true {
            let batch = await queue.peekBatch(batchSize)
            guard !batch.isEmpty else { break }
            let ids = batch.map(\.id)

            var lastError: Error?
            for attempt in 0..<maxRetries {
                do {
                    try await sender.sendBatch(batch.map(\.event))
                    lastError = nil
                    break
                } catch {
                    lastError = error
                    guard DeliveryBackoff.isRetryable(error) else { break }
                    if attempt < maxRetries - 1 {
                        try? await Task.sleep(nanoseconds: UInt64(retryDelay * pow(2.0, Double(attempt)) * 1_000_000_000))
                    }
                }
            }

            guard let error = lastError else {
                await queue.delete(ids: ids)
                let failures = await backoff.recordSuccess()
                if failures > 0 {
                    print("[Semetrics] Отправка восстановлена после \(failures) неудачных циклов")
                }
                continue
            }

            if DeliveryBackoff.isRetryable(error) {
                // Временная ошибка (нет сети, DNS, 5xx) — батч остаётся в очереди, ждём, а не долбим сервер
                let delay = await backoff.recordFailure()
                if await backoff.consecutiveFailures == 1 {
                    let pending = await queue.count
                    print("[Semetrics] Сервер недоступен, \(pending) событий ждут в очереди, повтор через \(Int(delay))с: \(error)")
                }
                break
            }

            // Батч не примут никогда (4xx, ошибка валидации) — удаляем, чтобы не блокировал очередь
            await queue.delete(ids: ids)
            print("[Semetrics] Батч из \(batch.count) событий отклонён и удалён: \(error)")
        }

        await backoff.end()
    }
}
