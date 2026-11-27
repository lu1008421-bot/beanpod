import Foundation

// MARK: - 从谈话提取有依据的人物背景与往来事项（P5）

/// 从模型输出解析出的一条人物更新：人物名 + 类别 + 文本 + 依据句号（1 起）。
nonisolated struct ExtractedPersonInsight: Sendable, Equatable {
    var personName: String
    var kind: InsightKind
    var text: String
    var segmentIndices: [Int]
}

/// 输入/输出都带 `segment_indices`，程序侧再反查精确声学起止，杜绝让模型直接输出时间戳。
nonisolated enum PersonInsightExtractor {
    struct IndexedLine: Sendable, Equatable {
        var index: Int            // 1 起
        var person: String
        var text: String
        var start: TimeInterval
        var end: TimeInterval
    }

    /// 把逐句文字稿编成 `[#N] 人：原文`，供模型引用句号。
    static func indexedTranscript(segments: [Segment], speakerNames: [String]) -> [IndexedLine] {
        segments.enumerated().map { n, seg in
            let name = seg.speaker.flatMap { $0 < speakerNames.count ? speakerNames[$0] : nil } ?? ""
            return IndexedLine(index: n + 1,
                               person: name.isEmpty ? String(localized: "说话人") : name,
                               text: seg.clean ?? seg.text,
                               start: seg.start,
                               end: seg.end ?? seg.start)
        }
    }

    static func prompt(lines: [IndexedLine]) -> (system: String, user: String) {
        let user = lines.map { "[#\($0.index)] \($0.person)：\($0.text)" }.joined(separator: "\n")
        let system = """
        你是对话记录整理助手。下面是带编号和说话人的对话文字稿。
        请提取与每位在场人物有关的三类信息：人物背景（bio：称呼、职责、关系）、提到的事（topic）、说定的事（commitment）。
        规则：
        - 严格区分说话人自述、他人转述与提到的第三人；多人会议里提到第三人或他人的款项，不得记到说话人或错误参与者名下。
        - 区分报价与成交、预计付款与已付款、口头邀约与已赴约；完整保留否定词与前提条件（如「还没付」「如果本周上线就签」）。
        - 没有明确原文依据的不要写；每一条必须给出依据的句号列表 segment_indices（从 1 开始）。
        - 只输出一个 JSON 对象：{"updates":[{"person":"人名","kind":"bio|topic|commitment","text":"…","segment_indices":[12]}]}
        - 不要输出任何时间戳、毫秒或秒数。
        """
        return (system, user)
    }

    /// 校验模型输出的 `segment_indices` 存在后，反查句子的精确声学起止并落库。
    static func parse(_ reply: String, lines: [IndexedLine]) -> [ExtractedPersonInsight] {
        guard let s = reply.firstIndex(of: "{"), let e = reply.lastIndex(of: "}"),
              let obj = try? JSONSerialization.jsonObject(with: Data(reply[s...e].utf8)) as? [String: Any],
              let updates = obj["updates"] as? [[String: Any]] else { return [] }
        var out: [ExtractedPersonInsight] = []
        for u in updates {
            guard let person = (u["person"] as? String)?.trimmingCharacters(in: .whitespaces), !person.isEmpty,
                  let kindRaw = u["kind"] as? String, let kind = InsightKind(rawValue: kindRaw),
                  let text = (u["text"] as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { continue }
            let indices = (u["segment_indices"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
                .filter { $0 >= 1 && $0 <= lines.count }
            guard !indices.isEmpty else { continue }
            out.append(ExtractedPersonInsight(personName: person, kind: kind, text: text, segmentIndices: indices))
        }
        return out
    }

    static func extract(lines: [IndexedLine], config: LLMConfig) async throws -> [ExtractedPersonInsight] {
        let p = prompt(lines: lines)
        let reply = try await Analyzer.chat(config, system: p.system, user: p.user, json: true)
        return parse(reply, lines: lines)
    }
}

extension BeanStore {
    /// 对一条已归人的录音抽人物背景与往来事项，反查句号区间后写入人物库。
    /// 人工 `edited_by_user` 的条目不会被覆盖（`upsertInsight` 只按 id 更新）。
    func runPeopleInsights(_ id: UInt32) async {
        guard let rec = recordings.first(where: { $0.id == id }),
              rec.segments.contains(where: { $0.speaker != nil }),
              peopleDB != nil, !asking else { return }
        let lines = PersonInsightExtractor.indexedTranscript(segments: rec.segments, speakerNames: rec.speakers)
        guard !lines.isEmpty, analysisAvailable else { return }
        do {
            let extracted = try await withLLM { config in
                try await PersonInsightExtractor.extract(lines: lines, config: config)
            }
            applyPeopleInsights(extracted, lines: lines, recordingID: id)
        } catch {
            addLog("人物信息抽取失败：\(error.localizedDescription)")
        }
    }

    private func applyPeopleInsights(_ extracted: [ExtractedPersonInsight], lines: [PersonInsightExtractor.IndexedLine], recordingID: UInt32) {
        guard let db = peopleDB else { return }
        let recDate = recordings.first(where: { $0.id == recordingID })?.date
        for e in extracted {
            guard let person = people.first(where: { $0.displayName == e.personName }) else { continue }
            let picked = lines.filter { e.segmentIndices.contains($0.index) }
            let startMs = picked.map { Int($0.start * 1000) }.min()
            let endMs = picked.map { Int($0.end * 1000) }.max()
            let insight = PersonInsight(id: UUID(), personID: person.id, kind: e.kind, text: e.text,
                                        recordingID: recordingID, startMs: startMs, endMs: endMs,
                                        occurredAt: recDate, editedByUser: false, modelVersion: "people-v1", stale: false)
            do { try db.upsertInsight(insight) }
            catch { peopleError = error.localizedDescription }
        }
    }
}
