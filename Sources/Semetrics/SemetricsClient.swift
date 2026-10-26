import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif

private let sdkVersion = "0.5.0"

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
        sourceVersion: String? = nil,
        flushInterval: TimeInterval = 5,
        batchSize: Int = 50,
        maxQueueSize: Int = 10_000,
        maxRetries: Int = 3
    ) {
        _shared = SemetricsClient(
            apiKey: apiKey,
            endpoint: endpoint,
            sourceId: sourceId,
            sourceVersion: sourceVersion,
            flushInterval: flushInterval,
            batchSize: batchSize,
            maxQueueSize: maxQueueSize,
            maxRetries: maxRetries
        )
    }

    // MARK: - Приватные свойства

    private let pipeline: DeliveryPipeline
    private let sourceId: String?
    private let sourceVersion: String?
    private var flushTimer: DispatchSourceTimer?
    private let pathMonitor = NWPathMonitor()
    private var lastPathStatus: NWPath.Status?
    private let workerQueue = DispatchQueue(label: "ru.semetrics.sdk.worker", qos: .utility)
#if canImport(UIKit)
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
#endif

    // MARK: - Инициализация

    private init(
        apiKey: String,
        endpoint: String,
        sourceId: String?,
        sourceVersion: String?,
        flushInterval: TimeInterval,
        batchSize: Int,
        maxQueueSize: Int,
        maxRetries: Int
    ) {
        self.pipeline = DeliveryPipeline(
            queue: EventQueue(maxSize: maxQueueSize),
            sender: NetworkTransport(endpoint: endpoint, apiKey: apiKey),
            batchSize: batchSize,
            maxRetries: maxRetries
        )
        self.sourceId = sourceId
        self.sourceVersion = sourceVersion

        setupFlushTimer(interval: flushInterval)
        subscribeToAppLifecycle()
        startNetworkMonitor()
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
            sourceVersion: sourceVersion,
            platform: "ios",
            sdkVersion: sdkVersion,
            clientTs: Date(),
            properties: codableProperties
        )
        Task { [pipeline] in await pipeline.queue.enqueue(event) }
    }

    /// Отправить все накопленные события прямо сейчас.
    public func flush() {
        workerQueue.async { [pipeline] in
            Task { await pipeline.flush(force: true) }
        }
    }

    // MARK: - Приватная логика

    private func setupFlushTimer(interval: TimeInterval) {
        let timer = DispatchSource.makeTimerSource(queue: workerQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [pipeline] in
            Task { await pipeline.flush(force: false) }
        }
        timer.resume()
        flushTimer = timer
    }

    /// Сеть появилась — отправляем сразу, не дожидаясь паузы backoff (до 5 мин).
    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let wasOffline = self.lastPathStatus != nil && self.lastPathStatus != .satisfied
            self.lastPathStatus = path.status
            if wasOffline && path.status == .satisfied {
                self.flush()
            }
        }
        pathMonitor.start(queue: workerQueue)
    }

    private func subscribeToAppLifecycle() {
#if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.flushInBackgroundTask()
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

#if canImport(UIKit)
    /// При уходе в фон просим у iOS время дослать очередь — иначе приложение заморозят посреди запроса.
    /// Вызывается на main thread (уведомления UIApplication), `backgroundTaskId` трогаем только там.
    private func flushInBackgroundTask() {
        endBackgroundTask()
        let taskId = UIApplication.shared.beginBackgroundTask(withName: "ru.semetrics.flush") { [weak self] in
            self?.endBackgroundTask()
        }
        backgroundTaskId = taskId
        // self — singleton на всё время жизни приложения, сильный захват безопасен
        Task { [pipeline] in
            await pipeline.flush(force: true)
            await MainActor.run { self.endBackgroundTask(ifCurrent: taskId) }
        }
    }

    private func endBackgroundTask(ifCurrent taskId: UIBackgroundTaskIdentifier? = nil) {
        guard backgroundTaskId != .invalid, taskId == nil || taskId == backgroundTaskId else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskId)
        backgroundTaskId = .invalid
    }
#endif
}
