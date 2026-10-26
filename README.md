# Semetrics iOS SDK

Swift SDK для отправки аналитических событий на платформу Semetrics.

**Требования:** iOS 16+, macOS 13+, Swift 5.9+

## Установка

### Swift Package Manager

В Xcode: **File → Add Package Dependencies**

```
https://github.com/trombocit/semetrics-ios
```

Или в `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/trombocit/semetrics-ios", from: "0.5.0")
]
```

## Быстрый старт

```swift
// AppDelegate.swift или App.swift
import Semetrics

// При запуске приложения
SemetricsClient.configure(
    apiKey: "sm_live_ваш_ключ",
    endpoint: "https://semetrics.ru/events",
    sourceId: Bundle.main.bundleIdentifier,  // "com.beyondviolet.wfm"
    sourceVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String  // "2.1.0"
)

// В любом месте приложения
SemetricsClient.shared.track(
    eventName: "screen_viewed",
    userId: "user_123",
    properties: ["screen": "home", "source": "push"]
)
```

## Параметры configure()

| Параметр | По умолчанию | Описание |
|----------|-------------|----------|
| `apiKey` | обязательный | API-ключ проекта |
| `endpoint` | `https://semetrics.ru/events` | URL сервиса |
| `sourceId` | `nil` | Идентификатор источника (`Bundle.main.bundleIdentifier`) |
| `sourceVersion` | `nil` | Версия приложения (`CFBundleShortVersionString`) |
| `flushInterval` | `5.0` | Интервал фонового сброса (секунды) |
| `batchSize` | `50` | Размер батча |
| `maxQueueSize` | `10_000` | Максимум событий в очереди |
| `maxRetries` | `3` | Попыток при ошибке |

## Гарантия доставки

- События хранятся в SQLite и удаляются только после ответа сервера — переживают перезапуск и force kill
- Автоматический flush при уходе в background, возврате в foreground и появлении сети
- При временной ошибке (сеть, DNS, 5xx) батч возвращается в очередь, повтор с backoff 5s → … → 5 мин; при 4xx батч удаляется

## Принудительный flush

```swift
SemetricsClient.shared.flush()
```

