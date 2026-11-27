import Foundation

// MARK: - 双层来源筛选（第一层确定性元数据拦截 + 第二层声学信道门控）

extension Recording {
    /// 第一层：确定性元数据拦截。以下录音不自动参与声纹分人/建卡——
    /// 链接素材、语音输入、纯文字笔记、Mac「电脑声音」。
    /// 场景（大会/课程/自媒体/灵感）要等整理出 `scene` 之后才拦（见 `blocksStrangerCreation`）。
    nonisolated var eligibleForAutoSpeaker: Bool {
        if isMaterial || isDictation || textOnly { return false }
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
        let used = Set(segments.compactMap(\.speaker)).sorted()
        guard !used.isEmpty else { return }
        while recordings[i].speakers.count < (used.max() ?? 0) + 1 {
            recordings[i].speakers.append(String(localized: "说话人 \(recordings[i].speakers.count + 1)"))
        }
    }

    /// 永久删除一条录音时，级联清理人物库里的派生数据（发言归属、人物资料、源自该录音的声音样本）。
    func purgePeopleForRecording(_ id: UInt32) {
        guard let db = peopleDB else { return }
        do { try db.deleteRecordingData(recordingID: id) }
        catch { peopleError = error.localizedDescription }
    }

    #if os(macOS)
    /// 声纹链路是否就绪（分割模型 + 声纹向量模型都已下载）。
    nonisolated var speakerPipelineReady: Bool {
        SpeakerEngine.hasSegmentationModel() && SpeakerEngine.hasEmbeddingModel()
    }

    /// 路径 A：先声纹分割、提取声纹并与人物库匹配、再按「说话人切换边界 + 停顿」切块送本机 ASR。
    /// 返回带 `speaker` 与 `end` 的句子；同时把分人区间（发言归属）幂等写入人物库。
    /// 自动署名只落到已确认/待认识人物；陌生人的建卡延迟到 `finalizeStrangerCards`（等场景确定）。
    func transcribeWithSpeakers(_ id: UInt32, progress: @Sendable @escaping (Double) -> Void) async throws -> [Segment] {
        let samples = try SpeakerEngine.loadMono16k(wavURL(id))
        let diar = await SpeakerEngine.shared.diarize(samples: samples)
        guard !diar.isEmpty else { throw SpeakerPipelineError.noSpeakerSegments }

        // 提取非重叠单人段声纹，并据此匹配人物库
        let embeddings = await SpeakerEngine.shared.embeddings(for: samples, segments: diar)
        let matches = matchSpeakers(id, diar: diar, embeddings: embeddings)
        persistSpeakerRuns(id, samples: samples, diar: diar, matches: matches)

        // 声纹引擎占着 ONNX 内存，转写前先释放，避免与 QwenASR/LocalLLM 叠加
        await SpeakerEngine.shared.reset()

        let runs = Self.speakerRuns(diar)
        var segments: [Segment] = []
        let server = settings.llamaServerPath
        let rate = 16000
        for (i, run) in runs.enumerated() {
            try Task.checkCancellation()
            progress(Double(i) / Double(max(1, runs.count)))
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
        syncPeopleToLibrary([id])
        return segments
    }

    /// 分人后把每个本地说话人的声纹与人物库比对，得出「自动署名 / 建议确认 / 新人」三档结论。
    /// 同时把还没达标的「新人」缓存进 `pendingStrangerCandidates`，等场景确定后再决定是否建卡。
    private func matchSpeakers(_ id: UInt32, diar: [SpeakerEngine.DiarizedSegment], embeddings: [SpeakerEngine.Embedding]) -> [Int: SpeakerMatchResult] {
        guard let db = peopleDB, let rec = recordings.first(where: { $0.id == id }) else { return [:] }

        var bySpeaker: [Int: [SpeakerEngine.Embedding]] = [:]
        for e in embeddings { bySpeaker[e.speaker, default: []].append(e) }

        // 候选：confirmed + pending + 我（排除 ignored）
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
        for (spk, embs) in bySpeaker {
            guard let centroid = SpeakerMatcher.centroid(embs.map(\.vector)) else { continue }
            let res = SpeakerMatcher.match(centroid: centroid, candidates: candidates, rejectedKeys: rejected) { pid in
                "\(pid.uuidString)|\(id)-\(spk)"
            }
            results[spk] = res

            switch res.tier {
            case .auto:
                // 自动署名到已有人物：更新最近交流
                if let pid = res.personID { try? db.setLastMet(id: pid, rec.date) }
            case .suggest:
                // 建议确认：记一条候选，交给后续「合并到 TA」的界面
                if let top = res.topCandidateID {
                    let payload: [String: Any] = ["recordingID": id, "localSpeaker": spk, "candidateID": top.uuidString, "score": res.score]
                    if let data = try? JSONSerialization.data(withJSONObject: payload) {
                        try? db.recordJob(kind: "speaker_suggestion", payload: String(data: data, encoding: .utf8))
                    }
                }
                fallthrough
            case .newPerson:
                let seconds = embs.map(\.duration).reduce(0, +)
                let startMs = embs.map { Int($0.start * 1000) }.min() ?? 0
                let endMs = embs.map { Int($0.end * 1000) }.max() ?? 0
                strangers.append(StrangerCandidate(localSpeaker: spk, centroid: centroid, seconds: seconds,
                                                   startMs: startMs, endMs: endMs, channel: channel))
            }
        }
        pendingStrangerCandidates[id] = strangers
        return results
    }

    /// 场景确定后调用：对达标（≥ 30 秒清晰发言）且场景允许的近场声音建待认识卡并记代表样本。
    func finalizeStrangerCards(_ id: UInt32) {
        guard let db = peopleDB, let rec = recordings.first(where: { $0.id == id }),
              let candidates = pendingStrangerCandidates[id] else { return }
        pendingStrangerCandidates[id] = nil
        guard !rec.blocksStrangerCreation(rec.scene) else { return }

        for c in candidates where c.seconds >= 30 {
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
        syncPeopleToLibrary([id])
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

    /// 把分人结果写进人物库发言表。只替换自动归属，保留人工 `manual` 归属（重转写不覆盖人工）。
    func persistSpeakerRuns(_ id: UInt32, samples: [Float], diar: [SpeakerEngine.DiarizedSegment], matches: [Int: SpeakerMatchResult]) {
        guard let db = peopleDB else { return }
        let fp = "recording-\(id)-\(samples.count)"
        let runs = Self.speakerRuns(diar)
        let utterances = runs.map { run in
            let m = matches[run.speaker]
            return Utterance(id: UUID(), recordingID: id, audioFingerprint: fp,
                             startMs: run.start * 1000 / 16000, endMs: run.end * 1000 / 16000,
                             localSpeaker: run.speaker, overlap: run.overlap,
                             personID: m?.tier == .auto ? m?.personID : nil,
                             source: "auto", score: Double(m?.score ?? 0), modelVersion: SpeakerEngine.embeddingCAMPPName)
        }
        do { try db.replaceAutoUtterances(recordingID: id, utterances) }
        catch { peopleError = error.localizedDescription }
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
