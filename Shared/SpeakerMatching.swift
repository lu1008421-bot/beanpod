import Foundation

// MARK: - 跨录音声纹匹配（纯函数，可独立单元测试）

/// 一个可匹配的候选人物：personID + 归一化中心向量。
nonisolated struct SpeakerCandidate: Sendable, Equatable {
    var personID: UUID
    var centroid: [Float]
}

/// 一段新声音与人物库匹配后的结论（auto 自动署名 / suggest 建议确认 / newPerson 新人）。
nonisolated struct SpeakerMatchResult: Sendable, Equatable {
    enum Tier: String, Sendable, Equatable { case auto, suggest, newPerson }

    var tier: Tier
    /// auto 档时非空，表示自动署名到的人物。
    var personID: UUID?
    /// 与第一候选的余弦相似度。
    var score: Float
    /// 与第二候选的余弦相似度（用于 Margin 校验）。
    var secondScore: Float
    /// suggest 档时给出最像的人，供界面「合并到 TA」。
    var topCandidateID: UUID?
}

/// 声纹匹配规则：阈值与 Margin 都在这里，便于调参与单测。
/// CAM++ 实测：同人 ≈ 0.81，异人 ≤ 0.28；阈值取保守区间，宁可落到「建议确认」也不硬塞给已知人。
nonisolated enum SpeakerMatcher {
    /// 高于此分数且第一/第二候选间距足够 → 自动署名。
    static let autoThreshold: Float = 0.60
    /// 高于此分数但间距不足 → 建议确认。
    static let suggestThreshold: Float = 0.45
    /// 第一/第二候选最小间距。
    static let minMargin: Float = 0.08
    /// 没认出的声音至少说够这么久（清晰、非交叠）才建待认识卡；更短的只留录音内标签。
    static let minStrangerSeconds: Double = 30
    /// 是否允许自动落库署名。**第 4 节真实多天样本阈值校准通过前保持关闭**：
    /// 关闭时即使分数 ≥ `autoThreshold` 且间距足够，也只降到「建议确认」，绝不自动署名，
    /// 用户点「就是 TA」后才归属并入库确认样本。
    static let autoAssignEnabled = false

    /// 若干归一化向量的中心（再归一化）。
    static func centroid(_ vectors: [[Float]]) -> [Float]? {
        guard let n = vectors.first?.count, !vectors.isEmpty else { return nil }
        var sum = [Float](repeating: 0, count: n)
        var kept = 0
        for v in vectors where v.count == n {
            for i in 0..<n { sum[i] += v[i] }
            kept += 1
        }
        guard kept > 0 else { return nil }
        let len = (sum.reduce(Float(0)) { $0 + $1 * $1 }).squareRoot()
        guard len > 0 else { return nil }
        return sum.map { $0 / len }
    }

    /// 两个等长向量的余弦相似度。
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    /// 把一段新声音中心向量与候选人物比对。
    /// - Parameters:
    ///   - centroid: 该段声音的归一化中心向量。
    ///   - candidates: 候选人物中心向量。
    ///   - rejectedKeys: 已驳回的「人物↔声音」对，命中则跳过该候选（防止反复推荐）。
    ///   - rejectedKey: 由候选 personID 生成驳回键。
    ///   - allowAuto: 是否允许返回 `.auto`（自动落库署名）。默认取 `autoAssignEnabled`（当前为关）。
    static func match(centroid: [Float], candidates: [SpeakerCandidate], rejectedKeys: Set<String>, rejectedKey: (UUID) -> String, allowAuto: Bool = autoAssignEnabled) -> SpeakerMatchResult {
        let scored = candidates
            .map { c -> (SpeakerCandidate, Float) in (c, cosine(centroid, c.centroid)) }
            .sorted { $0.1 > $1.1 }
        let allowed = scored.filter { !rejectedKeys.contains(rejectedKey($0.0.personID)) }
        guard let best = allowed.first else {
            return SpeakerMatchResult(tier: .newPerson, personID: nil, score: 0, secondScore: 0, topCandidateID: nil)
        }
        let second = allowed.dropFirst().first?.1 ?? -1
        if allowAuto, best.1 >= autoThreshold, best.1 - second >= minMargin {
            return SpeakerMatchResult(tier: .auto, personID: best.0.personID, score: best.1, secondScore: second, topCandidateID: best.0.personID)
        }
        if best.1 >= suggestThreshold {
            return SpeakerMatchResult(tier: .suggest, personID: nil, score: best.1, secondScore: second, topCandidateID: best.0.personID)
        }
        return SpeakerMatchResult(tier: .newPerson, personID: nil, score: best.1, secondScore: second, topCandidateID: nil)
    }
}

// MARK: - 「建议确认」：像某位已有人物但分数不够，交给用户点一下

nonisolated struct SpeakerSuggestion: Sendable, Equatable, Identifiable {
    var id: String
    var recordingID: UInt32
    var localSpeaker: Int
    var candidateID: UUID
    var score: Float
    /// 这个声音在这条录音里的中心声纹与出现区间：采纳建议时直接拿来当样本，不用再算一遍。
    var vector: [Float] = []
    var startMs: Int = 0
    var endMs: Int = 0

    var payload: String {
        let obj: [String: Any] = ["recordingID": Int(recordingID), "localSpeaker": localSpeaker,
                                   "candidateID": candidateID.uuidString, "score": score,
                                   "vector": vector, "startMs": startMs, "endMs": endMs]
        return String(data: (try? JSONSerialization.data(withJSONObject: obj)) ?? Data(), encoding: .utf8) ?? ""
    }

    /// 从库里存的文本还原；格式不对就当没有。
    static func parse(_ payload: String) -> SpeakerSuggestion? {
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let r = obj["recordingID"] as? NSNumber, let s = obj["localSpeaker"] as? NSNumber,
              let c = obj["candidateID"] as? String, let cid = UUID(uuidString: c),
              let score = obj["score"] as? NSNumber else { return nil }
        let v = (obj["vector"] as? [NSNumber])?.map { $0.floatValue } ?? []
        let st = (obj["startMs"] as? NSNumber)?.intValue ?? 0
        let en = (obj["endMs"] as? NSNumber)?.intValue ?? 0
        return SpeakerSuggestion(id: "", recordingID: UInt32(r.intValue), localSpeaker: s.intValue,
                                 candidateID: cid, score: score.floatValue, vector: v, startMs: st, endMs: en)
    }
}

// MARK: - 人物名单合并：声纹认出的人与模型提到的人各管各的

nonisolated enum PeopleProjection {
    /// 一条录音的人物名单 = 声纹认出的（置前）+ 模型从内容里提到的（去掉上一次声纹写入的旧名字）。
    static func merge(llmPeople: [String], oldVoicePeople: [String], newVoicePeople: [String]) -> (people: [String], voicePeople: [String]) {
        var seen = Set(newVoicePeople)
        var people = newVoicePeople
        for name in llmPeople where !oldVoicePeople.contains(name) {
            if seen.insert(name).inserted { people.append(name) }
        }
        return (people, newVoicePeople)
    }

    /// 录音被排除出「人物」、或人物库里再没有它的发言时：把上次声纹写入的名字拿掉，模型提到的保留。
    static func removingVoice(_ people: [String], voicePeople: [String]) -> [String] {
        people.filter { !voicePeople.contains($0) }
    }

    /// 一次整理之后 `recordings[j].people` 换成了模型新给的名字，要把声纹的那部分并回去。
    static func merge(into current: [String], oldVoicePeople: [String], newVoicePeople: [String]) -> [String] {
        merge(llmPeople: current, oldVoicePeople: oldVoicePeople, newVoicePeople: newVoicePeople).people
    }
}

// MARK: - 按时间对齐：声学分人区间 ↔ 文字稿句子 ↔ 人工归属

nonisolated enum SpeakerAlignment {
    struct Span: Sendable, Equatable { var start: Double; var end: Double }

    /// 每句归给「句子中点落在其区间内」的那个说话人；中点不在任何区间内、或整篇只有 start=0 一句时返回 nil（不强归）。
    static func segmentSpeakers(segments: [Span], runs: [(span: Span, speaker: Int)]) -> [Int?] {
        // 整篇只有一句且从 0 开始：没有逐句时间戳，无法逐句归人
        if segments.count == 1, segments[0].start == 0 { return [nil] }
        return segments.map { seg in
            let mid = (seg.start + seg.end) / 2
            return runs.first { mid >= $0.span.start && mid < $0.span.end }?.speaker
        }
    }

    /// 句子只有开头时间（老文字稿 / 部分云端转写）时补出区间：句尾用下一句的开头，最后一句用到录音结束。
    static func withEnds(_ segments: [(start: Double, end: Double?)], duration: Double) -> [Span] {
        segments.enumerated().map { n, s in
            let next = n + 1 < segments.count ? segments[n + 1].start : duration
            let end = s.end ?? next
            return Span(start: s.start, end: max(s.start + 0.01, end))
        }
    }

    /// 重转写后，保留下来的人工区间重新套到新句子上：中点落在人工区间内的句子用人工指定的说话人槽位。
    static func applyManual(segments: [Span], manual: [(span: Span, speaker: Int)]) -> [Int?] {
        segments.map { seg in
            let mid = (seg.start + seg.end) / 2
            return manual.first { mid >= $0.span.start && mid < $0.span.end }?.speaker
        }
    }

    /// 新生成的自动区间避开人工区间：完全落在人工区间里的丢掉，跨过边界的裁掉重叠部分，太短的也不要。
    static func clipAuto<T>(_ auto: [T], manual: [Span], span: (T) -> Span, rebuild: (T, Span) -> T) -> [T] {
        auto.compactMap { item -> T? in
            var s = span(item)
            for m in manual {
                guard s.end > m.start, s.start < m.end else { continue }
                if s.start >= m.start, s.end <= m.end { return nil }
                if s.start < m.start, s.end > m.end { return nil }   // 把人工区间整个包住：裁了就断成两截，这里不保留
                if s.start < m.start { s.end = m.start } else { s.start = m.end }
            }
            guard s.end - s.start >= 0.2 else { return nil }
            return rebuild(item, s)
        }
    }
}

// MARK: - 长音频分窗后的跨窗重连

nonisolated enum WindowLinker {
    struct Turn: Sendable, Equatable { var start: Double; var end: Double; var speaker: Int }

    /// 一个窗口的分人结果：绝对时间的区间 + 每个本地说话人的中心向量。
    struct Window {
        var turns: [Turn]
        var centroids: [Int: [Float]]
        /// 只有中点不早于这个时刻的区间才算这个窗口的（前面那截和上一个窗口重叠，归上一个窗口，免得重复）。
        var keepFrom: Double
        /// 这一窗在音频里的结束时刻。贴着它结束的区间是被窗尾截出来的半句：下一窗里要是有同一个人的重叠区间，
        /// 就只留下一窗那份完整的。最后一窗没有下一窗，为 nil。
        var cutAt: Double? = nil
    }

    static let linkThreshold: Float = 0.60

    /// 把各窗口的本地说话人编号并成全篇统一的编号：中心向量余弦 ≥ 阈值的视为同一人，否则新开一个。
    static func merge(_ windows: [Window], cosine: ([Float], [Float]) -> Float) -> [Turn] {
        var centroids: [[Float]] = []
        var counts: [Int] = []
        // 先把每一窗的本地编号都映射成全篇编号（只跟中心向量有关），再去重
        let maps: [[Int: Int]] = windows.map { w in
            var map: [Int: Int] = [:]
            for (local, c) in w.centroids.sorted(by: { $0.key < $1.key }) {
                let best = centroids.indices.max { cosine(centroids[$0], c) < cosine(centroids[$1], c) }
                if let best, cosine(centroids[best], c) >= linkThreshold {
                    // 做个滚动平均，越往后越稳
                    let n = Float(counts[best])
                    centroids[best] = zip(centroids[best], c).map { ($0 * n + $1) / (n + 1) }
                    counts[best] += 1
                    map[local] = best
                } else {
                    centroids.append(c); counts.append(1)
                    map[local] = centroids.count - 1
                }
            }
            return map
        }
        var out: [Turn] = []
        for (n, w) in windows.enumerated() {
            for turn in w.turns {
                // 开头重叠区归上一窗
                guard (turn.start + turn.end) / 2 >= w.keepFrom else { continue }
                // 窗尾截出来的半句：下一窗里有同一个人的重叠区间就只留下一窗那份
                // （截断会改变中点，光靠中点划界挡不住它；留 0.5 秒容差是因为模型的分段点不一定正好落在窗尾）
                if let cut = w.cutAt, turn.end >= cut - 0.5, n + 1 < windows.count,
                   let g = maps[n][turn.speaker],
                   windows[n + 1].turns.contains(where: { next in
                       next.start < turn.end && next.end > turn.start
                           && (next.start + next.end) / 2 >= windows[n + 1].keepFrom
                           && maps[n + 1][next.speaker] == g
                   }) { continue }
                out.append(Turn(start: turn.start, end: turn.end, speaker: maps[n][turn.speaker] ?? turn.speaker))
            }
        }
        return out.sorted { $0.start < $1.start }
    }
}
