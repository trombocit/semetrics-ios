import Foundation

/// Аналитическое событие, готовое к отправке.
public struct SemetricsEvent: Codable {
    public let eventName: String
    public let userId: String?
    public let anonymousId: String?
    public let sessionId: String?
    public let sourceId: String?
    public let sourceVersion: String?
    public let platform: String
    public let sdkVersion: String
    public let clientTs: Date
    public let properties: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case eventName    = "event_name"
        case userId       = "user_id"
        case anonymousId  = "anonymous_id"
        case sessionId    = "session_id"
        case sourceId      = "source_id"
        case sourceVersion = "source_version"
        case platform
        case sdkVersion   = "sdk_version"
        case clientTs     = "client_ts"
        case properties
    }
}

/// Батч событий для отправки на сервер.
struct BatchPayload: Encodable {
    let events: [SemetricsEvent]
}

/// Ответ сервера.
struct ServerResponse: Decodable {
    struct Status: Decodable {
        let code: String
        let message: String?
    }
    let status: Status
}

// MARK: - AnyCodable (простой враппер для произвольных свойств)

/// Враппер для кодирования/декодирования произвольных JSON-значений.
public struct AnyCodable: Codable {
    public let value: Any

    public init(_ value: Any) { self.value = value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self)         { value = int; return }
        if let double = try? container.decode(Double.self)   { value = double; return }
        if let bool = try? container.decode(Bool.self)       { value = bool; return }
        if let string = try? container.decode(String.self)   { value = string; return }
        value = NSNull()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let v as Int:    try container.encode(v)
        case let v as Double: try container.encode(v)
        case let v as Bool:   try container.encode(v)
        case let v as String: try container.encode(v)
        default:              try container.encodeNil()
        }
    }
}
