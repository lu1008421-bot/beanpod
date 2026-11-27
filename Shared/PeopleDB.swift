import Foundation
import SQLite3

/// 人物库：跨录音人物身份的唯一权威源。SQLite 存储，WAL 模式，`PRAGMA user_version` 做迁移。
/// 只依赖 Foundation + 系统 `SQLite3`，可独立单元测试。
///
/// 打开时校验 `quick_check`：数据库损坏或 `user_version` 高于本程序支持时抛可恢复错误，
/// 绝不静默清空或覆盖用户数据。
nonisolated final class PeopleDB {
    enum Error: LocalizedError {
        case openFailed(String)
        case corrupt(String)
        case tooNew(Int)
        case sql(String)
        case notFound(UUID)

        var errorDescription: String? {
            switch self {
            case .openFailed(let m): String(localized: "人物库打不开：\(m)")
            case .corrupt(let m): String(localized: "人物库已损坏：\(m)")
            case .tooNew(let v): String(localized: "人物库版本（\(v)）比这个 App 新，请升级 App 后再打开")
            case .sql(let m): String(localized: "人物库出错：\(m)")
            case .notFound(let id): String(localized: "找不到人物 \(id)")
            }
        }
    }

    static let schemaVersion = 1

    let folder: URL
    let dbURL: URL
    private var db: OpaquePointer?

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(folder: URL) throws {
        self.folder = folder
        self.dbURL = folder.appendingPathComponent("people.sqlite")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try open()
        try migrate()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - 打开与迁移

    private func open() throws {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(dbURL.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            if let handle { sqlite3_close(handle) }
            throw Error.openFailed(msg)
        }
        db = handle
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA foreign_keys=ON;")
        // 损坏检测：不通过就报错，不清空不覆盖
        let check = quickCheck()
        guard check == "ok" else { throw Error.corrupt(check) }
    }

    private func quickCheck() -> String {
        guard let db else { return "no db" }
        var stmt: OpaquePointer?
        var out = "unknown"
        if sqlite3_prepare_v2(db, "PRAGMA quick_check;", -1, &stmt, nil) == SQLITE_OK, let stmt {
            if sqlite3_step(stmt) == SQLITE_ROW, let p = sqlite3_column_text(stmt, 0) {
                out = String(cString: p)
            }
        }
        sqlite3_finalize(stmt)
        return out
    }

    private func migrate() throws {
        var version: Int32 = 0
        if let v = scalarInt("PRAGMA user_version;") { version = Int32(v) }
        if version > Int32(Self.schemaVersion) { throw Error.tooNew(Int(version)) }

        if version < 1 {
            try transaction {
                try exec(schemaSQL)
                try exec("PRAGMA user_version = \(Self.schemaVersion);")
            }
        }
    }

    private var schemaSQL: String {
        """
        CREATE TABLE IF NOT EXISTS persons (
          id TEXT PRIMARY KEY,
          display_name TEXT NOT NULL DEFAULT '',
          stranger_index INTEGER NOT NULL,
          color_index INTEGER NOT NULL DEFAULT 0,
          status TEXT NOT NULL DEFAULT 'pending',
          is_me INTEGER NOT NULL DEFAULT 0,
          note TEXT NOT NULL DEFAULT '',
          created_at REAL NOT NULL,
          last_met_at REAL
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_persons_stranger ON persons(stranger_index);
        CREATE UNIQUE INDEX IF NOT EXISTS idx_persons_me ON persons(is_me) WHERE is_me = 1;

        CREATE TABLE IF NOT EXISTS voice_samples (
          id TEXT PRIMARY KEY,
          person_id TEXT NOT NULL REFERENCES persons(id) ON DELETE CASCADE,
          source_kind TEXT NOT NULL,
          recording_id INTEGER,
          start_ms INTEGER NOT NULL,
          end_ms INTEGER NOT NULL,
          managed_file TEXT,
          channel TEXT NOT NULL DEFAULT 'unknown',
          confirmed INTEGER NOT NULL DEFAULT 0,
          model_version TEXT NOT NULL DEFAULT '',
          embedding BLOB,
          content_hash TEXT NOT NULL DEFAULT ''
        );
        CREATE INDEX IF NOT EXISTS idx_samples_person ON voice_samples(person_id);

        CREATE TABLE IF NOT EXISTS utterances (
          id TEXT PRIMARY KEY,
          recording_id INTEGER NOT NULL,
          audio_fingerprint TEXT NOT NULL,
          start_ms INTEGER NOT NULL,
          end_ms INTEGER NOT NULL,
          local_speaker INTEGER NOT NULL,
          overlap INTEGER NOT NULL DEFAULT 0,
          person_id TEXT REFERENCES persons(id) ON DELETE SET NULL,
          source TEXT NOT NULL DEFAULT 'auto',
          score REAL NOT NULL DEFAULT 0,
          model_version TEXT NOT NULL DEFAULT ''
        );
        CREATE INDEX IF NOT EXISTS idx_utterances_recording ON utterances(recording_id);

        CREATE TABLE IF NOT EXISTS person_insights (
          id TEXT PRIMARY KEY,
          person_id TEXT NOT NULL REFERENCES persons(id) ON DELETE CASCADE,
          kind TEXT NOT NULL,
          text TEXT NOT NULL,
          recording_id INTEGER,
          start_ms INTEGER,
          end_ms INTEGER,
          occurred_at REAL,
          edited_by_user INTEGER NOT NULL DEFAULT 0,
          model_version TEXT NOT NULL DEFAULT '',
          stale INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_insights_person ON person_insights(person_id);

        CREATE TABLE IF NOT EXISTS jobs_and_audits (
          id TEXT PRIMARY KEY,
          kind TEXT NOT NULL,
          input_fingerprint TEXT,
          model_version TEXT,
          rule_version TEXT,
          progress REAL,
          failure TEXT,
          rejected_pairs TEXT,
          payload TEXT,
          created_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_jobs_kind ON jobs_and_audits(kind);

        CREATE TABLE IF NOT EXISTS meta (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
        """
    }

    // MARK: - 底层助手

    private func exec(_ sql: String) throws {
        guard let db else { throw Error.openFailed("not open") }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw Error.sql(msg)
        }
    }

    private func scalarInt(_ sql: String) -> Int64? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE;")
        do {
            let r = try body()
            try exec("COMMIT;")
            return r
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private func text(_ stmt: OpaquePointer, _ i: Int32) -> String {
        guard let p = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: UnsafeRawPointer(p).assumingMemoryBound(to: CChar.self))
    }

    private func bind(_ stmt: OpaquePointer, _ i: Int32, _ s: String?) {
        if let s { sqlite3_bind_text(stmt, i, s, -1, Self.transient) }
        else { sqlite3_bind_null(stmt, i) }
    }

    // MARK: - 人物

    /// 取下一个不回收的陌生人编号（0→A）。计数器存 meta，跨重启稳定。
    func nextStrangerIndex() throws -> Int {
        try transaction {
            let current = scalarInt("SELECT CAST(value AS INTEGER) FROM meta WHERE key='stranger_counter';") ?? -1
            let next = current + 1
            let key = "stranger_counter"
            var stmt: OpaquePointer?
            guard let db, sqlite3_prepare_v2(db, "INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;", -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw Error.sql(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, key)
            bind(stmt, 2, String(next))
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw Error.sql(String(cString: sqlite3_errmsg(db))) }
            return Int(next)
        }
    }

    @discardableResult
    func createPerson(displayName: String, status: PersonStatus = .pending, isMe: Bool = false, note: String = "", colorIndex: Int? = nil, strangerIndex: Int? = nil) throws -> Person {
        let id = UUID()
        let idx = try strangerIndex ?? nextStrangerIndex()
        let color = colorIndex ?? Int.random(in: 0..<6)
        var stmt: OpaquePointer?
        guard let db, sqlite3_prepare_v2(db, "INSERT INTO persons(id,display_name,stranger_index,color_index,status,is_me,note,created_at) VALUES(?,?,?,?,?,?,?,?);", -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw Error.sql(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, id.uuidString)
        bind(stmt, 2, displayName)
        sqlite3_bind_int64(stmt, 3, Int64(idx))
        sqlite3_bind_int64(stmt, 4, Int64(color))
        bind(stmt, 5, status.rawValue)
        sqlite3_bind_int(stmt, 6, isMe ? 1 : 0)
        bind(stmt, 7, note)
        sqlite3_bind_double(stmt, 8, Date.now.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw Error.sql(String(cString: sqlite3_errmsg(db))) }
        return Person(id: id, displayName: displayName, strangerIndex: idx, colorIndex: color, status: status, isMe: isMe, note: note, createdAt: .now, lastMetAt: nil)
    }

    func listPersons(status: PersonStatus? = nil) throws -> [Person] {
        let whereSQL = status.map { " WHERE status='\($0.rawValue)'" } ?? ""
        return try queryPersons("SELECT id,display_name,stranger_index,color_index,status,is_me,note,created_at,last_met_at FROM persons\(whereSQL) ORDER BY stranger_index;")
    }

    func person(id: UUID) throws -> Person? {
        try queryPersons("SELECT id,display_name,stranger_index,color_index,status,is_me,note,created_at,last_met_at FROM persons WHERE id='\(id.uuidString)';").first
    }

    func renamePerson(id: UUID, to name: String) throws {
        try update("UPDATE persons SET display_name=? WHERE id=?;", args: [name, id.uuidString])
    }

    func setPersonStatus(id: UUID, _ status: PersonStatus) throws {
        try update("UPDATE persons SET status=? WHERE id=?;", args: [status.rawValue, id.uuidString])
    }

    func setMe(id: UUID?) throws {
        try transaction {
            try update("UPDATE persons SET is_me=0 WHERE is_me=1;", args: [])
            if let id { try update("UPDATE persons SET is_me=1 WHERE id=?;", args: [id.uuidString]) }
        }
    }

    func setPersonNote(id: UUID, _ note: String) throws {
        try update("UPDATE persons SET note=? WHERE id=?;", args: [note, id.uuidString])
    }

    func setPersonColor(id: UUID, _ colorIndex: Int) throws {
        try update("UPDATE persons SET color_index=? WHERE id=?;", args: [String(colorIndex), id.uuidString])
    }

    func setLastMet(id: UUID, _ date: Date?) throws {
        if let date {
            try update("UPDATE persons SET last_met_at=? WHERE id=?;", args: [String(date.timeIntervalSince1970), id.uuidString])
        } else {
            try update("UPDATE persons SET last_met_at=NULL WHERE id=?;", args: [id.uuidString])
        }
    }

    func deletePerson(id: UUID) throws {
        try update("DELETE FROM persons WHERE id=?;", args: [id.uuidString])
    }

    private func queryPersons(_ sql: String) throws -> [Person] {
        guard let db else { throw Error.openFailed("not open") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw Error.sql(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        var out: [Person] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let status = PersonStatus(rawValue: text(stmt, 4)) ?? .pending
            let lastMet = sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))
            out.append(Person(
                id: UUID(uuidString: text(stmt, 0)) ?? UUID(),
                displayName: text(stmt, 1),
                strangerIndex: Int(sqlite3_column_int64(stmt, 2)),
                colorIndex: Int(sqlite3_column_int64(stmt, 3)),
                status: status,
                isMe: sqlite3_column_int(stmt, 5) != 0,
                note: text(stmt, 6),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7)),
                lastMetAt: lastMet))
        }
        return out
    }

    private func update(_ sql: String, args: [String]) throws {
        guard let db else { throw Error.openFailed("not open") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw Error.sql(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        for (i, a) in args.enumerated() { bind(stmt, Int32(i + 1), a) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw Error.sql(String(cString: sqlite3_errmsg(db))) }
    }

    // MARK: - 声音样本

    func addSample(_ s: VoiceSample, embedding: [Float]?) throws {
        guard let db else { throw Error.openFailed("not open") }
        var stmt: OpaquePointer?
        let sql = "INSERT INTO voice_samples(id,person_id,source_kind,recording_id,start_ms,end_ms,managed_file,channel,confirmed,model_version,embedding,content_hash) VALUES(?,?,?,?,?,?,?,?,?,?,?,?);"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw Error.sql(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, s.id.uuidString)
        bind(stmt, 2, s.personID.uuidString)
        bind(stmt, 3, s.sourceKind.rawValue)
        if let r = s.recordingID { sqlite3_bind_int64(stmt, 4, Int64(r)) } else { sqlite3_bind_null(stmt, 4) }
        sqlite3_bind_int64(stmt, 5, Int64(s.startMs))
        sqlite3_bind_int64(stmt, 6, Int64(s.endMs))
        bind(stmt, 7, s.managedFile)
        bind(stmt, 8, s.channel.rawValue)
        sqlite3_bind_int(stmt, 9, s.confirmed ? 1 : 0)
        bind(stmt, 10, s.modelVersion)
        if let embedding {
            let data = Self.floatsToData(embedding)
            data.withUnsafeBytes { sqlite3_bind_blob(stmt, 11, $0.baseAddress, Int32(data.count), Self.transient) }
        } else {
            sqlite3_bind_null(stmt, 11)
        }
        bind(stmt, 12, s.contentHash)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw Error.sql(String(cString: sqlite3_errmsg(db))) }
    }

    func listSamples(personID: UUID) throws -> [VoiceSample] {
        guard let db else { throw Error.openFailed("not open") }
        var stmt: OpaquePointer?
        let sql = "SELECT id,person_id,source_kind,recording_id,start_ms,end_ms,managed_file,channel,confirmed,model_version,content_hash FROM voice_samples WHERE person_id='\(personID.uuidString)' ORDER BY start_ms;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw Error.sql(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        var out: [VoiceSample] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(VoiceSample(
                id: UUID(uuidString: text(stmt, 0)) ?? UUID(),
                personID: UUID(uuidString: text(stmt, 1)) ?? personID,
                sourceKind: VoiceSampleSourceKind(rawValue: text(stmt, 2)) ?? .recordingSpan,
                recordingID: sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : UInt32(sqlite3_column_int64(stmt, 3)),
                startMs: Int(sqlite3_column_int64(stmt, 4)),
                endMs: Int(sqlite3_column_int64(stmt, 5)),
                managedFile: sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : text(stmt, 6),
                channel: VoiceChannel(rawValue: text(stmt, 7)) ?? .unknown,
                confirmed: sqlite3_column_int(stmt, 8) != 0,
                modelVersion: text(stmt, 9),
                contentHash: text(stmt, 10)))
        }
        return out
    }

    func deleteSample(id: UUID) throws {
        try update("DELETE FROM voice_samples WHERE id=?;", args: [id.uuidString])
    }

    /// 读出一个人的全部声纹向量（含未确认样本；是否只用 confirmed 由上层决定）。
    func embeddings(personID: UUID) throws -> [[Float]] {
        guard let db else { throw Error.openFailed("not open") }
        var stmt: OpaquePointer?
        let sql = "SELECT embedding FROM voice_samples WHERE person_id='\(personID.uuidString)' AND embedding IS NOT NULL ORDER BY confirmed DESC, start_ms;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw Error.sql(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        var out: [[Float]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let p = sqlite3_column_blob(stmt, 0) {
                let len = Int(sqlite3_column_bytes(stmt, 0))
                let data = Data(bytes: p, count: len)
                out.append(Self.dataToFloats(data))
            }
        }
        return out
    }

    /// 已人工确认样本的声纹向量（用于标准声纹均值）。
    func confirmedEmbeddings(personID: UUID) throws -> [[Float]] {
        guard let db else { throw Error.openFailed("not open") }
        var stmt: OpaquePointer?
        let sql = "SELECT embedding FROM voice_samples WHERE person_id='\(personID.uuidString)' AND confirmed=1 AND embedding IS NOT NULL ORDER BY start_ms;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw Error.sql(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        var out: [[Float]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let p = sqlite3_column_blob(stmt, 0) {
                let len = Int(sqlite3_column_bytes(stmt, 0))
                out.append(Self.dataToFloats(Data(bytes: p, count: len)))
            }
        }
        return out
    }

    // MARK: - 发言归属

    /// 用一次事务整批替换一条录音的发言归属（重跑/重转写不残留脏数据）。
    func replaceUtterances(recordingID: UInt32, _ utterances: [Utterance]) throws {
        try transaction {
            try update("DELETE FROM utterances WHERE recording_id=?;", args: [String(recordingID)])
            for u in utterances {
                guard let db else { throw Error.openFailed("not open") }
                var stmt: OpaquePointer?
                let sql = "INSERT INTO utterances(id,recording_id,audio_fingerprint,start_ms,end_ms,local_speaker,overlap,person_id,source,score,model_version) VALUES(?,?,?,?,?,?,?,?,?,?,?);"
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw Error.sql(String(cString: sqlite3_errmsg(db))) }
                defer { sqlite3_finalize(stmt) }
                bind(stmt, 1, u.id.uuidString)
                sqlite3_bind_int64(stmt, 2, Int64(u.recordingID))
                bind(stmt, 3, u.audioFingerprint)
                sqlite3_bind_int64(stmt, 4, Int64(u.startMs))
                sqlite3_bind_int64(stmt, 5, Int64(u.endMs))
                sqlite3_bind_int64(stmt, 6, Int64(u.localSpeaker))
                sqlite3_bind_int(stmt, 7, u.overlap ? 1 : 0)
                bind(stmt, 8, u.personID?.uuidString)
                bind(stmt, 9, u.source)
                sqlite3_bind_double(stmt, 10, u.score)
                bind(stmt, 11, u.modelVersion)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw Error.sql(String(cString: sqlite3_errmsg(db))) }
            }
        }
    }

    func listUtterances(recordingID: UInt32) throws -> [Utterance] {
        guard let db else { throw Error.openFailed("not open") }
        var stmt: OpaquePointer?
        let sql = "SELECT id,recording_id,audio_fingerprint,start_ms,end_ms,local_speaker,overlap,person_id,source,score,model_version FROM utterances WHERE recording_id=\(recordingID) ORDER BY start_ms;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw Error.sql(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        var out: [Utterance] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(Utterance(
                id: UUID(uuidString: text(stmt, 0)) ?? UUID(),
                recordingID: UInt32(sqlite3_column_int64(stmt, 1)),
                audioFingerprint: text(stmt, 2),
                startMs: Int(sqlite3_column_int64(stmt, 3)),
                endMs: Int(sqlite3_column_int64(stmt, 4)),
                localSpeaker: Int(sqlite3_column_int64(stmt, 5)),
                overlap: sqlite3_column_int(stmt, 6) != 0,
                personID: sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : UUID(uuidString: text(stmt, 7)),
                source: text(stmt, 8),
                score: sqlite3_column_double(stmt, 9),
                modelVersion: text(stmt, 10)))
        }
        return out
    }

    func assignUtterance(id: UUID, personID: UUID?, source: String) throws {
        guard let db else { throw Error.openFailed("not open") }
        var stmt: OpaquePointer?
        let sql = "UPDATE utterances SET person_id=?, source=? WHERE id=?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw Error.sql(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, personID?.uuidString)
        bind(stmt, 2, source)
        bind(stmt, 3, id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw Error.sql(String(cString: sqlite3_errmsg(db))) }
    }

    // MARK: - 人物资料与往来

    func upsertInsight(_ insight: PersonInsight) throws {
        guard let db else { throw Error.openFailed("not open") }
        var stmt: OpaquePointer?
        let sql = "INSERT INTO person_insights(id,person_id,kind,text,recording_id,start_ms,end_ms,occurred_at,edited_by_user,model_version,stale) VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET text=excluded.text,recording_id=excluded.recording_id,start_ms=excluded.start_ms,end_ms=excluded.end_ms,occurred_at=excluded.occurred_at,stale=excluded.stale;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw Error.sql(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, insight.id.uuidString)
        bind(stmt, 2, insight.personID.uuidString)
        bind(stmt, 3, insight.kind.rawValue)
        bind(stmt, 4, insight.text)
        if let r = insight.recordingID { sqlite3_bind_int64(stmt, 5, Int64(r)) } else { sqlite3_bind_null(stmt, 5) }
        if let s = insight.startMs { sqlite3_bind_int64(stmt, 6, Int64(s)) } else { sqlite3_bind_null(stmt, 6) }
        if let e = insight.endMs { sqlite3_bind_int64(stmt, 7, Int64(e)) } else { sqlite3_bind_null(stmt, 7) }
        if let o = insight.occurredAt { sqlite3_bind_double(stmt, 8, o.timeIntervalSince1970) } else { sqlite3_bind_null(stmt, 8) }
        sqlite3_bind_int(stmt, 9, insight.editedByUser ? 1 : 0)
        bind(stmt, 10, insight.modelVersion)
        sqlite3_bind_int(stmt, 11, insight.stale ? 1 : 0)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw Error.sql(String(cString: sqlite3_errmsg(db))) }
    }

    func listInsights(personID: UUID) throws -> [PersonInsight] {
        guard let db else { throw Error.openFailed("not open") }
        var stmt: OpaquePointer?
        let sql = "SELECT id,person_id,kind,text,recording_id,start_ms,end_ms,occurred_at,edited_by_user,model_version,stale FROM person_insights WHERE person_id='\(personID.uuidString)' ORDER BY occurred_at IS NULL, occurred_at DESC, id;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw Error.sql(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        var out: [PersonInsight] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(PersonInsight(
                id: UUID(uuidString: text(stmt, 0)) ?? UUID(),
                personID: UUID(uuidString: text(stmt, 1)) ?? personID,
                kind: InsightKind(rawValue: text(stmt, 2)) ?? .bio,
                text: text(stmt, 3),
                recordingID: sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : UInt32(sqlite3_column_int64(stmt, 4)),
                startMs: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 5)),
                endMs: sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 6)),
                occurredAt: sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7)),
                editedByUser: sqlite3_column_int(stmt, 8) != 0,
                modelVersion: text(stmt, 9),
                stale: sqlite3_column_int(stmt, 10) != 0))
        }
        return out
    }

    func deleteInsight(id: UUID) throws {
        try update("DELETE FROM person_insights WHERE id=?;", args: [id.uuidString])
    }

    // MARK: - 作业与纠错

    func recordJob(kind: String, inputFingerprint: String? = nil, modelVersion: String? = nil, ruleVersion: String? = nil, progress: Double? = nil, failure: String? = nil, payload: String? = nil) throws {
        guard let db else { throw Error.openFailed("not open") }
        var stmt: OpaquePointer?
        let sql = "INSERT INTO jobs_and_audits(id,kind,input_fingerprint,model_version,rule_version,progress,failure,payload,created_at) VALUES(?,?,?,?,?,?,?,?,?);"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw Error.sql(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, UUID().uuidString)
        bind(stmt, 2, kind)
        bind(stmt, 3, inputFingerprint)
        bind(stmt, 4, modelVersion)
        bind(stmt, 5, ruleVersion)
        if let p = progress { sqlite3_bind_double(stmt, 6, p) } else { sqlite3_bind_null(stmt, 6) }
        bind(stmt, 7, failure)
        bind(stmt, 8, payload)
        sqlite3_bind_double(stmt, 9, Date.now.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw Error.sql(String(cString: sqlite3_errmsg(db))) }
    }

    func addRejectedPair(_ pair: String) throws {
        try recordJob(kind: "rejected_pair", payload: pair)
    }

    func rejectedPairs() throws -> [String] {
        guard let db else { throw Error.openFailed("not open") }
        var stmt: OpaquePointer?
        let sql = "SELECT payload FROM jobs_and_audits WHERE kind='rejected_pair' AND payload IS NOT NULL ORDER BY created_at;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw Error.sql(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(text(stmt, 0)) }
        return out
    }

    // MARK: - 浮点向量 <-> BLOB

    nonisolated static func floatsToData(_ v: [Float]) -> Data {
        v.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    nonisolated static func dataToFloats(_ d: Data) -> [Float] {
        d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
