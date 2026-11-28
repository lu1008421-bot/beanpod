import Foundation

// MARK: - 新声音的候选卡（纯值，分人结束后等场景确定再决定建不建卡）

nonisolated struct StrangerCandidate: Sendable {
    /// 一段干净的单人发言：自带起止时间和这段自己的声纹向量，建卡后直接当代表样本。
    struct Clip: Sendable, Equatable {
        var startMs: Int
        var endMs: Int
        var vector: [Float]
        var seconds: Double { Double(max(0, endMs - startMs)) / 1000 }
    }

    var localSpeaker: Int
    /// 清晰发言总时长（够不够建卡看这个）。
    var seconds: Double
    /// 代表原声：最长的至多 3 段，按时长降序。每段是一句连续的话，不是从第一次开口到最后一次的整段。
    var clips: [Clip]
    var channel: VoiceChannel

    /// 最长的一段：写「建议确认」时给它留回听入口。
    var longestClip: Clip? { clips.first }
}

nonisolated enum StrangerClips {
    static let maxCount = 3

    /// 从一个人的各段发言里挑代表段：按时长降序取前 `max` 段。
    static func representative(_ items: [(start: TimeInterval, end: TimeInterval, vector: [Float])], limit: Int = maxCount) -> [StrangerCandidate.Clip] {
        items.map { StrangerCandidate.Clip(startMs: Int($0.start * 1000), endMs: Int($0.end * 1000), vector: $0.vector) }
            .filter { $0.seconds > 0 }
            .sorted { $0.seconds > $1.seconds || ($0.seconds == $1.seconds && $0.startMs < $1.startMs) }
            .prefix(max(limit, 0))
            .map { $0 }
    }
}

// MARK: - 无分析模型时的场景兜底

nonisolated enum FallbackSceneRule {
    /// 判不出场景的短录音默认当「灵感」（一个人自言自语）。
    /// 但分人已经听出两个以上的人在说话，就不是自言自语，保持「其他」，不然多人短对话建不了卡。
    static func looksLikeMemo(duration: TimeInterval, localSpeakers: Int) -> Bool {
        duration < 90 && localSpeakers < 2
    }
}

// MARK: - 「听一段」的记账

/// 就地试听一段原声时的状态：正在听哪一段、听到哪里停。界面读 `activeSpan` 决定这一行显示「听」还是「停」。
nonisolated struct SpanPlayback: Equatable, Sendable {
    /// 正在听的那一段；没在听就是 nil。
    private(set) var activeSpan: ClosedRange<TimeInterval>?
    /// 「这句再听」：播到这里自己停。
    private(set) var stopAt: TimeInterval?

    /// 开始听一段。循环听没有停点（到句尾由循环逻辑跳回句首）。
    /// 录音结尾留一点余量，不然 100ms 一次的检查容易错过、播放器先自己停了。
    mutating func begin(_ span: ClosedRange<TimeInterval>, loop: Bool, duration: TimeInterval) {
        let end = max(span.lowerBound + 0.3, min(span.upperBound, duration - 0.15))
        activeSpan = span.lowerBound...end
        stopAt = loop ? nil : end
    }

    /// 播放头跳到了正在听的这一段之外：这段算听完了，停点也一起作废。
    /// 首尾各留 0.25 秒容差：AVAudioPlayer 的 currentTime 会因帧对齐略小于句首，别在第一帧就误清。
    mutating func leaveIfOutside(at time: TimeInterval) {
        if let s = activeSpan, time < s.lowerBound - 0.25 || time > s.upperBound + 0.25 { clear() }
    }

    mutating func clear() {
        activeSpan = nil
        stopAt = nil
    }
}
