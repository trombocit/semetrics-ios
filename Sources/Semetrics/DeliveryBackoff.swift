import Foundation

/// Состояние доставки: пауза между неудачными циклами отправки и защита от параллельных flush.
///
/// После неудачного цикла следующая попытка откладывается: 5s → 10s → 20s → … → 5 мин (±20% jitter).
/// Тики таймера в это время не ходят в сеть; явный `flush()` паузу игнорирует.
actor DeliveryBackoff {

    private let baseDelay: TimeInterval
    private let maxDelay: TimeInterval
    private let now: () -> Date

    private(set) var consecutiveFailures = 0
    private(set) var nextAttemptAt: Date?
    private var isFlushing = false

    init(baseDelay: TimeInterval = 5, maxDelay: TimeInterval = 300, now: @escaping () -> Date = Date.init) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.now = now
    }

    /// Можно ли начать flush. `force` — явный вызов `flush()`, пропускает паузу.
    func tryBegin(force: Bool) -> Bool {
        guard !isFlushing else { return false }
        if !force, let nextAttemptAt, now() < nextAttemptAt { return false }
        isFlushing = true
        return true
    }

    func end() {
        isFlushing = false
    }

    /// Отметить успешную отправку. Возвращает число неудачных циклов до неё (для лога о восстановлении).
    func recordSuccess() -> Int {
        let failures = consecutiveFailures
        consecutiveFailures = 0
        nextAttemptAt = nil
        return failures
    }

    /// Отметить неудачный цикл. Возвращает задержку до следующей попытки.
    func recordFailure() -> TimeInterval {
        consecutiveFailures += 1
        let exponent = Double(min(consecutiveFailures - 1, 16))
        let delay = min(baseDelay * pow(2, exponent), maxDelay) * Double.random(in: 0.8...1.2)
        nextAttemptAt = now().addingTimeInterval(delay)
        return delay
    }

    /// Временная ли ошибка (стоит повторить позже) или батч не примут никогда.
    static func isRetryable(_ error: Error) -> Bool {
        switch error {
        case TransportError.httpError(let code):
            return code == 408 || code == 429 || code >= 500
        case TransportError.serverError:
            return false  // сервер явно отклонил батч
        case is EncodingError:
            return false  // батч не сериализуется — повтор не поможет
        case let urlError as URLError:
            return ![.badURL, .unsupportedURL].contains(urlError.code)
        default:
            return true  // сеть, обрыв, не-JSON ответ (captive portal) и т.п.
        }
    }
}
