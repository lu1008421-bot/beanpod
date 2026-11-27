import Foundation
import SQLite3
import XCTest

/// `PeopleDB` 的迁移与稳定性单元测试。每个用例在独立临时目录里跑，不碰正式人物库。
final class PeopleDBTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("beanpod-people-test-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func openDB() throws -> PeopleDB {
        try PeopleDB(folder: tempDir.appendingPathComponent("People", isDirectory: true))
    }

    /// 同一显示名的两个人可以共存，改名沿用 UUID。
    func testSameNameCoexistsAndRenameKeepsUUID() throws {
        let db = try openDB()
        let a = try db.createPerson(displayName: "王总", status: .confirmed)
        let b = try db.createPerson(displayName: "王总", status: .confirmed)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(try db.listPersons().filter { $0.displayName == "王总" }.count, 2)

        try db.renamePerson(id: a.id, to: "老王")
        let renamed = try XCTUnwrap(try db.person(id: a.id))
        XCTAssertEqual(renamed.displayName, "老王")
        XCTAssertEqual(renamed.id, a.id, "改名应沿用 UUID")
        XCTAssertEqual(try db.person(id: b.id)?.displayName, "王总")
    }

    /// 陌生人编号单调递增且不回收（删除最高编号后新建仍取下一个）。
    func testStrangerIndexNeverRecycled() throws {
        let db = try openDB()
        let a = try db.createPerson(displayName: "", status: .pending)
        let b = try db.createPerson(displayName: "", status: .pending)
        XCTAssertEqual(a.strangerIndex, 0)
        XCTAssertEqual(b.strangerIndex, 1)
        XCTAssertEqual(a.strangerLabel, "A")
        XCTAssertEqual(b.strangerLabel, "B")

        try db.deletePerson(id: b.id)
        let c = try db.createPerson(displayName: "", status: .pending)
        XCTAssertEqual(c.strangerIndex, 2, "编号不得回收")
        XCTAssertEqual(c.strangerLabel, "C")
    }

    /// 重启（关库再开库）后数据与编号保持稳定。
    func testReopenKeepsPersonsSamplesAndIndices() throws {
        let folder = tempDir.appendingPathComponent("People", isDirectory: true)
        var db = try PeopleDB(folder: folder)
        let p = try db.createPerson(displayName: "陈工", status: .confirmed)
        let sample = VoiceSample(
            id: UUID(), personID: p.id, sourceKind: .recordingSpan, recordingID: 1,
            startMs: 1000, endMs: 4000, managedFile: nil, channel: .nearField,
            confirmed: true, modelVersion: "cam++", contentHash: "abc")
        try db.addSample(sample, embedding: [0.1, 0.2, 0.3])
        // 让 deinit 关闭连接
        db = try PeopleDB(folder: folder)

        let persons = try db.listPersons()
        XCTAssertEqual(persons.count, 1)
        XCTAssertEqual(persons[0].displayName, "陈工")
        XCTAssertEqual(persons[0].strangerIndex, p.strangerIndex)
        let samples = try db.listSamples(personID: p.id)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].contentHash, "abc")
        let embs = try db.embeddings(personID: p.id)
        XCTAssertEqual(embs.count, 1)
        XCTAssertEqual(embs[0], [0.1, 0.2, 0.3])
    }

    /// 「我」全局至多一人。
    func testIsMeUnique() throws {
        let db = try openDB()
        let a = try db.createPerson(displayName: "甲")
        let b = try db.createPerson(displayName: "乙")
        try db.setMe(id: a.id)
        XCTAssertEqual(try db.person(id: a.id)?.isMe, true)
        try db.setMe(id: b.id)
        XCTAssertEqual(try db.person(id: a.id)?.isMe, false)
        XCTAssertEqual(try db.person(id: b.id)?.isMe, true)
    }

    /// 旧版本（user_version=0）空库会建表；高版本直接报可恢复错误，不清空。
    func testSchemaMigrationAndTooNew() throws {
        let folder = tempDir.appendingPathComponent("People", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dbURL = folder.appendingPathComponent("people.sqlite")
        // 手工造一个 user_version=0 的空库
        var raw: OpaquePointer?
        sqlite3_open_v2(dbURL.path, &raw, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        sqlite3_close(raw)
        let db = try PeopleDB(folder: folder)
        _ = try db.createPerson(displayName: "甲")
        XCTAssertEqual(try db.listPersons().count, 1)

        // 抬到 999 后重开应抛 tooNew
        var raw2: OpaquePointer?
        sqlite3_open_v2(dbURL.path, &raw2, SQLITE_OPEN_READWRITE, nil)
        sqlite3_exec(raw2, "PRAGMA user_version=999;", nil, nil, nil)
        sqlite3_close(raw2)
        XCTAssertThrowsError(try PeopleDB(folder: folder)) { error in
            guard case PeopleDB.Error.tooNew(let v) = error else {
                return XCTFail("应抛 tooNew，实际 \(error)")
            }
            XCTAssertEqual(v, 999)
        }

        // 数据仍在，未被清空（用原生 SQLite 直接查）
        var raw3: OpaquePointer?
        sqlite3_open_v2(dbURL.path, &raw3, SQLITE_OPEN_READWRITE, nil)
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(raw3, "SELECT COUNT(*) FROM persons;", -1, &stmt, nil)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(stmt, 0), 1, "人物数据不得被静默清空")
        sqlite3_finalize(stmt)
        sqlite3_close(raw3)
    }

    /// 损坏的数据库文件要报错而不是静默重建。
    func testCorruptDBThrows() throws {
        let folder = tempDir.appendingPathComponent("People", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dbURL = folder.appendingPathComponent("people.sqlite")
        try Data("这不是一个 SQLite 文件".utf8).write(to: dbURL)
        XCTAssertThrowsError(try PeopleDB(folder: folder))
    }

    /// 重复整批写发言不残留脏数据（事务替换）。
    func testReplaceUtterancesIsAtomic() throws {
        let db = try openDB()
        let u1 = Utterance(id: UUID(), recordingID: 7, audioFingerprint: "f", startMs: 0, endMs: 1000, localSpeaker: 0, overlap: false, personID: nil, source: "auto", score: 0.9, modelVersion: "v1")
        let u2 = Utterance(id: UUID(), recordingID: 7, audioFingerprint: "f", startMs: 1000, endMs: 2000, localSpeaker: 1, overlap: false, personID: nil, source: "auto", score: 0.8, modelVersion: "v1")
        try db.replaceUtterances(recordingID: 7, [u1, u2])
        XCTAssertEqual(try db.listUtterances(recordingID: 7).count, 2)
        try db.replaceUtterances(recordingID: 7, [u1])
        XCTAssertEqual(try db.listUtterances(recordingID: 7).count, 1)
        XCTAssertEqual(try db.listUtterances(recordingID: 7)[0].id, u1.id)
    }

    /// 彻底删除一条录音时，级联清掉它的发言、资料与源自它的声音样本；独立导入的样本不受影响。
    func testDeleteRecordingDataCascades() throws {
        let db = try openDB()
        let p = try db.createPerson(displayName: "李四", status: .confirmed)
        let recSample = VoiceSample(
            id: UUID(), personID: p.id, sourceKind: .recordingSpan, recordingID: 42,
            startMs: 0, endMs: 3000, managedFile: nil, channel: .nearField,
            confirmed: false, modelVersion: "cam++", contentHash: "r")
        let imported = VoiceSample(
            id: UUID(), personID: p.id, sourceKind: .importedFile, recordingID: nil,
            startMs: 0, endMs: 5000, managedFile: nil, channel: .nearField,
            confirmed: true, modelVersion: "cam++", contentHash: "i")
        try db.addSample(recSample, embedding: nil)
        try db.addSample(imported, embedding: nil)
        try db.upsertInsight(PersonInsight(
            id: UUID(), personID: p.id, kind: .commitment, text: "下周交报告",
            recordingID: 42, startMs: 1000, endMs: 2000, occurredAt: .now,
            editedByUser: false, modelVersion: "v1", stale: false))
        let u = Utterance(id: UUID(), recordingID: 42, audioFingerprint: "f", startMs: 0, endMs: 3000, localSpeaker: 0, overlap: false, personID: p.id, source: "auto", score: 0.9, modelVersion: "v1")
        try db.replaceUtterances(recordingID: 42, [u])

        try db.deleteRecordingData(recordingID: 42)

        XCTAssertTrue(try db.listUtterances(recordingID: 42).isEmpty, "该录音的发言应清空")
        XCTAssertTrue(try db.listInsights(personID: p.id).isEmpty, "该录音的资料应清空")
        let samples = try db.listSamples(personID: p.id)
        XCTAssertEqual(samples.count, 1, "只应留下独立导入的样本")
        XCTAssertEqual(samples[0].id, imported.id)
    }
}
