import Foundation
import SQLite3

/// Ключ, под которым SDK ≤ 0.4.x хранил очередь в UserDefaults (переносится в SQLite при первом запуске).
private let legacyUserDefaultsKey = "semetrics_event_queue"
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Событие из очереди вместе с id строки в SQLite.
struct QueuedEvent {
    let id: Int64
    let event: SemetricsEvent
}

/// Персистентная очередь событий в SQLite.
///
/// Каждое событие — отдельная строка: `track()` не переписывает всю очередь.
/// `peekBatch` не удаляет события — их удаляет `delete` после ответа сервера,
/// поэтому убийство приложения во время отправки не теряет батч.
actor EventQueue {

    private let db: OpaquePointer?
    private let maxSize: Int
    private var storedCount: Int
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// - Parameters:
    ///   - path: файл базы; `nil` — очередь только в памяти.
    ///   - legacyDefaults: откуда перенести очередь старых версий SDK.
    init(maxSize: Int = 10_000, path: URL? = EventQueue.defaultPath(), legacyDefaults: UserDefaults? = .standard) {
        self.maxSize = maxSize
        let db = Self.open(path: path)
        self.db = db
        if let legacyDefaults { Self.migrateLegacy(db: db, defaults: legacyDefaults) }
        self.storedCount = Self.countRows(db: db)
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Публичный интерфейс

    /// Добавить событие. Возвращает `false`, если очередь переполнена или запись не удалась.
    @discardableResult
    func enqueue(_ event: SemetricsEvent) -> Bool {
        guard storedCount < maxSize else { return false }  // очередь переполнена — дропаем
        guard let payload = try? encoder.encode(event), Self.insert(db: db, payload: payload) else { return false }
        storedCount += 1
        return true
    }

    /// Первые `size` событий в порядке добавления. Из очереди не удаляются.
    func peekBatch(_ size: Int) -> [QueuedEvent] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, payload FROM queued_events ORDER BY id LIMIT ?", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(size))

        var result: [QueuedEvent] = []
        var corrupted: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let bytes = sqlite3_column_blob(stmt, 1)
            let length = Int(sqlite3_column_bytes(stmt, 1))
            let data = bytes.map { Data(bytes: $0, count: length) } ?? Data()
            if let event = try? decoder.decode(SemetricsEvent.self, from: data) {
                result.append(QueuedEvent(id: id, event: event))
            } else {
                corrupted.append(id)
            }
        }
        if !corrupted.isEmpty { delete(ids: corrupted) }  // битую строку не отправить никогда
        return result
    }

    /// Удалить события (после успешной отправки или отказа сервера).
    func delete(ids: [Int64]) {
        guard !ids.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM queued_events WHERE id IN (\(placeholders))", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        for (index, id) in ids.enumerated() {
            sqlite3_bind_int64(stmt, Int32(index + 1), id)
        }
        if sqlite3_step(stmt) == SQLITE_DONE {
            storedCount = max(0, storedCount - Int(sqlite3_changes(db)))
        }
    }

    var count: Int { storedCount }

    // MARK: - SQLite

    static func defaultPath() -> URL? {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        // На macOS Application Support общий для всех приложений — разделяем по bundle id
        var dir = support
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Semetrics", isDirectory: true)
            .appendingPathComponent("Semetrics", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir.appendingPathComponent("queue.sqlite")
    }

    private static func open(path: URL?) -> OpaquePointer? {
        if let path, let db = openDatabase(path.path) { return db }
        if path != nil {
            print("[Semetrics] Не удалось открыть очередь на диске, события будут храниться только в памяти")
        }
        return openDatabase(":memory:")
    }

    private static func openDatabase(_ path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        let schema = """
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;
            CREATE TABLE IF NOT EXISTS queued_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                payload BLOB NOT NULL,
                created_at REAL NOT NULL
            );
            """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        return db
    }

    private static func insert(db: OpaquePointer?, payload: Data) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO queued_events (payload, created_at) VALUES (?, ?)", -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        _ = payload.withUnsafeBytes { sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32(payload.count), SQLITE_TRANSIENT) }
        sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private static func countRows(db: OpaquePointer?) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM queued_events", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    /// Перенести очередь из UserDefaults (SDK ≤ 0.4.x) в SQLite одной транзакцией.
    private static func migrateLegacy(db: OpaquePointer?, defaults: UserDefaults) {
        guard let data = defaults.data(forKey: legacyUserDefaultsKey) else { return }
        guard let events = try? JSONDecoder().decode([SemetricsEvent].self, from: data) else {
            defaults.removeObject(forKey: legacyUserDefaultsKey)
            return
        }
        let encoder = JSONEncoder()
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        for event in events {
            guard let payload = try? encoder.encode(event), insert(db: db, payload: payload) else {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                return  // оставляем UserDefaults — попробуем при следующем запуске
            }
        }
        if sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK {
            defaults.removeObject(forKey: legacyUserDefaultsKey)
        }
    }
}
