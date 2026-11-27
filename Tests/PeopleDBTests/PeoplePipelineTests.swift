import Foundation
import XCTest

/// 第三轮收口新增的纯函数与库层行为：人物名单合并、时间对齐、分窗重连、样本去重、匹配建议、资料编辑。
final class PeoplePipelineTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("beanpod-people-pipeline-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func openDB() throws -> PeopleDB {
        try PeopleDB(folder: tempDir.appendingPathComponent("People", isDirectory: true))
    }

    private func span(_ s: Double, _ e: Double) -> SpeakerAlignment.Span { .init(start: s, end: e) }

    // MARK: 人物名单合并

    /// 整理时模型给的人物名单不能把声纹认出的人名冲掉，模型提到但没发声的人也要留着。
    func testProjectionKeepsMentionedAndPutsVoiceFirst() {
        let r = PeopleProjection.merge(llmPeople: ["张三", "李四"], oldVoicePeople: ["王五"], newVoicePeople: ["赵六", "张三"])
        XCTAssertEqual(r.people, ["赵六", "张三", "李四"])
        XCTAssertEqual(r.voicePeople, ["赵六", "张三"])
    }

    /// 上次声纹写入、这次没再认出的名字要拿掉；模型这次也提到的除外。
    func testProjectionDropsStaleVoiceNames() {
        let r = PeopleProjection.merge(llmPeople: ["老周", "小吴"], oldVoicePeople: ["老周"], newVoicePeople: [])
        XCTAssertEqual(r.people, ["小吴"])
        // 没人再开口：名单里只剩模型提到的
        let r2 = PeopleProjection.merge(llmPeople: ["老周", "小吴"], oldVoicePeople: ["老周"], newVoicePeople: ["小吴"])
        XCTAssertEqual(r2.people, ["小吴"])
    }

    /// 一条录音被排除出「人物」：名单里只拿掉声纹写的名字，模型提到的照留。
    func testExcludedRecordingKeepsMentionedPeople() {
        XCTAssertEqual(PeopleProjection.removingVoice(["赵六", "李四"], voicePeople: ["赵六"]), ["李四"])
        XCTAssertEqual(PeopleProjection.removingVoice(["李四"], voicePeople: []), ["李四"])
    }

    // MARK: 按时间对齐

    /// 句子归给中点所在区间的说话人；中点落在空隙里就不归。
    func testSegmentSpeakersByMidpoint() {
        let runs = [(span(0, 3), 0), (span(3, 8), 1), (span(9, 12), 0)]
        let got = SpeakerAlignment.segmentSpeakers(segments: [span(0, 2), span(2, 6), span(8, 9), span(9, 11)], runs: runs)
        XCTAssertEqual(got, [0, 1, nil, 0])
    }

    /// 整篇只有 start=0 一句：没有逐句时间戳，不整篇归给一个人。
    func testWholeTranscriptIsNeverAssignedToOneSpeaker() {
        let runs = [(span(0, 5), 0), (span(5, 10), 1)]
        let got = SpeakerAlignment.segmentSpeakers(segments: [span(0, 10)], runs: runs)
        XCTAssertEqual(got.count, 1)
        XCTAssertNil(got[0])
    }

    /// 重转写后，保留下来的人工区间套到新句子上；没被人工改过的句子不受影响。
    func testApplyManualRealignsToNewSegments() {
        let manual = [(span(4, 7.2), 5)]
        let got = SpeakerAlignment.applyManual(segments: [span(0, 4), span(4, 6), span(6, 8)], manual: manual)
        XCTAssertEqual(got, [nil, 5, 5])
    }

    /// 新的自动区间让开人工区间：包住的丢掉、跨界的裁掉、裁得太短的也不要。
    func testClipAutoAroundManual() {
        let items = [span(0, 2), span(2, 6), span(5, 9), span(9, 10)]
        let got = SpeakerAlignment.clipAuto(items, manual: [span(3, 8)], span: { $0 }, rebuild: { _, s in s })
        XCTAssertEqual(got, [span(0, 2), span(2, 3), span(8, 9), span(9, 10)])
    }

    // MARK: 分窗重连

    private func unit(_ i: Int, _ dim: Int = 4) -> [Float] {
        (0..<dim).map { $0 == i ? 1 : 0 }
    }

    /// 同一个人在两个窗口里编号不同，中心向量相近就该并成一个；不像的新开一个。
    func testWindowLinkerReconnectsSameSpeakerAcrossWindows() {
        let a = unit(0)
        let a2: [Float] = [0.95, 0.05, 0, 0]
        let b = unit(1)
        let windows = [
            WindowLinker.Window(turns: [.init(start: 0, end: 10, speaker: 0), .init(start: 10, end: 20, speaker: 1)],
                                centroids: [0: a, 1: b], keepFrom: 0),
            // 第二个窗口里 0 号其实是第一个人，1 号是第二个人，2 号是新来的人
            WindowLinker.Window(turns: [.init(start: 20, end: 30, speaker: 0), .init(start: 30, end: 35, speaker: 1),
                                        .init(start: 35, end: 40, speaker: 2)],
                                centroids: [0: a2, 1: b, 2: unit(2)], keepFrom: 30),
        ]
        let turns = WindowLinker.merge(windows, cosine: SpeakerMatcher.cosine)
        // 第二个窗口里 20–30 那段和上一个窗口重叠，归上一个窗口，不重复输出
        XCTAssertEqual(turns.map(\.speaker), [0, 1, 1, 2])
        XCTAssertEqual(turns.map(\.start), [0, 10, 30, 35])
    }

    // MARK: 样本

    private func sample(_ person: UUID, hash: String, file: String? = nil) -> VoiceSample {
        VoiceSample(id: UUID(), personID: person, sourceKind: .importedFile, recordingID: nil, startMs: 0, endMs: 1500,
                    managedFile: file, channel: .nearField, confirmed: false, modelVersion: "cam++", contentHash: hash)
    }

    /// 同一个人同一段音频不重复入库；换个人可以各自存。
    func testSampleDedupedByContentHash() throws {
        let db = try openDB()
        let a = try db.createPerson(displayName: "甲", status: .confirmed)
        let b = try db.createPerson(displayName: "乙", status: .confirmed)
        let first = sample(a.id, hash: "h1", file: "x.wav")
        XCTAssertTrue(try db.addSample(first, embedding: unit(0)))
        XCTAssertFalse(try db.addSample(sample(a.id, hash: "h1"), embedding: unit(0)), "同一个人同内容应去重")
        XCTAssertTrue(try db.addSample(sample(b.id, hash: "h1"), embedding: unit(0)), "不同人可以各存一份")
        XCTAssertTrue(try db.sampleExists(personID: a.id, contentHash: "h1"))
        XCTAssertEqual(try db.listSamples(personID: a.id).count, 1)
        XCTAssertEqual(try db.sampleFile(id: first.id), "x.wav")
    }

    /// 认下这个人之后，TA 名下的样本全部变成已确认，标准声纹才开始用它们。
    func testConfirmSamplesAfterNaming() throws {
        let db = try openDB()
        let p = try db.createPerson(displayName: "", status: .pending)
        try db.addSample(sample(p.id, hash: "s1"), embedding: unit(0))
        try db.addSample(sample(p.id, hash: "s2"), embedding: unit(0))
        XCTAssertTrue(try db.confirmedEmbeddings(personID: p.id).isEmpty)
        try db.confirmSamples(personID: p.id)
        XCTAssertEqual(try db.confirmedEmbeddings(personID: p.id).count, 2)
    }

    // MARK: 匹配建议

    /// 「疑似某人」存进库里能原样读回（带声纹向量），采纳或驳回后删除。
    func testSuggestionRoundTripAndDelete() throws {
        let db = try openDB()
        let cand = UUID()
        let s = SpeakerSuggestion(id: "", recordingID: 42, localSpeaker: 1, candidateID: cand, score: 0.52,
                                  vector: [0.1, 0.2], startMs: 3000, endMs: 9000)
        try db.recordJob(kind: "speaker_suggestion", payload: s.payload)
        let list = try db.listSuggestions()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].recordingID, 42)
        XCTAssertEqual(list[0].localSpeaker, 1)
        XCTAssertEqual(list[0].candidateID, cand)
        XCTAssertEqual(list[0].score, 0.52, accuracy: 0.001)
        XCTAssertEqual(list[0].vector, [0.1, 0.2])
        XCTAssertEqual(list[0].startMs, 3000)
        XCTAssertEqual(list[0].endMs, 9000)
        XCTAssertFalse(list[0].id.isEmpty)
        try db.deleteJob(id: list[0].id)
        XCTAssertTrue(try db.listSuggestions().isEmpty)
    }

    // MARK: 人物资料

    /// 改过的条目标记成人工改写；移除是软删。
    func testInsightEditAndRemove() throws {
        let db = try openDB()
        let p = try db.createPerson(displayName: "李总", status: .confirmed)
        let it = PersonInsight(id: UUID(), personID: p.id, kind: .bio, text: "自动写的背景", recordingID: 3, startMs: nil, endMs: nil,
                               occurredAt: nil, editedByUser: false, modelVersion: "v1", stale: false)
        try db.upsertInsight(it)
        try db.editInsight(id: it.id, text: "人工改过的背景")
        let edited = try XCTUnwrap(try db.listInsights(personID: p.id).first)
        XCTAssertEqual(edited.text, "人工改过的背景")
        XCTAssertTrue(edited.editedByUser)
        XCTAssertFalse(edited.stale)
        try db.hideInsight(id: it.id)
        XCTAssertTrue(try db.listInsights(personID: p.id).first?.stale == true)
    }
}
