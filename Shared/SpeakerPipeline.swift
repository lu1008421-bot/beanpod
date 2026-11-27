import Foundation

// MARK: - 双层来源筛选（第一层确定性元数据拦截 + 第二层声学信道门控）

extension Recording {
    /// 第一层：确定性元数据拦截。以下录音不自动参与声纹分人/建卡——
    /// 链接素材、语音输入、纯文字笔记、Mac「电脑声音」、用户手动排除出「人物」的录音。
    /// 场景（大会/课程/自媒体/灵感）要等整理出 `scene` 之后才拦（见 `blocksStrangerCreation`）。
    nonisolated var eligibleForAutoSpeaker: Bool {
        if isMaterial || isDictation || textOnly || peopleExcluded { return false }
        if let d = sourceDetail, d.contains("电脑声音") { return false }
        return true
    }

    /// 后置建卡拦截：整理出场景后，这几类场景不自动建陌生人卡（仍保留录音内说话人标签）。
    nonisolated func blocksStrangerCreation(_ scene: Scene?) -> Bool {
        guard let scene else { return false }
        return [.conference, .lesson, .media, .memo].contains(scene)
    }

    /// 第二层：声学信道。外放/系统混音只作辅助，不写标准声纹库；其余按近场直录处理。
    nonisolated var speakerChannel: VoiceChannel {
        if let d = sourceDetail, d.contains("电脑声音") { return .speakerLoopback }
        return .nearField
    }
}

// MARK: - 先分人后转写流水线

#if os(macOS)
/// 一段尚未自动建卡、等待场景确认后再决定是否升格的新声音（仅存中心向量与代表区间，不常驻音频）。
nonisolated struct StrangerCandidate: Sendable {
    var localSpeaker: Int
    var centroid: [Float]
    var seconds: Double
    var startMs: Int
    var endMs: Int
    var channel: VoiceChannel
}
#endif

extension BeanStore {
    /// 把一条录音里出现的本地说话人编号补进 `Recording.speakers`（默认「说话人 N」标签）。
    func syncLocalSpeakers(_ id: UInt32, from segments: [Segment]) {
        guard let i = recordings.firstIndex(where: { $0.id == id }) else { return }
        let used = Set(segments.compactMap(\.speaker))
        guard let top = used.max() else { return }
        while recordings[i].speakers.count < top + 1 {
            recordings[i].speakers.append(String(localized: "说话人 \(recordings[i].speakers.count + 1)"))
        }
    }

    /// 永久删除一条录音时，级联清理人物库里的派生数据（发言归属、人物资料、源自该录音的声音样本）。
    func purgePeopleForRecording(_ id: UInt32) {
        guard let db = peopleDB else { return }
        do {
            for s in suggestions() where s.recordingID == id { try db.deleteJob(id: s.id) }
            try db.deleteRecordingData(recordingID: id)
        }
        catch { peopleError = error.localizedDescription }
    }

    #if os(macOS)
    /// 声纹链路是否就绪（分割模型 + 声纹向量模型都已下载）。
    nonisolated var speakerPipelineReady: Bool {
        SpeakerEngine.hasSegmentationModel() && SpeakerEngine.hasEmbeddingModel()
    }

    /// 这条录音这次要不要走声纹：链路就绪 + 本地有 WAV + 第一层筛选通过。
    func speakerPathApplies(_ rec: Recording) -> Bool {
        speakerPipelineReady && rec.eligibleForAutoSpeaker && FileManager.default.fileExists(atPath: wavURL(rec.id).path)
    }

    /// 路径 A：先声纹分割、提取声纹并与人物库匹配、再按「说话人切换边界 + 停顿」切块送本机 ASR。
    /// 返回带 `speaker` 与 `end` 的句子；分人区间（发言归属）幂等写入人物库，人工归属保留并重新套到新句子上。
    func transcribeWithSpeakers(_ id: UInt32, progress: @Sendable @escaping (Double) -> Void) async throws -> [Segment] {
        let samples = try SpeakerEngine.loadMono16k(wavURL(id))
        let diar = await SpeakerEngine.shared.diarize(samples: samples)
        guard !diar.isEmpty else { throw SpeakerPipelineError.noSpeakerSegments }

        // 分人结果写进人物库：自动署名已有人物；没认出的先缓存，等场景确定后再决定建不建卡
        await attributeSpeakers(id, samples: samples, diar: diar)

        // 声纹引擎占着 ONNX 内存，转写前先释放，避免与 QwenASR/LocalLLM 叠加
        await SpeakerEngine.shared.reset()

        var segments: [Segment] = []
        let server = settings.llamaServerPath
        let rate = 16000
        let runs = Self.speakerRuns(diar)
        for (n, run) in runs.enumerated() {
            try Task.checkCancellation()
            progress(Double(n) / Double(max(1, runs.count)))
            guard run.end > run.start else { continue }
            let piece = Array(samples[run.start..<run.end])
            guard Self.hasSpeech(piece) else { continue }
            if run.end - run.start <= 15 * rate {
                let text = try await QwenASR.shared.transcribe(samples: piece, serverPath: server)
                if !text.isEmpty, !Self.isFiller(text) {
                    segments.append(Segment(start: Double(run.start) / Double(rate), text: text,
                                            speaker: run.speaker, end: Double(run.end) / Double(rate)))
                }
            } else {
                // 单人连续发言超过 15 秒：沿停顿切细，仍归属同一说话人
                for c in QwenASR.sentenceChunks(piece) {
                    let text = try await QwenASR.shared.transcribe(samples: Array(piece[c]), serverPath: server)
                    if !text.isEmpty, !Self.isFiller(text) {
                        segments.append(Segment(start: Double(run.start + c.lowerBound) / Double(rate), text: text,
                                                speaker: run.speaker, end: Double(run.start + c.upperBound) / Double(rate)))
                    }
                }
            }
        }
        progress(1)
        applyManualAttribution(id, to: &segments)
        return segments
    }

    /// 路径 B：文字稿不是按说话人切的（云端转写、系统识别）。本地有 WAV 时分人，再与现有句子按时间交集对齐。
    /// 整篇只有 `start = 0` 一句时没有逐句时间戳：不逐句归人，只留下可回听的声学时间线。
    func alignTranscriptWithSpeakers(_ id: UInt32, segments: inout [Segment]) async {
        guard let i = recordings.firstIndex(where: { $0.id == id }), speakerPathApplies(recordings[i]), !segments.isEmpty,
              let samples = try? SpeakerEngine.loadMono16k(wavURL(id)) else { return }
        let diar = await SpeakerEngine.shared.diarize(samples: samples)
        guard !diar.isEmpty else { return }
        await attributeSpeakers(id, samples: samples, diar: diar)
        await SpeakerEngine.shared.reset()

        let whole = segments.count == 1 && segments[0].start == 0
        guard !whole else { return }
        let runs = Self.speakerRuns(diar).map { (span: SpeakerAlignment.Span(start: Double($0.start) / 16000, end: Double($0.end) / 16000), speaker: $0.speaker) }
        let speakers = SpeakerAlignment.segmentSpeakers(
            segments: segments.map { SpeakerAlignment.Span(start: $0.start, end: $0.end ?? $0.start) }, runs: runs)
        for n in segments.indices where speakers[n] != nil { segments[n].speaker = speakers[n] }
        applyManualAttribution(id, to: &segments)
    }

    /// 分人后提取声纹、与人物库比对，并把区间写进发言表。
    private func attributeSpeakers(_ id: UInt32, samples: [Float], diar: [SpeakerEngine.DiarizedSegment]) async {
        let embeddings = await SpeakerEngine.shared.embeddings(for: samples, segments: diar)
        let matches = matchSpeakers(id, diar: diar, embeddings: embeddings)
        persistSpeakerRuns(id, diar: diar, matches: matches)
    }

    /// 把每个本地说话人的声纹与人物库比对，得出「自动署名 / 建议确认 / 新人」三档结论。
    /// 没认出的缓存进 `pendingStrangerCandidates`，等场景确定后再决定是否建卡。
    private func matchSpeakers(_ id: UInt32, diar: [SpeakerEngine.DiarizedSegment], embeddings: [SpeakerEngine.Embedding]) -> [Int: SpeakerMatchResult] {
        guard let db = peopleDB, let rec = recordings.first(where: { $0.id == id }) else { return [:] }

        var bySpeaker: [Int: [SpeakerEngine.Embedding]] = [:]
        for e in embeddings { bySpeaker[e.speaker, default: []].append(e) }

        // 候选：confirmed + pending（排除 ignored）；优先用已确认样本的中心向量
        let candidates = people.filter { $0.status != .ignored }.compactMap { p -> SpeakerCandidate? in
            let confirmed = (try? db.confirmedEmbeddings(personID: p.id)) ?? []
            let vecs = confirmed.isEmpty ? ((try? db.embeddings(personID: p.id)) ?? []) : confirmed
            guard let c = SpeakerMatcher.centroid(vecs) else { return nil }
            return SpeakerCandidate(personID: p.id, centroid: c)
        }
        let rejected = Set((try? db.rejectedPairs()) ?? [])
        let channel = rec.speakerChannel

        var results: [Int: SpeakerMatchResult] = [:]
        var strangers: [StrangerCandidate] = []
        // 上一次跑留下的旧建议作废，以这次为准
        for old in (try? db.listSuggestions()) ?? [] where old.recordingID == id { try? db.deleteJob(id: old.id) }
        for (spk, embs) in bySpeaker {
            guard let centroid = SpeakerMatcher.centroid(embs.map(\.vector)) else { continue }
            let res = SpeakerMatcher.match(centroid: centroid, candidates: candidates, rejectedKeys: rejected) { pid in
                "\(pid.uuidString)|\(id)-\(spk)"
            }
            results[spk] = res

            switch res.tier {
            case .auto:
                if let pid = res.personID { try? db.setLastMet(id: pid, rec.date) }
            case .suggest:
                // 像某位已有人物但分数不够：记一条「建议确认」，人物页给出「就是 TA / 不是」
                if let top = res.topCandidateID, let cand = stranger(spk, embs, centroid, channel) {
                    try? db.recordJob(kind: "speaker_suggestion",
                                      payload: SpeakerSuggestion(id: "", recordingID: id, localSpeaker: spk, candidateID: top, score: res.score,
                                                                 vector: centroid, startMs: cand.startMs, endMs: cand.endMs).payload)
                    strangers.append(cand)
                }
            case .newPerson:
                if let c = stranger(spk, embs, centroid, channel) { strangers.append(c) }
            }
        }
        pendingStrangerCandidates[id] = strangers
        return results
    }

    private func stranger(_ spk: Int, _ embs: [SpeakerEngine.Embedding], _ centroid: [Float], _ channel: VoiceChannel) -> StrangerCandidate? {
        let sec = embs.map(\.duration).reduce(0, +)
        guard sec > 0 else { return nil }
        return StrangerCandidate(localSpeaker: spk, centroid: centroid,
                          seconds: sec,
                          startMs: embs.map { Int($0.start * 1000) }.min() ?? 0,
                          endMs: embs.map { Int($0.end * 1000) }.max() ?? 0, channel: channel)
    }

    /// 场景确定后调用：对达标（≥ 30 秒清晰发言）、场景允许的近场声音建待认识卡并记代表样本。
    func finalizeStrangerCards(_ id: UInt32) {
        guard let db = peopleDB, let rec = recordings.first(where: { $0.id == id }),
              let candidates = pendingStrangerCandidates.removeValue(forKey: id) else { return }
        guard !rec.blocksStrangerCreation(rec.scene) else { return }

        for c in candidates where c.seconds >= SpeakerMatcher.minStrangerSeconds {
            do {
                let person = try db.createPerson(displayName: "", status: .pending)
                let sample = VoiceSample(id: UUID(), personID: person.id, sourceKind: .recordingSpan, recordingID: id,
                                         startMs: c.startMs, endMs: c.endMs, managedFile: nil, channel: c.channel,
                                         confirmed: false, modelVersion: SpeakerEngine.embeddingCAMPPName,
                                         contentHash: "recording-\(id)-\(c.startMs)-\(c.endMs)")
                try db.addSample(sample, embedding: c.centroid)
                try db.assignUtterancesByLocalSpeaker(recordingID: id, localSpeaker: c.localSpeaker, personID: person.id)
                try db.setLastMet(id: person.id, rec.date)
            } catch { peopleError = error.localizedDescription }
        }
        reloadPeople()
    }

    /// 把相邻同说话人、间隔 < 0.5 秒的分割段并成「说话人轮次」，区间以 16 kHz 样本下标表示。
    nonisolated static func speakerRuns(_ diar: [SpeakerEngine.DiarizedSegment]) -> [(start: Int, end: Int, speaker: Int, overlap: Bool)] {
        let rate = 16000
        var runs: [(start: Int, end: Int, speaker: Int, overlap: Bool)] = []
        for s in diar {
            let lo = max(0, Int((s.start * Double(rate)).rounded(.down)))
            let hi = max(lo, Int((s.end * Double(rate)).rounded(.up)))
            if var last = runs.last, last.speaker == s.speaker, lo - last.end < rate / 2 {
                last.end = max(last.end, hi)
                last.overlap = last.overlap || s.overlap
                runs[runs.count - 1] = last
            } else {
                runs.append((lo, hi, s.speaker, s.overlap))
            }
        }
        return runs
    }

    /// 把分人结果写进人物表：只替换自动归属，人工 `manual` 区间保留，自动区间让开人工区间。
    private func persistSpeakerRuns(_ id: UInt32, diar: [SpeakerEngine.DiarizedSegment], matches: [Int: SpeakerMatchResult]) {
        guard let db = peopleDB else { return }
        let manualSpans = ((try? db.listUtterances(recordingID: id)) ?? []).filter { $0.source == "manual" }
            .map { SpeakerAlignment.Span(start: Double($0.startMs) / 1000, end: Double($0.endMs) / 1000) }
        let auto = Self.speakerRuns(diar).map { run in
            let m = matches[run.speaker]
            return Utterance(id: UUID(), recordingID: id, audioFingerprint: "recording-\(id)",
                             startMs: run.start * 1000 / 16000, endMs: run.end * 1000 / 16000,
                             localSpeaker: run.speaker, overlap: run.overlap,
                             personID: m?.tier == .auto ? m?.personID : nil,
                             source: "auto", score: Double(m?.score ?? 0), modelVersion: SpeakerEngine.embeddingCAMPPName)
        }
        let clipped = SpeakerAlignment.clipAuto(auto, manual: manualSpans,
                                                span: { SpeakerAlignment.Span(start: Double($0.startMs) / 1000, end: Double($0.endMs) / 1000) }) { u, s in
            var v = u; v.startMs = Int(s.start * 1000); v.endMs = Int(s.end * 1000); return v
        }
        do { try db.replaceAutoUtterances(recordingID: id, clipped) }
        catch { peopleError = error.localizedDescription }
    }

    /// 人工改过的句子（`manual` 归属）重新套到新转出来的句子上：中点落在人工区间内的，用人工指定的说话人槽位。
    func applyManualAttribution(_ id: UInt32, to segments: inout [Segment]) {
        guard let db = peopleDB, let i = recordings.firstIndex(where: { $0.id == id }) else { return }
        let manual = ((try? db.listUtterances(recordingID: id)) ?? []).filter { $0.source == "manual" }
        guard !manual.isEmpty, !segments.isEmpty else { return }
        let mapped = SpeakerAlignment.applyManual(
            segments: segments.map { SpeakerAlignment.Span(start: $0.start, end: $0.end ?? $0.start) },
            manual: manual.map { (span: SpeakerAlignment.Span(start: Double($0.startMs) / 1000, end: Double($0.endMs) / 1000), speaker: $0.localSpeaker) })
        let top = (manual.map(\.localSpeaker).max() ?? -1) + 1
        while recordings[i].speakers.count < top { recordings[i].speakers.append(String(localized: "说话人 \(recordings[i].speakers.count + 1)")) }
        for n in segments.indices where mapped[n] != nil { segments[n].speaker = mapped[n] }
    }
    #endif
}

enum SpeakerPipelineError: LocalizedError {
    case noSpeakerSegments

    var errorDescription: String? {
        switch self {
        case .noSpeakerSegments: String(localized: "声纹模型没分出说话人，先按整段转写。")
        }
    }
}
