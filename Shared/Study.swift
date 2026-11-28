import BeanKit
import Foundation

/// 英语学习模式整理出来的东西（设计稿 design/ui/ui_study.png）：难度概览、重点单词（带等级）、短语搭配、难句解析。
/// 用户在纪要页勾上「英语学习模式」才整理；不勾就是普通纪要。
nonisolated struct Study: Codable, Equatable {
    struct Word: Codable, Equatable, Identifiable {
        var word: String
        var phonetic: String = ""
        var pos: String = ""
        /// CEFR 等级：A1 A2 B1 B2 C1 C2
        var level: String = ""
        var meaning: String = ""
        var example: String?
        /// 原句在音频里的时间（点一下回听）；对不上就是空
        var time: TimeInterval?
        var id: String { word.lowercased() }
    }

    struct Phrase: Codable, Equatable, Identifiable {
        var phrase: String
        var meaning: String = ""
        var example: String?
        var time: TimeInterval?
        var id: String { phrase.lowercased() }
    }

    struct Sentence: Codable, Equatable, Identifiable {
        var text: String
        var translation: String = ""
        /// 句子结构拆解
        var structure: String = ""
        /// 语法、用法要点
        var points: String = ""
        var time: TimeInterval?
        var id: String { text }
    }

    /// 整体难度，比如「B2」
    var overall: String = ""
    /// 一句话概览，比如「中高级，日常话题，语速偏快」
    var note: String = ""
    /// 词汇分级占比（百分比）：A1–A2、B1、B2、C1–C2
    var levels: [String: Double] = [:]
    /// 语速（词/分钟），按文字稿和时长算
    var wordsPerMinute: Int?
    var words: [Word] = []
    var phrases: [Phrase] = []
    var sentences: [Sentence] = []
    var model: String = ""
    var date = Date()

    static let levelBands = ["A1–A2", "B1", "B2", "C1–C2"]
}

extension BeanStore {
    /// 文字稿主要是英文才给「英语学习模式」（中英夹杂的英语节目也算：拉丁字母占四成以上）。
    nonisolated static func isMostlyEnglish(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count > 40 else { return false }
        return Double(letters.filter(\.isASCII).count) / Double(letters.count) > 0.4
    }

    /// 勾上 / 取消「英语学习模式」。勾上且还没整理过就开始整理。
    func setStudyMode(_ id: UInt32, _ on: Bool) {
        guard let i = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[i].studyMode = on
        saveLibrary()
        if on, recordings[i].study == nil { study(id) }
    }

    /// 按学英语的需要整理一条录音：用整理纪要的那个模型。
    func study(_ id: UInt32) {
        guard let rec = recordings.first(where: { $0.id == id }), let text = rec.transcript, !text.isEmpty,
              !studying.contains(id) else { return }
        guard analysisAvailable else {
            problem = Problem(title: String(localized: "还没设置整理纪要的模型"), detail: String(localized: "英语学习模式要用模型来分级单词、解析句子。先在设置里选一个本机模型，或者填自己的云端模型。"), action: .settings)
            return
        }
        studying.insert(id)
        addLog("开始英语学习整理 \(id)")
        // 太长的只取前面一段（约 1.6 万字符，大约 25 分钟的英语），够挑出重点词句
        let excerpt = String(text.prefix(16_000))
        Task {
            defer { studying.remove(id) }
            do {
                let (reply, model) = try await withLLM(task: .study, tier: .primary, recordingID: id) { config in
                    let res = try await Analyzer.chatDetailed(config, system: Self.studyPrompt, user: excerpt, json: true)
                    return ((res.content, config.model), res.usage)
                }
                var s = try Self.parseStudy(Analyzer.stripThinking(reply))
                s.model = model
                guard let i = recordings.firstIndex(where: { $0.id == id }) else { return }
                Self.locate(&s, in: recordings[i])
                // 语速按整条文字稿算（送给模型的只是前一段，不能拿它除以整条时长）
                let words = text.split { !$0.isLetter && $0 != "'" }.filter { $0.allSatisfy(\.isASCII) }.count
                if recordings[i].duration > 30, words > 50 { s.wordsPerMinute = Int(Double(words) / (recordings[i].duration / 60)) }
                recordings[i].study = s
                saveLibrary()
                addLog("英语学习整理完成 \(id)：\(s.words.count) 词 \(s.phrases.count) 短语 \(s.sentences.count) 难句，模型 \(model)")
                toast("graduationcap", String(localized: "学习笔记整理好了：\(String(rec.displayTitle.prefix(16)))"))
            } catch {
                problem = Problem(title: String(localized: "没能整理学习笔记"), detail: error.localizedDescription)
            }
        }
    }

    nonisolated static let studyPrompt = """
    你是给中文母语者做英语听力精讲的老师。用户给你一段英语音频（播客、访谈、课程）的文字稿，可能夹着中文。
    按学英语的需要整理，只输出一个 JSON 对象，字段如下（全部用简体中文解释，英文原文照抄）：
    {
      "overall": "整体难度的 CEFR 等级，如 B2",
      "note": "一句话概览：难度、话题、语速口音等，20 字以内",
      "levels": {"A1–A2": 百分比, "B1": 百分比, "B2": 百分比, "C1–C2": 百分比},   // 文中词汇按 CEFR 分级的大致占比，加起来 100
      "words": [ {"word": "原形", "phonetic": "英式或美式音标，带斜杠", "pos": "词性缩写如 n. v. adj.", "level": "CEFR 等级如 B2", "meaning": "在这段话里的中文意思", "example": "文中出现这个词的原句，一字不差照抄"} ],
      "phrases": [ {"phrase": "短语或固定搭配", "meaning": "中文意思", "example": "文中原句，一字不差照抄"} ],
      "sentences": [ {"text": "文中较难或很有用的原句，一字不差照抄", "translation": "通顺的中文译文", "structure": "句子结构拆解：主干、从句、修饰成分", "points": "语法或用法要点，1～2 条"} ]
    }
    要求：
    - words 挑 20～30 个最值得学的词：B1 及以上优先、在文中意思关键、常用；不要人名地名品牌名，不要广告里的词，不要 the/and 这类基础词。按 level 从高到低排。
    - phrases 挑 8～12 个地道的短语、搭配、口语说法。
    - sentences 挑 4～6 句：结构复杂、听起来容易卡住、或特别值得模仿的句子。
    - example 和 text 必须是文中原句（可以截取一句），方便回到音频里听。
    只输出 JSON，不要任何别的文字。
    """

    nonisolated static func parseStudy(_ reply: String) throws -> Study {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}") else {
            throw AnalyzerError.badReply(String(localized: "模型没按格式回复"))
        }
        let data = Data(reply[start...end].utf8)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AnalyzerError.badReply(String(localized: "模型没按格式回复")) }
        func str(_ d: [String: Any], _ k: String) -> String { (d[k] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        var s = Study()
        s.overall = str(obj, "overall").uppercased()
        s.note = str(obj, "note")
        if let lv = obj["levels"] as? [String: Any] {
            for (k, v) in lv {
                let key = k.replacingOccurrences(of: "-", with: "–").replacingOccurrences(of: " ", with: "")
                let n = (v as? Double) ?? (v as? Int).map(Double.init) ?? Double("\(v)".filter { $0.isNumber || $0 == "." }) ?? 0
                if let band = Study.levelBands.first(where: { $0 == key }) { s.levels[band] = n }
            }
        }
        let order = ["C2": 0, "C1": 1, "B2": 2, "B1": 3, "A2": 4, "A1": 5]
        s.words = (obj["words"] as? [[String: Any]] ?? []).compactMap { d in
            let w = str(d, "word"); guard !w.isEmpty else { return nil }
            return Study.Word(word: w, phonetic: str(d, "phonetic"), pos: str(d, "pos"), level: str(d, "level").uppercased(),
                              meaning: str(d, "meaning"), example: str(d, "example").nilIfEmpty)
        }.sorted { (order[$0.level] ?? 9) < (order[$1.level] ?? 9) }
        s.phrases = (obj["phrases"] as? [[String: Any]] ?? []).compactMap { d in
            let p = str(d, "phrase"); guard !p.isEmpty else { return nil }
            return Study.Phrase(phrase: p, meaning: str(d, "meaning"), example: str(d, "example").nilIfEmpty)
        }
        s.sentences = (obj["sentences"] as? [[String: Any]] ?? []).compactMap { d in
            let t = str(d, "text"); guard !t.isEmpty else { return nil }
            return Study.Sentence(text: t, translation: str(d, "translation"), structure: str(d, "structure"), points: str(d, "points"))
        }
        guard !s.words.isEmpty || !s.sentences.isEmpty else { throw AnalyzerError.badReply(String(localized: "模型没整理出单词和句子")) }
        return s
    }

    /// 给例句找到它在音频里的时间：在分句里找含有这句开头一段的那一句。
    nonisolated static func locate(_ s: inout Study, in r: Recording) {
        func norm(_ t: String) -> String { t.lowercased().filter { $0.isLetter || $0.isNumber } }
        let segs = r.segments.map { ($0.start, norm($0.clean ?? $0.text)) }
        func time(_ text: String?) -> TimeInterval? {
            guard let text else { return nil }
            let key = String(norm(text).prefix(24))
            guard key.count >= 8 else { return nil }
            return segs.first { $0.1.contains(key) }?.0
        }
        for i in s.words.indices { s.words[i].time = time(s.words[i].example) }
        for i in s.phrases.indices { s.phrases[i].time = time(s.phrases[i].example) }
        for i in s.sentences.indices { s.sentences[i].time = time(s.sentences[i].text) }
    }
}

// 每个字段都容错读取：以后加字段、改字段，旧的学习笔记照样能打开，不会整份丢掉
extension Study {
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        overall = (try? c.decodeIfPresent(String.self, forKey: .overall)) ?? ""
        note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? ""
        levels = (try? c.decodeIfPresent([String: Double].self, forKey: .levels)) ?? [:]
        wordsPerMinute = try? c.decodeIfPresent(Int.self, forKey: .wordsPerMinute)
        words = (try? c.decodeIfPresent([Word].self, forKey: .words)) ?? []
        phrases = (try? c.decodeIfPresent([Phrase].self, forKey: .phrases)) ?? []
        sentences = (try? c.decodeIfPresent([Sentence].self, forKey: .sentences)) ?? []
        model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? ""
        date = (try? c.decodeIfPresent(Date.self, forKey: .date)) ?? Date()
    }
}

private extension String {
    nonisolated var nilIfEmpty: String? { isEmpty ? nil : self }
}
