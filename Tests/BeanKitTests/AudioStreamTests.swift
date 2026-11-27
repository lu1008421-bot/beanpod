import AVFoundation
import Foundation
import Testing
@testable import BeanKit

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("beanpod-audiostream-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func writeSyntheticFloatWAV(
    to url: URL,
    sampleRate: Double,
    channels: Int,
    frameCount: Int,
    generator: (Int, Int) -> Float
) throws {
    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: false),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
          let data = buffer.floatChannelData else {
        throw AudioStreamError.writeFailed
    }
    buffer.frameLength = AVAudioFrameCount(frameCount)
    for c in 0..<channels {
        for i in 0..<frameCount {
            data[c][i] = generator(c, i)
        }
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buffer)
}

@Test func transcodesStereo48kHzMultiChunkToMono16kWAV() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let src = dir.appendingPathComponent("stereo48k.wav")
    let dst = dir.appendingPathComponent("mono16k.wav")
    let sr = 48_000.0
    let frames = 264_000 // 5.5 seconds -> spans multiple 32k/65k chunks
    try writeSyntheticFloatWAV(to: src, sampleRate: sr, channels: 2, frameCount: frames) { _, i in
        if i < frames / 2 {
            return 0.5 * sin(Float(2.0 * Double.pi * 440.0 * Double(i) / sr))
        }
        return 0
    }

    let result = try AudioStream.transcodeToMono16kWAV(from: src, to: dst, minSamples: 1601)
    #expect(abs(result.duration - 5.5) < 0.02)
    #expect(result.byteSize == UInt64(44 + result.sampleCount * 2))

    let outFile = try AVAudioFile(forReading: dst)
    #expect(outFile.fileFormat.sampleRate == 16_000)
    #expect(outFile.fileFormat.channelCount == 1)
    #expect(Int(outFile.length) == result.sampleCount)

    let decoded = try AudioStream.loadMono16k(dst)
    #expect(decoded.count == result.sampleCount)

    let firstHalf = decoded.prefix(decoded.count / 3)
    let secondHalf = decoded.suffix(decoded.count / 3)
    let firstRMS = sqrt(firstHalf.reduce(Float(0)) { $0 + $1 * $1 } / Float(firstHalf.count))
    let secondRMS = sqrt(secondHalf.reduce(Float(0)) { $0 + $1 * $1 } / Float(secondHalf.count))
    #expect(firstRMS > 0.2)
    #expect(secondRMS < 0.01)
}

@Test func mono16kStreamReaderStreamsInSmallChunksWithoutLoss() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let src = dir.appendingPathComponent("multi.wav")
    let sr = 44_100.0
    let frames = 132_300 // 3.0 seconds
    try writeSyntheticFloatWAV(to: src, sampleRate: sr, channels: 1, frameCount: frames) { _, i in
        0.4 * sin(Float(2.0 * Double.pi * 330.0 * Double(i) / sr))
    }

    let reader = try Mono16kStreamReader(url: src)
    var streamed: [Float] = []
    var chunkCount = 0
    while !reader.isAtEnd {
        let part = try reader.readNext(maxFrames: 8_192)
        if part.isEmpty { break }
        chunkCount += 1
        streamed.append(contentsOf: part)
    }
    #expect(chunkCount >= 5)
    #expect(reader.framesDelivered == streamed.count)

    let full = try AudioStream.loadMono16k(src)
    #expect(streamed.count == full.count)
    var maxDiff: Float = 0
    for i in streamed.indices {
        maxDiff = max(maxDiff, abs(streamed[i] - full[i]))
    }
    #expect(maxDiff < 1e-5)
}

@Test func mixesTwoTracksWithPositiveAndNegativeOffsetStreaming() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let micURL = dir.appendingPathComponent("mic.wav")
    let sysURL = dir.appendingPathComponent("sys.wav")
    let sr = 16_000.0
    let frames = 96_000 // 6 seconds -> > 1 chunk
    // Mic is silent on [0, 3s), 0.7 DC/tone on [3s, 6s)
    try writeSyntheticFloatWAV(to: micURL, sampleRate: sr, channels: 1, frameCount: frames) { _, i in
        i >= 48_000 ? 0.6 : 0.0
    }
    // System is 0.7 throughout [0, 6s) -> mixed with mic should clamp cleanly to 1.0
    try writeSyntheticFloatWAV(to: sysURL, sampleRate: sr, channels: 1, frameCount: frames) { _, _ in
        0.7
    }

    let posOut = dir.appendingPathComponent("pos.wav")
    _ = try AudioStream.mixToMono16kWAV(micURL: micURL, systemURL: sysURL, systemOffsetSamples: 16_000, to: posOut, minSamples: 1601)
    let posSamples = try AudioStream.loadMono16k(posOut)
    #expect(posSamples.count == frames + 16_000)
    #expect(abs(posSamples[1_000]) < 0.01) // system padded 1s silence at start
    #expect(abs(posSamples[20_000] - 0.7) < 0.02) // system active after 1s
    #expect(abs(posSamples[60_000] - 1.0) < 0.02) // 0.6 + 0.7 clamped to 1.0

    let negOut = dir.appendingPathComponent("neg.wav")
    _ = try AudioStream.mixToMono16kWAV(micURL: micURL, systemURL: sysURL, systemOffsetSamples: -32_000, to: negOut, minSamples: 1601)
    let negSamples = try AudioStream.loadMono16k(negOut)
    #expect(negSamples.count == frames) // mic is 6s, system trimmed 2s -> remaining 4s
    #expect(abs(negSamples[70_000] - 0.6) < 0.02) // only mic left after system ends at 4s

    let singleOut = dir.appendingPathComponent("single.wav")
    let missingURL = dir.appendingPathComponent("does-not-exist.wav")
    let singleRes = try AudioStream.mixToMono16kWAV(micURL: micURL, systemURL: missingURL, systemOffsetSamples: 0, to: singleOut, minSamples: 1601)
    #expect(singleRes.sampleCount == frames)
}

@Test func streamingWaveformProducesBarsAndCachesByFileMetadata() throws {
    AudioStream.clearWaveformCache()
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let wavURL = dir.appendingPathComponent("wave.wav")
    let frames = 160_000
    try writeSyntheticFloatWAV(to: wavURL, sampleRate: 16_000, channels: 1, frameCount: frames) { _, i in
        i < frames / 2 ? 0.02 : 0.8
    }

    let bars1 = AudioStream.waveform(of: wavURL, bars: 160)
    #expect(bars1.count == 160)
    let quietAvg = bars1.prefix(60).reduce(0, +) / 60
    let loudAvg = bars1.suffix(60).reduce(0, +) / 60
    #expect(loudAvg > quietAvg * 3)

    let barsCached = AudioStream.waveform(of: wavURL, bars: 160)
    #expect(barsCached == bars1)

    // Overwrite file with different size & mtime -> cache must invalidate
    try writeSyntheticFloatWAV(to: wavURL, sampleRate: 16_000, channels: 1, frameCount: frames + 16_000) { _, _ in
        0.5
    }
    let barsUpdated = AudioStream.waveform(of: wavURL, bars: 160)
    #expect(barsUpdated.count == 160)
    #expect(barsUpdated != bars1)
}

@Test func nextBatchCutPrefersQuietRegionWithinSearchWindow() {
    let rate = 16_000
    let maxBatch = 300 * rate
    var samples = [Float](repeating: 0.4, count: maxBatch + 10_000)
    // Quiet gap at [280s, 281s) inside [272s, 300s]
    let gapStart = 280 * rate
    let gapEnd = 281 * rate
    for i in gapStart..<gapEnd { samples[i] = 0.0 }

    let cut = AudioStream.nextBatchCut(in: samples, maxBatchSamples: maxBatch, searchWindowSeconds: 28, rate: rate)
    #expect(cut >= gapStart && cut <= gapEnd)
}

@Test func preferredAudioURLFallsBackFromOggToWav() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let ogg = dir.appendingPathComponent("1.ogg")
    let wav = dir.appendingPathComponent("1.wav")
    #expect(AudioStream.preferredAudioURL(ogg: ogg, wav: wav) == nil)

    try Data([1, 2, 3]).write(to: wav)
    #expect(AudioStream.preferredAudioURL(ogg: ogg, wav: wav) == wav)

    try Data([4, 5, 6]).write(to: ogg)
    #expect(AudioStream.preferredAudioURL(ogg: ogg, wav: wav) == ogg)
}

@Test func asrRoutePolicyBlocksSilentDegradationAndExplainsFallback() {
    // Cloud requested/forced without config -> blocked
    let cloudMissing = ASRRoutePolicy.resolve(
        preferred: .cloud, forceCloud: false, hasCloudConfig: false,
        hasQwenServer: true, hasQwenModel: true, retranscribing: false
    )
    #expect(cloudMissing == .blocked(
        title: "云端转写还没配置好",
        detail: "请先在设置里填好云端转写的接口地址和模型，再重新转写。原有文字稿保持不变。"
    ))

    let forceCloudMissing = ASRRoutePolicy.resolve(
        preferred: .qwen, forceCloud: true, hasCloudConfig: false,
        hasQwenServer: true, hasQwenModel: true, retranscribing: true
    )
    if case .blocked = forceCloudMissing {} else { Issue.record("Expected blocked when forceCloud lacks config") }

    // Cloud configured -> cloud
    #expect(ASRRoutePolicy.resolve(
        preferred: .cloud, forceCloud: false, hasCloudConfig: true,
        hasQwenServer: false, hasQwenModel: false, retranscribing: false
    ) == .cloud)

    // Qwen ready -> qwen
    #expect(ASRRoutePolicy.resolve(
        preferred: .qwen, forceCloud: false, hasCloudConfig: false,
        hasQwenServer: true, hasQwenModel: true, retranscribing: false
    ) == .qwen)

    // Qwen missing model on new recording -> explicit appleDegraded
    let missingModel = ASRRoutePolicy.resolve(
        preferred: .qwen, forceCloud: false, hasCloudConfig: false,
        hasQwenServer: true, hasQwenModel: false, retranscribing: false
    )
    #expect(missingModel == .appleDegraded(reason: "本机 Qwen3‑ASR 模型还没下载"))

    // Qwen missing server on new recording -> explicit appleDegraded
    let missingServer = ASRRoutePolicy.resolve(
        preferred: .qwen, forceCloud: false, hasCloudConfig: false,
        hasQwenServer: false, hasQwenModel: true, retranscribing: false
    )
    #expect(missingServer == .appleDegraded(reason: "没找到 llama-server（本机转写服务）"))

    // Qwen missing on retranscribe -> blocked so timestamped transcript isn't clobbered
    let retranscribeBlocked = ASRRoutePolicy.resolve(
        preferred: .qwen, forceCloud: false, hasCloudConfig: false,
        hasQwenServer: false, hasQwenModel: false, retranscribing: true
    )
    if case .blocked(let title, let detail) = retranscribeBlocked {
        #expect(title.contains("已取消重转"))
        #expect(detail.contains("llama-server") && detail.contains("Qwen3‑ASR"))
    } else {
        Issue.record("Expected blocked when retranscribing without Qwen")
    }

    // Explicit Apple -> apple
    #expect(ASRRoutePolicy.resolve(
        preferred: .apple, forceCloud: false, hasCloudConfig: false,
        hasQwenServer: false, hasQwenModel: false, retranscribing: false
    ) == .apple)
}
