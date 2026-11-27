import Foundation

// MARK: - 双层来源筛选（第一层确定性元数据拦截 + 第二层声学信道门控）

extension Recording {
    /// 第一层：确定性元数据拦截。以下录音不自动参与声纹建卡与陌生人发现——
    /// 链接素材、语音输入、纯文字笔记、Mac「电脑声音」、大会/课程/自媒体/灵感类场景。
    nonisolated var eligibleForAutoSpeaker: Bool {
        if isMaterial || isDictation || textOnly { return false }
        if let d = sourceDetail, d.contains("电脑声音") { return false }
        if let s = scene, [.conference, .lesson, .media, .memo].contains(s) { return false }
        return true
    }

    /// 第二层：声学信道。外放/系统混音只作辅助，不写标准声纹库；其余按近场直录处理。
    nonisolated var speakerChannel: VoiceChannel {
        if let d = sourceDetail, d.contains("电脑声音") { return .speakerLoopback }
        return .nearField
    }
}

// MARK: - 先分人后转写流水线

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

    /// 路径 A：先声纹分割、再按「说话人切换边界 + 停顿」切块送本机 ASR。
    /// 返回带 `speaker` 与 `end` 的句子；同时把分人区间（发言归属）幂等写入人物库。
    func transcribeWithSpeakers(_ id: UInt32, progress: @Sendable @escaping (Double) -> Void) async throws -> [Segment] {
        let samples = try SpeakerEngine.loadMono16k(wavURL(id))
        let diar = await SpeakerEngine.shared.diarize(samples: samples)
        guard !diar.isEmpty else { throw SpeakerPipelineError.noSpeakerSegments }
        persistSpeakerRuns(id, samples: samples, diar: diar)

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
        return segments
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

    /// 把分人结果写进人物库发言表。幂等：按录音 ID 整体替换，重跑不重复。
    func persistSpeakerRuns(_ id: UInt32, samples: [Float], diar: [SpeakerEngine.DiarizedSegment]) {
        guard let db = peopleDB else { return }
        let fp = "recording-\(id)-\(samples.count)"
        let runs = Self.speakerRuns(diar)
        let utterances = runs.map { run in
            Utterance(id: UUID(), recordingID: id, audioFingerprint: fp,
                      startMs: run.start * 1000 / 16000, endMs: run.end * 1000 / 16000,
                      localSpeaker: run.speaker, overlap: run.overlap,
                      personID: nil, source: "auto", score: 0, modelVersion: SpeakerEngine.embeddingCAMPPName)
        }
        do { try db.replaceUtterances(recordingID: id, utterances) }
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
