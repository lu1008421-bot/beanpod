import AVFoundation
import Foundation
import SherpaOnnx

/// 说话人分割与声纹识别引擎。
///
/// 为什么单独一个 actor：`sherpa-onnx` 的 Swift 封装持有 C `OpaquePointer`，既不是 `Sendable`
/// 也不该在 MainActor 上跑；BeanPod 工程默认把代码隔离到 MainActor，所以把推理收敛进这个 actor，
/// 让 C 推理在后台串行执行，只把 `Sendable` 的纯值类型结果交还给界面和 `BeanStore`。
actor SpeakerEngine {
    static let shared = SpeakerEngine()

    // MARK: - 模型文件（在 BeanPod/Models/speaker/ 下，由 ModelDownloader 下载）

    /// 说话人分割模型（首选 Pyannote 3.0）。文件名须与 `Shared/SpeakerModels.swift` 保持一致。
    static let segmentationName = "model.onnx"
    /// 中英声纹向量（首选，192 维 CAM++）。文件名须与 `Shared/SpeakerModels.swift` 保持一致。
    static let embeddingCAMPPName = "3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx"
    /// 中文声纹向量（P1 对照组，ERes2Net）。文件名须与 `Shared/SpeakerModels.swift` 保持一致。
    static let embeddingERes2NetName = "3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx"

    nonisolated static var modelFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeanPod/Models/speaker", isDirectory: true)
    }

    // MARK: - 纯值类型（Sendable，跨隔离边界安全）

    /// 一条录音内分出的一段话。`speaker` 是录音内临时编号；`overlap` 表示它与另一人的区间有交叠。
    struct DiarizedSegment: Sendable, Equatable {
        var start: TimeInterval
        var end: TimeInterval
        var speaker: Int
        var overlap: Bool = false
    }

    /// 一段纯净单人语音提取到的声纹向量（已归一化）。
    struct Embedding: Sendable, Equatable {
        var vector: [Float]
        var start: TimeInterval
        var end: TimeInterval
        var speaker: Int
        var duration: TimeInterval { end - start }
    }

    // MARK: - 缓存（非 Sendable，只在 actor 内）

    private var diarizer: SherpaOnnxOfflineSpeakerDiarizationWrapper?
    private var diarizerSegModel: URL?
    private var diarizerEmbModel: URL?
    private var extractor: SherpaOnnxSpeakerEmbeddingExtractorWrapper?
    private var extractorModel: URL?

    // MARK: - 就绪状态

    /// 需要的模型文件是否都已下载。
    nonisolated static func modelFile(_ name: String) -> URL {
        modelFolder.appendingPathComponent(name)
    }

    nonisolated static func hasSegmentationModel() -> Bool {
        FileManager.default.fileExists(atPath: modelFile(segmentationName).path)
    }

    nonisolated static func hasEmbeddingModel(_ name: String = embeddingCAMPPName) -> Bool {
        FileManager.default.fileExists(atPath: modelFile(name).path)
    }

    /// 释放缓存的 C 引擎，重跑实验或切换模型前调用。
    func reset() {
        diarizer = nil
        extractor = nil
        diarizerSegModel = nil
        diarizerEmbModel = nil
        extractorModel = nil
    }

    // MARK: - 音频读取

    /// 用系统原生 `AVAudioFile`/`AVAudioConverter` 把任意 CoreAudio 支持格式读到 16 kHz 单声道浮点，
    /// 不依赖 `ffmpeg`。供说话人分割与声纹提取统一使用。
    nonisolated static func loadMono16k(_ url: URL) throws -> [Float] {
        guard let file = try? AVAudioFile(forReading: url),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw SpeakerEngineError.badAudio
        }
        try file.read(into: input)
        if file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1, let d = input.floatChannelData {
            return Array(UnsafeBufferPointer(start: d[0], count: Int(input.frameLength)))
        }
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(input.frameLength) * 16000 / file.processingFormat.sampleRate) + 1024) else {
            throw SpeakerEngineError.badAudio
        }
        nonisolated(unsafe) var pending: AVAudioPCMBuffer? = input
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if let b = pending { pending = nil; status.pointee = .haveData; return b }
            status.pointee = .endOfStream; return nil
        }
        guard error == nil, let d = output.floatChannelData else { throw SpeakerEngineError.badAudio }
        return Array(UnsafeBufferPointer(start: d[0], count: Int(output.frameLength)))
    }

    // MARK: - 说话人分割

    /// 对整段 16 kHz 单声道采样做离线说话人分割，按开始时间排序，并标记交叠区间。
    /// - Parameters:
    ///   - samples: 16 kHz 单声道浮点采样
    ///   - numClusters: 已知说话人数，`-1` 表示自动
    ///   - threshold: FastClustering 阈值
    func diarize(samples: [Float], numClusters: Int = -1, threshold: Float = 0.5, numThreads: Int = 1) -> [DiarizedSegment] {
        let segURL = Self.modelFile(Self.segmentationName)
        let embURL = Self.modelFile(Self.embeddingCAMPPName)
        guard FileManager.default.fileExists(atPath: segURL.path),
              FileManager.default.fileExists(atPath: embURL.path) else { return [] }

        let d = ensureDiarizer(segmentation: segURL, embedding: embURL, numClusters: numClusters, threshold: threshold, numThreads: numThreads)
        guard let d else { return [] }

        let raw = d.process(samples: samples)
        let segments = raw.map { DiarizedSegment(start: Double($0.start), end: Double($0.end), speaker: $0.speaker) }
        return Self.markOverlaps(segments)
    }

    private func ensureDiarizer(segmentation: URL, embedding: URL, numClusters: Int, threshold: Float, numThreads: Int) -> SherpaOnnxOfflineSpeakerDiarizationWrapper? {
        if let diarizer, diarizerSegModel == segmentation, diarizerEmbModel == embedding {
            // 只改聚类参数时复用引擎；sherpa-onnx 的 setConfig 只吃 clustering 字段
            var cfg = sherpaOnnxOfflineSpeakerDiarizationConfig(
                segmentation: sherpaOnnxOfflineSpeakerSegmentationModelConfig(
                    pyannote: sherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig(model: segmentation.path),
                    numThreads: numThreads),
                embedding: sherpaOnnxSpeakerEmbeddingExtractorConfig(model: embedding.path, numThreads: numThreads),
                clustering: sherpaOnnxFastClusteringConfig(numClusters: numClusters, threshold: threshold))
            diarizer.setConfig(config: &cfg)
            return diarizer
        }

        var cfg = sherpaOnnxOfflineSpeakerDiarizationConfig(
            segmentation: sherpaOnnxOfflineSpeakerSegmentationModelConfig(
                pyannote: sherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig(model: segmentation.path),
                numThreads: numThreads),
            embedding: sherpaOnnxSpeakerEmbeddingExtractorConfig(model: embedding.path, numThreads: numThreads),
            clustering: sherpaOnnxFastClusteringConfig(numClusters: numClusters, threshold: threshold))
        let d = SherpaOnnxOfflineSpeakerDiarizationWrapper(config: &cfg)
        diarizer = d
        diarizerSegModel = segmentation
        diarizerEmbModel = embedding
        return d
    }

    /// 对不同临时说话人的时间区间两两求交集，凡有交叠就标记 `overlap = true`。
    nonisolated static func markOverlaps(_ segments: [DiarizedSegment]) -> [DiarizedSegment] {
        var out = segments
        for i in 0..<out.count {
            for j in (i + 1)..<out.count where out[i].speaker != out[j].speaker {
                let a = out[i], b = out[j]
                let s = max(a.start, b.start), e = min(a.end, b.end)
                if s < e { out[i].overlap = true; out[j].overlap = true }
            }
        }
        return out
    }

    // MARK: - 声纹提取

    /// 对分好的段落提取声纹向量。交叠段、过短段、能量过低的静音/噪声段会剔除。
    /// - Parameters:
    ///   - samples: 16 kHz 单声道采样（与 diarize 同一份）
    ///   - segments: diarize 的结果
    ///   - embeddingModel: 声纹模型文件名
    ///   - minDuration: 最短有效语音时长（秒）
    func embeddings(for samples: [Float], segments: [DiarizedSegment], embeddingModel: String = SpeakerEngine.embeddingCAMPPName, minDuration: TimeInterval = 1.2, minRMS: Float = 0.0015) -> [Embedding] {
        let modelURL = Self.modelFile(embeddingModel)
        guard FileManager.default.fileExists(atPath: modelURL.path) else { return [] }

        let ex = ensureExtractor(model: modelURL)
        guard let ex else { return [] }

        let rate = 16000
        var out: [Embedding] = []
        for seg in segments {
            guard !seg.overlap, seg.end - seg.start >= minDuration else { continue }
            let lo = min(samples.count, max(0, Int(seg.start * Double(rate))))
            let hi = min(samples.count, max(lo, Int(seg.end * Double(rate))))
            guard hi - lo > rate / 4 else { continue }
            let piece = Array(samples[lo..<hi])
            guard Self.rms(piece) > minRMS else { continue }
            let stream = ex.createStream()
            stream.acceptWaveform(samples: piece, sampleRate: rate)
            stream.inputFinished()
            let vector = ex.compute(stream: stream)
            guard !vector.isEmpty else { continue }
            out.append(Embedding(vector: vector, start: seg.start, end: seg.end, speaker: seg.speaker))
        }
        return out
    }

    private func ensureExtractor(model: URL) -> SherpaOnnxSpeakerEmbeddingExtractorWrapper? {
        if let extractor, extractorModel == model { return extractor }
        var cfg = sherpaOnnxSpeakerEmbeddingExtractorConfig(model: model.path)
        let ex = SherpaOnnxSpeakerEmbeddingExtractorWrapper(config: &cfg)
        extractor = ex
        extractorModel = model
        return ex
    }

    /// 把整段语音当作一个人，提取一个声纹向量（用于跨录音比对 / 导入样本建档）。
    func embedWhole(_ samples: [Float], embeddingModel: String = SpeakerEngine.embeddingCAMPPName) -> [Float]? {
        let modelURL = Self.modelFile(embeddingModel)
        guard FileManager.default.fileExists(atPath: modelURL.path) else { return nil }
        let ex = ensureExtractor(model: modelURL)
        guard let ex else { return nil }
        let stream = ex.createStream()
        stream.acceptWaveform(samples: samples, sampleRate: 16000)
        stream.inputFinished()
        let v = ex.compute(stream: stream)
        return v.isEmpty ? nil : v
    }

    // MARK: - 余弦相似度与匹配

    /// 两个等长向量的余弦相似度（[-1, 1]，越接近 1 越像同一个人）。
    nonisolated static func cosine(_ a: [Float], _ b: [Float]) -> Float {
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

    /// 两个声纹向量的余弦距离（方便按阈值判断，越小越像）。
    nonisolated static func distance(_ a: [Float], _ b: [Float]) -> Float { 1 - cosine(a, b) }

    nonisolated static func rms(_ s: [Float]) -> Float {
        guard !s.isEmpty else { return 0 }
        var e: Float = 0
        for v in s { e += v * v }
        return (e / Float(s.count)).squareRoot()
    }
}

enum SpeakerEngineError: LocalizedError {
    case badAudio

    var errorDescription: String? {
        switch self {
        case .badAudio: String(localized: "这段音频读不出来或格式不支持")
        }
    }
}
