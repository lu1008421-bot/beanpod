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

    /// 头像颜色按 UUID 稳定映射（跨天、改名、重启不变），不随机。
    nonisolated static func colorIndex(for id: UUID) -> Int {
        withUnsafeBytes(of: id.uuid) { bytes in bytes.reduce(0) { ($0 + Int($1)) % 6 } }
    }

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

    /// 预处理一条语句，把参数依次绑到 `?` 上。所有带值的查询都走这里，不拼字符串。
    /// 调用方负责 `sqlite3_finalize`。
    private func prepare(_ sql: String, _ args: [String?] = []) throws -> OpaquePointer {
        guard let db else { throw Error.openFailed("not open") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw Error.sql(String(cString: sqlite3_errmsg(db))) }
        for (i, a) in args.enumerated() { bind(stmt, Int32(i + 1), a) }
        return stmt
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
        let color = colorIndex ?? Self.colorIndex(for: id)
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
        let whereSQL = status == nil ? "" : " WHERE status=?"
        return try queryPersons("SELECT id,display_name,stranger_index,color_index,status,is_me,note,created_at,last_met_at FROM persons\(whereSQL) ORDER BY stranger_index;",
                                args: [status?.rawValue])
    }

    func person(id: UUID) throws -> Person? {
        try queryPersons("SELECT id,display_name,stranger_index,color_index,status,is_me,note,created_at,last_met_at FROM persons WHERE id=?;",
                         args: [id.uuidString]).first
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

    /// 删除人物卡并级联清掉其声音样本、发言归属与资料。
    func deletePersonCascade(id: UUID) throws {
        try transaction { try cascadeDelete(id: id) }
    }

    /// 级联删除的几条语句本身（给已经在事务里的调用方用）。
    private func cascadeDelete(id: UUID) throws {
        try update("DELETE FROM voice_samples WHERE person_id=?;", args: [id.uuidString])
        try update("DELETE FROM utterances WHERE person_id=?;", args: [id.uuidString])
        try update("DELETE FROM person_insights WHERE person_id=?;", args: [id.uuidString])
        try update("DELETE FROM persons WHERE id=?;", args: [id.uuidString])
    }

    private func queryPersons(_ sql: String, args: [String?] = []) throws -> [Person] {
        let stmt = try prepare(sql, args)
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

    /// 存一段声音样本。同一个人已有相同内容（`contentHash` 相同）的样本时不再入库，返回 false。
    @discardableResult
    func addSample(_ s: VoiceSample, embedding: [Float]?) throws -> Bool {
        if !s.contentHash.isEmpty, try sampleExists(personID: s.personID, contentHash: s.contentHash) { return false }
        let stmt = try prepare("INSERT INTO voice_samples(id,person_id,source_kind,recording_id,start_ms,end_ms,managed_file,channel,confirmed,model_version,embedding,content_hash) VALUES(?,?,?,?,?,?,?,?,?,?,?,?);")
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
        guard let db, sqlite3_step(stmt) == SQLITE_DONE else { throw Error.sql("insert sample") }
        return true
    }

    func sampleExists(personID: UUID, contentHash: String) throws -> Bool {
        let stmt = try prepare("SELECT 1 FROM voice_samples WHERE person_id=? AND content_hash=? LIMIT 1;", [personID.uuidString, contentHash])
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// 把一个人的全部样本标为已确认（用户认下了这个人，TA 名下的声音就可以当标准声纹用）。
    func confirmSamples(personID: UUID) throws {
        try update("UPDATE voice_samples SET confirmed=1 WHERE person_id=?;", args: [personID.uuidString])
    }

    func listSamples(personID: UUID) throws -> [VoiceSample] {
        let stmt = try prepare("SELECT id,person_id,source_kind,recording_id,start_ms,end_ms,managed_file,channel,confirmed,model_version,content_hash FROM voice_samples WHERE person_id=? ORDER BY start_ms;", [personID.uuidString])
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
        let stmt = try prepare("SELECT embedding FROM voice_samples WHERE person_id=? AND embedding IS NOT NULL ORDER BY confirmed DESC, start_ms;", [personID.uuidString])
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
        let stmt = try prepare("SELECT embedding FROM voice_samples WHERE person_id=? AND confirmed=1 AND embedding IS NOT NULL ORDER BY start_ms;", [personID.uuidString])
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

    /// 只替换自动归属（`source != 'manual'`），保留人工指定的区间与人物归属（重转写不覆盖人工）。
    func replaceAutoUtterances(recordingID: UInt32, _ utterances: [Utterance]) throws {
        try transaction {
            try update("DELETE FROM utterances WHERE recording_id=? AND source!='manual';", args: [String(recordingID)])
            for u in utterances { try insertUtterance(u) }
        }
    }

    /// 插入一条发言归属。
    func insertUtterance(_ u: Utterance) throws {
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

    /// 把某条录音里某个本地说话人尚未归属（person_id 为空）的发言整批归属到某人物。
    func assignUtterancesByLocalSpeaker(recordingID: UInt32, localSpeaker: Int, personID: UUID) throws {
        guard let db else { throw Error.openFailed("not open") }
        var stmt: OpaquePointer?
        let sql = "UPDATE utterances SET person_id=?, source='auto' WHERE recording_id=? AND local_speaker=? AND person_id IS NULL;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw Error.sql(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, personID.uuidString)
        sqlite3_bind_int64(stmt, 2, Int64(recordingID))
        sqlite3_bind_int64(stmt, 3, Int64(localSpeaker))
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw Error.sql(String(cString: sqlite3_errmsg(db))) }
    }

    /// 采纳「疑似某人」在库里的部分：这个声音在这条录音里的发言全部改归 `candidateID`，
    /// 它自己那张待认识卡并掉。只删这一张（按录音 + 本地说话人查），同一条录音里别的待认识卡不动。
    func acceptSuggestion(recordingID: UInt32, localSpeaker: Int, candidateID: UUID) throws {
        try transaction {
            // 先记下它自己的待认识卡：发言一改归属就查不到了
            let own = try pendingPersonID(recordingID: recordingID, localSpeaker: localSpeaker)
            if let own {
                // 发言先从待认识卡名下转过去；直接删卡会把发言一起删掉
                try update("UPDATE utterances SET person_id=? WHERE recording_id=? AND local_speaker=? AND person_id=?;",
                           args: [candidateID.uuidString, String(recordingID), String(localSpeaker), own.uuidString])
            }
            try assignUtterancesByLocalSpeaker(recordingID: recordingID, localSpeaker: localSpeaker, personID: candidateID)
            if let own { try cascadeDelete(id: own) }
        }
    }

    /// 某条录音里某个本地说话人现在关联的待认识人物；不是待认识卡（或没归属）就返回 nil。
    func pendingPersonID(recordingID: UInt32, localSpeaker: Int) throws -> UUID? {
        let stmt = try prepare("SELECT u.person_id FROM utterances u JOIN persons p ON p.id = u.person_id "
                               + "WHERE u.recording_id = ? AND u.local_speaker = ? AND p.status = ? LIMIT 1;",
                               [String(recordingID), String(localSpeaker), PersonStatus.pending.rawValue])
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return UUID(uuidString: text(stmt, 0))
    }

    func listUtterances(recordingID: UInt32) throws -> [Utterance] {
        let stmt = try prepare("SELECT id,recording_id,audio_fingerprint,start_ms,end_ms,local_speaker,overlap,person_id,source,score,model_version FROM utterances WHERE recording_id=? ORDER BY start_ms;", [String(recordingID)])
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

    /// 级联删除一条录音的派生数据（发言归属、人物资料、源自该录音的声音样本）。
    /// 独立导入的音频样本不在此列（其 `recording_id` 为空）。
    func deleteRecordingData(recordingID: UInt32) throws {
        try transaction {
            try update("DELETE FROM utterances WHERE recording_id=?;", args: [String(recordingID)])
            try update("DELETE FROM person_insights WHERE recording_id=?;", args: [String(recordingID)])
            try update("DELETE FROM voice_samples WHERE recording_id=?;", args: [String(recordingID)])
        }
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
        let stmt = try prepare("SELECT id,person_id,kind,text,recording_id,start_ms,end_ms,occurred_at,edited_by_user,model_version,stale FROM person_insights WHERE person_id=? ORDER BY occurred_at IS NULL, occurred_at DESC, id;", [personID.uuidString])
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

    /// 软删除一条人物资料：标记 `stale=1` 且 `edited_by_user=1`，重跑模型不会恢复它。
    func hideInsight(id: UUID) throws {
        try update("UPDATE person_insights SET stale=1, edited_by_user=1 WHERE id=?;", args: [id.uuidString])
    }

    /// 人工编辑一条资料：写入新文本并标记人工，重跑不覆盖。
    func editInsight(id: UUID, text: String) throws {
        try update("UPDATE person_insights SET text=?, edited_by_user=1 WHERE id=?;", args: [text, id.uuidString])
    }

    /// 重跑一次录音的摘要：只清掉自动条目（`edited_by_user=0`）再插入新结果，人工编辑/删除的条目原样保留。
    func replaceAutoInsights(recordingID: UInt32, _ insights: [PersonInsight]) throws {
        try transaction {
            try update("DELETE FROM person_insights WHERE recording_id=? AND edited_by_user=0;", args: [String(recordingID)])
            for i in insights { try upsertInsight(i) }
        }
    }

    // MARK: - 时间线、纠错与合并

    /// 某个人物名下的全部发言归属（按录音、时间排序）。
    func listUtterancesForPerson(personID: UUID) throws -> [Utterance] {
        let stmt = try prepare("SELECT id,recording_id,audio_fingerprint,start_ms,end_ms,local_speaker,overlap,person_id,source,score,model_version FROM utterances WHERE person_id=? ORDER BY recording_id, start_ms;", [personID.uuidString])
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

    /// 批量改发言归属（同批纠正）。人工指定优先于自动重跑。
    func assignUtterances(_ ids: [UUID], personID: UUID?, source: String) throws {
        guard !ids.isEmpty else { return }
        try transaction {
            for id in ids { try assignUtterance(id: id, personID: personID, source: source) }
        }
    }

    /// 单句人工改归属后，把这句话的区间从原本地说话人的归属与旧人物的代表原声里精确剔除：
    /// 完全落在区间里的整条删除，部分重叠的裁掉重叠段（必要时一分为二）；
    /// 旧人物名下、来自该录音、与区间重叠的代表原声一并删除（它已经不再是干净的「这个人」的声音）。
    /// 其它说话人、其它时间区间、以及目标人物名下的数据一律不动。
    func carveManualRange(recordingID: UInt32, oldLocalSpeaker: Int, oldPersonID: UUID?, startMs: Int, endMs: Int) throws {
        try transaction {
            let overlapped = try listUtterances(recordingID: recordingID)
                .filter { $0.localSpeaker == oldLocalSpeaker && $0.endMs > startMs && $0.startMs < endMs }
            for u in overlapped {
                if u.startMs >= startMs && u.endMs <= endMs {
                    try update("DELETE FROM utterances WHERE id=?;", args: [u.id.uuidString])
                } else if u.startMs < startMs && u.endMs > endMs {
                    try update("UPDATE utterances SET end_ms=? WHERE id=?;", args: [String(startMs), u.id.uuidString])
                    let right = Utterance(id: UUID(), recordingID: u.recordingID, audioFingerprint: u.audioFingerprint,
                                          startMs: endMs, endMs: u.endMs, localSpeaker: u.localSpeaker, overlap: u.overlap,
                                          personID: u.personID, source: u.source, score: u.score, modelVersion: u.modelVersion)
                    try insertUtterance(right)
                } else if u.startMs < startMs {
                    try update("UPDATE utterances SET end_ms=? WHERE id=?;", args: [String(startMs), u.id.uuidString])
                } else {
                    try update("UPDATE utterances SET start_ms=? WHERE id=?;", args: [String(endMs), u.id.uuidString])
                }
            }
            if let oldPersonID {
                try update("DELETE FROM voice_samples WHERE person_id=? AND recording_id=? AND source_kind='recordingSpan' AND end_ms>? AND start_ms<?;",
                           args: [oldPersonID.uuidString, String(recordingID), String(startMs), String(endMs)])
            }
        }
    }

    private struct MergeSnapshot: Codable {
        struct PersonFields: Codable {
            var displayName: String
            var strangerIndex: Int
            var colorIndex: Int
            var status: String
            var isMe: Bool
            var note: String
            var createdAt: TimeInterval
            var lastMetAt: TimeInterval?
        }
        var primary: UUID
        var secondary: UUID
        var secondaryFields: PersonFields
        var samples: [UUID]
        var utterances: [UUID]
        var insights: [UUID]
    }

    private func personIDs(_ sql: String, _ args: [String?] = []) throws -> [UUID] {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        var out: [UUID] = []
        while sqlite3_step(stmt) == SQLITE_ROW { if let u = UUID(uuidString: text(stmt, 0)) { out.append(u) } }
        return out
    }

    private func insertJob(id: String, kind: String, payload: String?) throws {
        guard let db else { throw Error.openFailed("not open") }
        var stmt: OpaquePointer?
        let sql = "INSERT INTO jobs_and_audits(id,kind,input_fingerprint,model_version,rule_version,progress,failure,payload,created_at) VALUES(?,?,NULL,NULL,NULL,NULL,NULL,?,?);"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw Error.sql(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, id)
        bind(stmt, 2, kind)
        bind(stmt, 3, payload)
        sqlite3_bind_double(stmt, 4, Date.now.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw Error.sql(String(cString: sqlite3_errmsg(db))) }
    }

    private func jobPayload(id: String) throws -> String? {
        let stmt = try prepare("SELECT payload FROM jobs_and_audits WHERE id=?;", [id])
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_type(stmt, 0) == SQLITE_NULL ? nil : text(stmt, 0)
    }

    private func insertPersonSnapshot(id: UUID, s: MergeSnapshot.PersonFields) throws {
        guard let db else { throw Error.openFailed("not open") }
        var stmt: OpaquePointer?
        let sql = "INSERT INTO persons(id,display_name,stranger_index,color_index,status,is_me,note,created_at,last_met_at) VALUES(?,?,?,?,?,?,?,?,?);"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw Error.sql(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, id.uuidString)
        bind(stmt, 2, s.displayName)
        sqlite3_bind_int64(stmt, 3, Int64(s.strangerIndex))
        sqlite3_bind_int64(stmt, 4, Int64(s.colorIndex))
        bind(stmt, 5, s.status)
        sqlite3_bind_int(stmt, 6, s.isMe ? 1 : 0)
        bind(stmt, 7, s.note)
        sqlite3_bind_double(stmt, 8, s.createdAt)
        if let lm = s.lastMetAt { sqlite3_bind_double(stmt, 9, lm) } else { sqlite3_bind_null(stmt, 9) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw Error.sql(String(cString: sqlite3_errmsg(db))) }
    }

    /// 把次要人物合并进主要人物（样本/发言/资料归主卡，删次要卡），返回 merge_log 编号供撤销。
    @discardableResult
    func mergePersons(primary: UUID, secondary: UUID) throws -> String {
        guard primary != secondary else { throw Error.sql("不能合并同一个人") }
        guard let sec = try person(id: secondary) else { throw Error.sql("要合并的人物不存在") }
        let samples = try personIDs("SELECT id FROM voice_samples WHERE person_id=?;", [secondary.uuidString])
        let utterances = try personIDs("SELECT id FROM utterances WHERE person_id=?;", [secondary.uuidString])
        let insights = try personIDs("SELECT id FROM person_insights WHERE person_id=?;", [secondary.uuidString])
        let logID = UUID().uuidString
        let snap = MergeSnapshot(
            primary: primary, secondary: secondary,
            secondaryFields: .init(displayName: sec.displayName, strangerIndex: sec.strangerIndex, colorIndex: sec.colorIndex,
                                   status: sec.status.rawValue, isMe: sec.isMe, note: sec.note,
                                   createdAt: sec.createdAt.timeIntervalSince1970, lastMetAt: sec.lastMetAt?.timeIntervalSince1970),
            samples: samples, utterances: utterances, insights: insights)
        let payload = String(data: try JSONEncoder().encode(snap), encoding: .utf8)
        try transaction {
            try update("UPDATE voice_samples SET person_id=? WHERE person_id=?;", args: [primary.uuidString, secondary.uuidString])
            try update("UPDATE utterances SET person_id=? WHERE person_id=?;", args: [primary.uuidString, secondary.uuidString])
            try update("UPDATE person_insights SET person_id=? WHERE person_id=?;", args: [primary.uuidString, secondary.uuidString])
            try update("DELETE FROM persons WHERE id=?;", args: [secondary.uuidString])
            try insertJob(id: logID, kind: "merge_log", payload: payload)
        }
        return logID
    }

    /// 撤销一次合并：重建次要人物（沿用原编号/颜色），把合并前归它的样本/发言/资料挪回，不伤合并后新增的其它内容。
    func undoMerge(logID: String) throws {
        guard let payload = try jobPayload(id: logID),
              let data = payload.data(using: .utf8),
              let snap = try? JSONDecoder().decode(MergeSnapshot.self, from: data) else {
            throw Error.sql("找不到这次合并记录")
        }
        try transaction {
            try insertPersonSnapshot(id: snap.secondary, s: snap.secondaryFields)
            for id in snap.samples { try update("UPDATE voice_samples SET person_id=? WHERE id=? AND person_id=?;", args: [snap.secondary.uuidString, id.uuidString, snap.primary.uuidString]) }
            for id in snap.utterances { try update("UPDATE utterances SET person_id=? WHERE id=? AND person_id=?;", args: [snap.secondary.uuidString, id.uuidString, snap.primary.uuidString]) }
            for id in snap.insights { try update("UPDATE person_insights SET person_id=? WHERE id=? AND person_id=?;", args: [snap.secondary.uuidString, id.uuidString, snap.primary.uuidString]) }
            try update("DELETE FROM jobs_and_audits WHERE id=?;", args: [logID])
        }
    }

    /// 尚未撤销的合并记录（供「撤销上次合并」入口）。
    func pendingMergeLogs() throws -> [(id: String, primary: UUID, secondary: UUID)] {
        guard let db else { throw Error.openFailed("not open") }
        var stmt: OpaquePointer?
        let sql = "SELECT id, payload FROM jobs_and_audits WHERE kind='merge_log' ORDER BY created_at DESC;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw Error.sql(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        var out: [(id: String, primary: UUID, secondary: UUID)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = text(stmt, 0)
            if sqlite3_column_type(stmt, 1) != SQLITE_NULL,
               let data = text(stmt, 1).data(using: .utf8),
               let snap = try? JSONDecoder().decode(MergeSnapshot.self, from: data) {
                out.append((id, snap.primary, snap.secondary))
            }
        }
        return out
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
        let stmt = try prepare("SELECT payload FROM jobs_and_audits WHERE kind=? AND payload IS NOT NULL ORDER BY created_at;", ["rejected_pair"])
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(text(stmt, 0)) }
        return out
    }

    /// 还没处理的「建议确认」：某个新声音像某位已有人物，等人点一下。
    func listSuggestions() throws -> [SpeakerSuggestion] {
        let stmt = try prepare("SELECT id,payload FROM jobs_and_audits WHERE kind=? ORDER BY created_at;", ["speaker_suggestion"])
        defer { sqlite3_finalize(stmt) }
        var out: [SpeakerSuggestion] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if var s = SpeakerSuggestion.parse(text(stmt, 1)) { s.id = text(stmt, 0); out.append(s) }
        }
        return out
    }

    func deleteJob(id: String) throws {
        try update("DELETE FROM jobs_and_audits WHERE id=?;", args: [id])
    }

    /// 取出某个人的受管样本文件名（删样本时顺带删磁盘文件用）。
    func sampleFile(id: UUID) throws -> String? {
        let stmt = try prepare("SELECT managed_file FROM voice_samples WHERE id=?;", [id.uuidString])
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
        return text(stmt, 0)
    }

    // MARK: - 浮点向量 <-> BLOB

    nonisolated static func floatsToData(_ v: [Float]) -> Data {
        v.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    nonisolated static func dataToFloats(_ d: Data) -> [Float] {
        d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
