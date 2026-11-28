import Foundation

// MARK: - 人物领域模型（跨录音人物身份的唯一权威源，SQLite 存储）

/// 人物状态：`confirmed` 已命名确认、`pending` 待认识、`ignored` 已忽略。
nonisolated enum PersonStatus: String, Codable, Sendable, CaseIterable {
    case confirmed, pending, ignored
}

/// 一个可跨录音复用的人物身份。
nonisolated struct Person: Identifiable, Equatable, Sendable, Codable {
    var id: UUID
    var displayName: String
    /// 稳定编号：0→A、1→B、…、26→AA，跨天/改名/重启不回收。
    var strangerIndex: Int
    /// 头像颜色下标，映射 `Theme.speakers`。
    var colorIndex: Int
    var status: PersonStatus
    /// 全局至多一个「我」。
    var isMe: Bool
    var note: String
    var createdAt: Date
    var lastMetAt: Date?

    /// 给待认识声音看的内部编号（A、B、…、Z、AA、AB）。
    var strangerLabel: String {
        var n = strangerIndex
        var s = ""
        repeat {
            s = String(UnicodeScalar(65 + n % 26)!) + s
            n = n / 26 - 1
        } while n >= 0
        return s
    }
}

/// 声音样本来源。
nonisolated enum VoiceSampleSourceKind: String, Codable, Sendable {
    case recordingSpan, importedFile
}

/// 采集信道：近场直录 / 系统或外放二次拾音 / 未知。
nonisolated enum VoiceChannel: String, Codable, Sendable {
    case nearField, speakerLoopback, unknown
}

/// 一段声音样本（纯净单人语音），声纹向量存 BLOB，不常驻内存。
nonisolated struct VoiceSample: Identifiable, Equatable, Sendable, Codable {
    var id: UUID
    var personID: UUID
    var sourceKind: VoiceSampleSourceKind
    var recordingID: UInt32?
    var startMs: Int
    var endMs: Int
    var managedFile: String?
    var channel: VoiceChannel
    /// 只有人工确认的样本进入标准声纹均值。
    var confirmed: Bool
    var modelVersion: String
    var contentHash: String
}

/// 一次发言归属：严格以原音毫秒区间定位。
nonisolated struct Utterance: Identifiable, Equatable, Sendable, Codable {
    var id: UUID
    var recordingID: UInt32
    var audioFingerprint: String
    var startMs: Int
    var endMs: Int
    var localSpeaker: Int
    var overlap: Bool
    var personID: UUID?
    var source: String   // auto / manual / unknown
    var score: Double
    var modelVersion: String
}

/// 人物资料与往来事项的种类。
nonisolated enum InsightKind: String, Codable, Sendable, CaseIterable {
    case bio, topic, commitment
}

/// 从谈话里抽取的、有原文依据的人物资料与往来事项。
nonisolated struct PersonInsight: Identifiable, Equatable, Sendable, Codable {
    var id: UUID
    var personID: UUID
    var kind: InsightKind
    var text: String
    var recordingID: UInt32?
    var startMs: Int?
    var endMs: Int?
    var occurredAt: Date?
    var editedByUser: Bool
    var modelVersion: String
    var stale: Bool
}
