import Foundation
#if canImport(UIKit)
import UIKit
#endif

private let sdkVersion = "0.3.0"

/// Главный клиент Semetrics SDK для iOS/macOS.
///
/// Пример использования:
/// ```swift
/// // В AppDelegate или @main
/// SemetricsClient.configure(apiKey: "sm_live_...", endpoint: "https://semetrics.ru/events")
///
/// // Отправка события
/// SemetricsClient.shared.track(eventName: "screen_viewed", userId: "u123")
/// ```
public final class SemetricsClient {

    // MARK: - Singleton

    private static var _shared: SemetricsClient?

    public static var shared: SemetricsClient {
        guard let instance = _shared else {
            fatalError("Вызовите SemetricsClient.configure() перед использованием .shared")
        }
        return instance
    }

    public static func configure(
        apiKey: String,
        endpoint: String = "https://semetrics.ru/events",
        sourceId: String? = nil,
        flushInterval: TimeInterval = 5,
        batchSize: Int = 50,
        maxQueueSize: Int = 10_000,
        maxRetries: Int = 3
    ) {
        _shared = SemetricsClient(
            apiKey: apiKey,
            endpoint: endpoint,
            sourceId: sourceId,
            flushInterval: flushInterval,
            batchSize: batchSize,
            maxQueueSize: maxQueueSize,
            maxRetries: maxRetries
        )
    }

    // MARK: - Приватные свойства

    private let queue: EventQueue
    private let transport: NetworkTransport
    private let sourceId: String?
    private let batchSize: Int
    private let maxRetries: Int
    private var flushTimer: DispatchSourceTimer?
    private let workerQueue = DispatchQueue(label: "ru.semetrics.sdk.worker", qos: .utility)

    // MARK: - Инициализация

    private init(
        apiKey: String,
        endpoint: String,
        sourceId: String?,
        flushInterval: TimeInterval,
        batchSize: Int,
        maxQueueSize: Int,
        maxRetries: Int
    ) {
        self.queue = EventQueue(maxSize: maxQueueSize)
        self.transport = NetworkTransport(endpoint: endpoint, apiKey: apiKey)
        self.sourceId = sourceId
        self.batchSize = batchSize
        self.maxRetries = maxRetries

        setupFlushTimer(interval: flushInterval)
        subscribeToAppLifecycle()
    }

    // MARK: - Публичный API

    /// Добавить событие в очередь (не блокирует).
    public func track(
        eventName: String,
        userId: String? = nil,
        anonymousId: String? = nil,
        sessionId: String? = nil,
        properties: [String: Any]? = nil
    ) {
        let codableProperties = properties?.compactMapValues { AnyCodable($0) }
        let event = SemetricsEvent(
            eventName: eventName,
            userId: userId,
            anonymousId: anonymousId,
            sessionId: sessionId,
            sourceId: sourceId,
            platform: "ios",
            sdkVersion: sdkVersion,
            clientTs: Date(),
            properties: codableProperties
        )
        Task { await queue.enqueue(event) }
    }

    /// Отправить все накопленные события прямо сейчас.
    public func flush() {
        workerQueue.async { [weak self] in
            guard let self else { return }
            Task { await self.performFlush() }
        }
    }

    // MARK: - Приватная логика

    private func setupFlushTimer(interval: TimeInterval) {
        let timer = DispatchSource.makeTimerSource(queue: workerQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            Task { await self?.performFlush() }
        }
        timer.resume()
        flushTimer = timer
    }

    private func performFlush() async {
        while true {
            let batch = await queue.dequeueBatch(batchSize)
            guard !batch.isEmpty else { return }

            var lastError: Error?
            for attempt in 0..<maxRetries {
                do {
                    try await transport.sendBatch(batch)
                    lastError = nil
                    break
                } catch {
                    lastError = error
                    if attempt < maxRetries - 1 {
                        try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 1_000_000_000)
                    }
                }
            }

            if let error = lastError {
                // Не возвращаем в очередь — логируем потерю
                print("[Semetrics] Батч из \(batch.count) событий потерян: \(error)")
            }
        }
    }

    private func subscribeToAppLifecycle() {
#if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.flush()
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.flush()
        }
#endif
    }
}
