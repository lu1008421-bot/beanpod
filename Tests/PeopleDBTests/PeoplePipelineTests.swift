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

    // MARK: 第四轮审计回归

    private func utterance(_ rec: UInt32, _ start: Int, _ end: Int, speaker: Int, person: UUID?) -> Utterance {
        Utterance(id: UUID(), recordingID: rec, audioFingerprint: "recording-\(rec)", startMs: start, endMs: end,
                  localSpeaker: speaker, overlap: false, personID: person, source: "auto", score: 0.9, modelVersion: "")
    }

    /// 同一条录音里两个陌生人发言穿插一小时：采纳其中一人的「疑似」只并掉他自己的待认识卡，另一张不动，
    /// 而且他的发言要转给被认下的人（不能跟着旧卡一起被删）。
    func testAcceptSuggestionOnlyRemovesOwnPendingCard() throws {
        let db = try openDB()
        let rec: UInt32 = 7
        let known = try db.createPerson(displayName: "老张", status: .confirmed)
        let a = try db.createPerson(displayName: "", status: .pending)
        let b = try db.createPerson(displayName: "", status: .pending)
        var utts: [Utterance] = []
        for n in 0..<6 {
            utts.append(utterance(rec, n * 600_000, n * 600_000 + 60_000, speaker: 1, person: a.id))
            utts.append(utterance(rec, n * 600_000 + 120_000, n * 600_000 + 180_000, speaker: 2, person: b.id))
        }
        try db.replaceAutoUtterances(recordingID: rec, utts)
        XCTAssertEqual(try db.pendingPersonID(recordingID: rec, localSpeaker: 1), a.id)
        XCTAssertEqual(try db.pendingPersonID(recordingID: rec, localSpeaker: 2), b.id)

        try db.acceptSuggestion(recordingID: rec, localSpeaker: 1, candidateID: known.id)

        XCTAssertNil(try db.person(id: a.id), "被认下的那个声音自己的待认识卡并掉")
        XCTAssertEqual(try db.person(id: b.id)?.status, .pending, "另一个人的待认识卡不能被误删")
        let mine = try db.listUtterancesForPerson(personID: known.id)
        XCTAssertEqual(mine.count, 6, "这个声音的发言全部转给被认下的人")
        XCTAssertTrue(mine.allSatisfy { $0.recordingID == rec && $0.localSpeaker == 1 })
        XCTAssertEqual(try db.listUtterancesForPerson(personID: b.id).count, 6)
        XCTAssertNil(try db.pendingPersonID(recordingID: rec, localSpeaker: 1))
        XCTAssertEqual(try db.pendingPersonID(recordingID: rec, localSpeaker: 2), b.id)
    }

    /// 这个声音没有待认识卡（比如场景拦截没建卡）时，采纳只是把未归属的发言归过去。
    func testAcceptSuggestionWithoutPendingCardAssignsUnownedUtterances() throws {
        let db = try openDB()
        let rec: UInt32 = 8
        let known = try db.createPerson(displayName: "老李", status: .confirmed)
        try db.replaceAutoUtterances(recordingID: rec, [utterance(rec, 0, 4000, speaker: 0, person: nil),
                                                        utterance(rec, 9000, 12000, speaker: 0, person: nil),
                                                        utterance(rec, 5000, 8000, speaker: 1, person: nil)])
        try db.acceptSuggestion(recordingID: rec, localSpeaker: 0, candidateID: known.id)
        let mine = try db.listUtterancesForPerson(personID: known.id)
        XCTAssertEqual(mine.map(\.startMs), [0, 9000])
    }

    /// 单句改归属后：旧人物的这条发言与代表原声即时剔除，另一句仍归原人，不能还播得出来。
    func testCarveManualRangeDropsOldAttributionAndSample() throws {
        let db = try openDB()
        let rec: UInt32 = 9002
        let old = try db.createPerson(displayName: "", status: .pending)
        try db.replaceAutoUtterances(recordingID: rec, [
            utterance(rec, 2000, 10000, speaker: 0, person: old.id),   // 0:02–0:10 要改归别人
            utterance(rec, 13000, 16000, speaker: 0, person: old.id),  // 0:13 仍归原人
        ])
        let clip = VoiceSample(id: UUID(), personID: old.id, sourceKind: .recordingSpan, recordingID: rec,
                               startMs: 2000, endMs: 10000, managedFile: nil, channel: .nearField,
                               confirmed: false, modelVersion: "cam++", contentHash: "r9002-0-2000")
        try db.addSample(clip, embedding: unit(0))

        try db.carveManualRange(recordingID: rec, oldLocalSpeaker: 0, oldPersonID: old.id, startMs: 2000, endMs: 10000)

        let mine = try db.listUtterancesForPerson(personID: old.id)
        XCTAssertEqual(mine.map(\.startMs), [13000], "只剩 0:13 那句")
        XCTAssertTrue(try db.listSamples(personID: old.id).isEmpty, "0:02–0:10 的代表原声要删掉，不能还点得动")
    }

    /// 改掉的只是 run 里的一句：run 的前后半段还归原人，一分为二裁掉中间那句，不误删别人。
    func testCarveManualRangeSplitsPartialOverlap() throws {
        let db = try openDB()
        let rec: UInt32 = 9003
        let old = try db.createPerson(displayName: "", status: .pending)
        try db.replaceAutoUtterances(recordingID: rec, [utterance(rec, 0, 20000, speaker: 0, person: old.id)])
        try db.carveManualRange(recordingID: rec, oldLocalSpeaker: 0, oldPersonID: old.id, startMs: 2000, endMs: 10000)
        let mine = try db.listUtterancesForPerson(personID: old.id)
        XCTAssertEqual(mine.map(\.startMs), [0, 10000])
        XCTAssertEqual(mine.map(\.endMs), [2000, 20000])
    }

    /// 代表原声是几句各自连续的话（最长的至多 3 段），不是从第一次开口到最后一次的整条。
    func testRepresentativeClipsAreSeparateSegments() {
        let v = [Float(1)]
        // 第 0 秒、第 300 秒、第 350 秒各说了几句：一个人在录音里前后穿插
        let clips = StrangerClips.representative([(start: 0, end: 10, vector: v), (start: 300, end: 310, vector: v),
                                                 (start: 350, end: 359.5, vector: v), (start: 350, end: 355, vector: v)])
        XCTAssertEqual(clips.count, 3)
        XCTAssertEqual(clips.map(\.seconds), [10, 10, 9.5])
        XCTAssertEqual(clips.map(\.startMs), [0, 300_000, 350_000])
        XCTAssertTrue(clips.allSatisfy { $0.seconds <= 10 }, "每段都不超过单句时长，不能跨成一小时")
        // 按时长降序；不足 3 段就有几段给几段
        XCTAssertEqual(StrangerClips.representative([(start: 5, end: 7, vector: v)]).first?.startMs, 5000)
        XCTAssertTrue(StrangerClips.representative([(start: 5, end: 5, vector: v)]).isEmpty, "零长度的不算")
    }

    /// 「听一段」：不循环也要记下正在听的区间；停、播到句尾、跳出区间都会清掉。
    func testSpanPlaybackTracksActiveSpan() {
        var p = SpanPlayback()
        XCTAssertNil(p.activeSpan)
        p.begin(10...20, loop: false, duration:100)
        XCTAssertEqual(p.activeSpan, 10...20)
        XCTAssertEqual(p.stopAt, 20, "不循环：播到句尾停")
        p.leaveIfOutside(at: 9.99)
        XCTAssertEqual(p.activeSpan, 10...20, "首帧比句首略小（帧对齐）不能误清")
        XCTAssertEqual(p.stopAt, 20)
        p.leaveIfOutside(at: 20.1)
        XCTAssertEqual(p.activeSpan, 10...20, "句尾略过一点也不误清")
        p.leaveIfOutside(at: 8.0)
        XCTAssertNil(p.activeSpan, "确实跳到段外才清")
        XCTAssertNil(p.stopAt)

        p.begin(10...20, loop: false, duration: 100)
        p.clear()                                   // stop()
        XCTAssertNil(p.activeSpan)
        XCTAssertNil(p.stopAt)

        p.begin(10...20, loop: true, duration: 100)
        XCTAssertEqual(p.activeSpan, 10...20, "循环也记 activeSpan，界面才知道这一行正在播")
        XCTAssertNil(p.stopAt)
        p.leaveIfOutside(at: 15)
        XCTAssertEqual(p.activeSpan, 10...20, "还在这一段里：不变")
        p.leaveIfOutside(at: 30)
        XCTAssertNil(p.activeSpan)
        XCTAssertNil(p.stopAt)

        // 录音结尾留余量；太短的段落至少播 0.3 秒
        p.begin(98...120, loop: false, duration: 100)
        XCTAssertEqual(p.activeSpan, 98...99.85)
        XCTAssertEqual(p.stopAt, 99.85)
        p.begin(5...5.1, loop: false, duration: 100)
        XCTAssertEqual(p.activeSpan, 5...5.3)
    }

    /// 路径 B：老文字稿只有开头时间，句尾用下一句的开头、最后一句用到录音结束，然后按中点归人。
    func testPathBFillsMissingEndsBeforeAligning() {
        let spans = SpeakerAlignment.withEnds([(start: 0, end: nil), (start: 3, end: nil), (start: 7.5, end: nil)], duration: 12)
        XCTAssertEqual(spans, [span(0, 3), span(3, 7.5), span(7.5, 12)])
        let runs = [(span(0, 4), 0), (span(4, 12), 1)]
        XCTAssertEqual(SpeakerAlignment.segmentSpeakers(segments: spans, runs: runs), [0, 1, 1])
        // 有句尾的照用；录音时长比最后一句开头还小（时长没算准）也不出倒挂区间
        XCTAssertEqual(SpeakerAlignment.withEnds([(start: 0, end: 2.5), (start: 3, end: nil)], duration: 1),
                       [span(0, 2.5), span(3, 3.01)])
        // 仍然只有一段 start=0 时不整篇归人
        let single = SpeakerAlignment.withEnds([(start: 0, end: nil)], duration: 9)
        XCTAssertEqual(SpeakerAlignment.segmentSpeakers(segments: single, runs: runs), [nil])
    }

    /// 分窗的结尾重叠区：上一窗被窗尾截出来的半句，下一窗里有同一个人更完整的区间时只留下一窗那份。
    func testWindowTailOverlapBelongsToNextWindow() {
        func first(_ next: [WindowLinker.Turn]) -> [WindowLinker.Turn] {
            WindowLinker.merge([
                WindowLinker.Window(turns: [.init(start: 10, end: 20, speaker: 0), .init(start: 272, end: 285, speaker: 0),
                                            .init(start: 299.6, end: 299.96, speaker: 1)],
                                    centroids: [0: unit(0), 1: unit(1)], keepFrom: 0, cutAt: 300),
                WindowLinker.Window(turns: next, centroids: [0: unit(1), 1: unit(0)], keepFrom: 300),
            ], cosine: SpeakerMatcher.cosine)
        }
        let turns = first([.init(start: 272, end: 285, speaker: 1), .init(start: 299.6, end: 306, speaker: 0)])
        XCTAssertEqual(turns.map(\.speaker), [0, 0, 1])
        XCTAssertEqual(turns.map(\.start), [10, 272, 299.6], "窗尾截出的 299.6–299.96 那半句不重复")
        XCTAssertEqual(turns.last?.end, 306, "取下一窗看到的整句")
        // 下一窗没分出这句（比如静音被并掉了）：截出来的半句照留，不能丢
        let kept = first([.init(start: 272, end: 285, speaker: 1)])
        XCTAssertEqual(kept.map(\.end), [20, 285, 299.96])
        // 下一窗里重叠的是别人：也不删（各是各的话）
        let other = first([.init(start: 272, end: 285, speaker: 1), .init(start: 299.6, end: 306, speaker: 1)])
        XCTAssertEqual(other.map(\.speaker), [0, 0, 1, 0], "半句和下一窗那句是两个人说的：都留")
    }

    /// 没有分析模型时：短于 90 秒、判不出场景的录音默认当「灵感」；但分人已听出两个以上的人在说话就不是。
    func testShortMultiSpeakerRecordingIsNotMemo() {
        XCTAssertTrue(FallbackSceneRule.looksLikeMemo(duration: 53, localSpeakers: 0), "没分过人：维持原来的兜底")
        XCTAssertTrue(FallbackSceneRule.looksLikeMemo(duration: 53, localSpeakers: 1), "一个人自言自语")
        XCTAssertFalse(FallbackSceneRule.looksLikeMemo(duration: 53, localSpeakers: 2), "多人短对话不拦")
        XCTAssertFalse(FallbackSceneRule.looksLikeMemo(duration: 200, localSpeakers: 0), "长录音本来就不兜底")
    }
}
