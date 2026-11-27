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
    static func match(centroid: [Float], candidates: [SpeakerCandidate], rejectedKeys: Set<String>, rejectedKey: (UUID) -> String) -> SpeakerMatchResult {
        let scored = candidates
            .map { c -> (SpeakerCandidate, Float) in (c, cosine(centroid, c.centroid)) }
            .sorted { $0.1 > $1.1 }
        let allowed = scored.filter { !rejectedKeys.contains(rejectedKey($0.0.personID)) }
        guard let best = allowed.first else {
            return SpeakerMatchResult(tier: .newPerson, personID: nil, score: 0, secondScore: 0, topCandidateID: nil)
        }
        let second = allowed.dropFirst().first?.1 ?? -1
        if best.1 >= autoThreshold, best.1 - second >= minMargin {
            return SpeakerMatchResult(tier: .auto, personID: best.0.personID, score: best.1, secondScore: second, topCandidateID: best.0.personID)
        }
        if best.1 >= suggestThreshold {
            return SpeakerMatchResult(tier: .suggest, personID: nil, score: best.1, secondScore: second, topCandidateID: best.0.personID)
        }
        return SpeakerMatchResult(tier: .newPerson, personID: nil, score: best.1, secondScore: second, topCandidateID: nil)
    }
}
