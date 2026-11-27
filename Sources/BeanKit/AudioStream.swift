@preconcurrency import AVFoundation
import Foundation

public enum AudioStreamError: Error, Equatable, Sendable {
    case unreadable
    case tooShort
    case writeFailed
    case wavTooLarge
}

public struct WAVWriteResult: Equatable, Sendable {
    public let sampleCount: Int
    public let byteSize: UInt64
    public let duration: TimeInterval

    public init(sampleCount: Int, byteSize: UInt64, duration: TimeInterval) {
        self.sampleCount = sampleCount
        self.byteSize = byteSize
        self.duration = duration
    }
}

/// 分块流式读取任意可解码音频，并统一重采样为 16 kHz 单声道 Float32（保持连续的转换器状态）。
public final class Mono16kStreamReader {
    public let estimatedTotalFrames: Int
    public private(set) var framesDelivered: Int = 0
    public private(set) var isAtEnd: Bool = false

    private let file: AVAudioFile
    private let targetFormat: AVAudioFormat
    private let fastPath: Bool
    private let converter: AVAudioConverter?
    private let inputBuffer: AVAudioPCMBuffer?
    private var inputEOF = false

    public init(url: URL) throws {
        guard let audioFile = try? AVAudioFile(forReading: url),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(AudioStream.sampleRate), channels: 1, interleaved: false) else {
            throw AudioStreamError.unreadable
        }
        self.file = audioFile
        self.targetFormat = target
        let srcFmt = audioFile.processingFormat
        let ratio = Double(AudioStream.sampleRate) / max(1.0, srcFmt.sampleRate)
        self.estimatedTotalFrames = max(0, Int((Double(audioFile.length) * ratio).rounded()))
        let isNativeMono16k = srcFmt.sampleRate == Double(AudioStream.sampleRate)
            && srcFmt.channelCount == 1
            && srcFmt.commonFormat == .pcmFormatFloat32
            && !srcFmt.isInterleaved
        if isNativeMono16k {
            self.fastPath = true
            self.converter = nil
            self.inputBuffer = nil
        } else {
            guard let conv = AVAudioConverter(from: srcFmt, to: target),
                  let inBuf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: 32_768) else {
                throw AudioStreamError.unreadable
            }
            self.fastPath = false
            self.converter = conv
            self.inputBuffer = inBuf
        }
    }

    public func readNext(maxFrames: Int = AudioStream.defaultChunkFrames) throws -> [Float] {
        guard !isAtEnd else { return [] }
        let cap = AVAudioFrameCount(max(1024, maxFrames))
        if fastPath {
            let remaining = file.length - file.framePosition
            if remaining <= 0 {
                isAtEnd = true
                return []
            }
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: cap) else {
                throw AudioStreamError.unreadable
            }
            let toRead = AVAudioFrameCount(min(Int64(cap), remaining))
            do {
                try file.read(into: outBuf, frameCount: toRead)
            } catch {
                if framesDelivered > 0 {
                    isAtEnd = true
                    return []
                }
                throw AudioStreamError.unreadable
            }
            let count = Int(outBuf.frameLength)
            guard count > 0, let channel = outBuf.floatChannelData else {
                isAtEnd = true
                return []
            }
            framesDelivered += count
            if file.framePosition >= file.length {
                isAtEnd = true
            }
            return Array(UnsafeBufferPointer(start: channel[0], count: count))
        }

        guard let converter, let inputBuffer else {
            throw AudioStreamError.unreadable
        }
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: cap) else {
            throw AudioStreamError.unreadable
        }

        while !isAtEnd {
            outputBuffer.frameLength = 0
            var convError: NSError?
            var readFailed = false
            let status = converter.convert(to: outputBuffer, error: &convError) { requestedPackets, outStatus in
                if self.inputEOF {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                let toRead = AVAudioFrameCount(min(UInt32(inputBuffer.frameCapacity), max(1, requestedPackets)))
                inputBuffer.frameLength = 0
                do {
                    try self.file.read(into: inputBuffer, frameCount: toRead)
                } catch {
                    self.inputEOF = true
                    if self.framesDelivered == 0 { readFailed = true }
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if inputBuffer.frameLength == 0 {
                    self.inputEOF = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inputBuffer
            }

            if (status == .error || readFailed) && outputBuffer.frameLength == 0 && framesDelivered == 0 {
                throw AudioStreamError.unreadable
            }

            let produced = Int(outputBuffer.frameLength)
            if status == .endOfStream || (inputEOF && produced == 0) {
                isAtEnd = true
            }
            if produced > 0, let channel = outputBuffer.floatChannelData {
                framesDelivered += produced
                return Array(UnsafeBufferPointer(start: channel[0], count: produced))
            }
            if status == .error || status == .inputRanDry {
                isAtEnd = true
            }
        }
        return []
    }
}

/// 原子流式写入 16 kHz 单声道 16-bit PCM WAV，避免把整段音频缓存在内存里。
public final class WAVStreamWriter {
    private let destination: URL
    private let tempURL: URL
    private let sampleRate: Int
    private var handle: FileHandle?
    private var totalSamples: Int64 = 0
    private var finished = false

    public init(destination: URL, sampleRate: Int = AudioStream.sampleRate) throws {
        self.destination = destination
        self.sampleRate = sampleRate
        let dir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.tempURL = dir.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tempURL.path, contents: nil),
              let fh = try? FileHandle(forWritingTo: tempURL) else {
            throw AudioStreamError.writeFailed
        }
        self.handle = fh
        do {
            try fh.write(contentsOf: Data(count: 44))
        } catch {
            abort()
            throw AudioStreamError.writeFailed
        }
    }

    deinit {
        if !finished {
            abort()
        }
    }

    public func append(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        guard !finished, let handle else { throw AudioStreamError.writeFailed }
        let addedBytes = Int64(samples.count) * 2
        let currentBytes = totalSamples * 2
        guard currentBytes + addedBytes <= Int64(UInt32.max) - 36 else {
            abort()
            throw AudioStreamError.wavTooLarge
        }
        var pcm = Data(count: samples.count * 2)
        pcm.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            for (index, sample) in samples.enumerated() {
                let clamped = max(-1.0 as Float, min(1.0 as Float, sample))
                var v = Int16(clamped * 32767.0).littleEndian
                withUnsafeBytes(of: &v) { src in
                    base.advanced(by: index * 2).copyMemory(from: src.baseAddress!, byteCount: 2)
                }
            }
        }
        do {
            try handle.write(contentsOf: pcm)
            totalSamples += Int64(samples.count)
        } catch {
            abort()
            throw AudioStreamError.writeFailed
        }
    }

    public func finish(minSamples: Int = 0) throws -> WAVWriteResult {
        guard !finished, let handle else { throw AudioStreamError.writeFailed }
        if totalSamples < Int64(minSamples) {
            abort()
            throw AudioStreamError.tooShort
        }
        let dataBytes = UInt32(totalSamples * 2)
        let header = AudioStream.wavHeader(dataBytes: dataBytes, rate: sampleRate)
        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: header)
            try handle.close()
            self.handle = nil
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: tempURL)
            } else {
                try fm.moveItem(at: tempURL, to: destination)
            }
            finished = true
            return WAVWriteResult(
                sampleCount: Int(totalSamples),
                byteSize: UInt64(44) + UInt64(dataBytes),
                duration: Double(totalSamples) / Double(sampleRate)
            )
        } catch {
            abort()
            throw AudioStreamError.writeFailed
        }
    }

    public func abort() {
        if let handle {
            try? handle.close()
            self.handle = nil
        }
        try? FileManager.default.removeItem(at: tempURL)
    }
}

private final class BoundedWaveformCache: @unchecked Sendable {
    private let lock = NSLock()
    private let limit = 200
    private var values: [String: [Float]] = [:]
    private var order: [String] = []

    func get(_ key: String) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func set(_ key: String, value: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        if values[key] == nil {
            order.append(key)
        }
        values[key] = value
        while order.count > limit {
            let evicted = order.removeFirst()
            values.removeValue(forKey: evicted)
        }
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        values.removeAll()
        order.removeAll()
    }
}

public enum AudioStream: Sendable {
    public static let sampleRate: Int = 16_000
    public static let defaultChunkFrames: Int = 65_536

    private static let waveformCache = BoundedWaveformCache()

    public static func wavHeader(dataBytes: UInt32, rate: Int = sampleRate) -> Data {
        var d = Data(capacity: 44)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8))
        u32(36 &+ dataBytes)
        d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate * 2))
        u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8))
        u32(dataBytes)
        return d
    }

    public static func encodeWAV(_ samples: [Float], rate: Int = sampleRate) -> Data {
        let dataBytes = UInt32(samples.count * 2)
        var d = Data(count: 44 + samples.count * 2)
        let header = wavHeader(dataBytes: dataBytes, rate: rate)
        d.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            header.withUnsafeBytes { hRaw in
                base.copyMemory(from: hRaw.baseAddress!, byteCount: 44)
            }
            for (index, sample) in samples.enumerated() {
                let clamped = max(-1.0 as Float, min(1.0 as Float, sample))
                var v = Int16(clamped * 32767.0).littleEndian
                withUnsafeBytes(of: &v) { src in
                    base.advanced(by: 44 + index * 2).copyMemory(from: src.baseAddress!, byteCount: 2)
                }
            }
        }
        return d
    }

    public static func loadMono16k(_ url: URL) throws -> [Float] {
        let reader = try Mono16kStreamReader(url: url)
        var out: [Float] = []
        if reader.estimatedTotalFrames > 0, reader.estimatedTotalFrames < 20_000_000 {
            out.reserveCapacity(reader.estimatedTotalFrames)
        }
        while !reader.isAtEnd {
            let chunk = try reader.readNext()
            if chunk.isEmpty { break }
            out.append(contentsOf: chunk)
        }
        return out
    }

    public static func transcodeToMono16kWAV(from sourceURL: URL, to destURL: URL, minSamples: Int = 1601) throws -> WAVWriteResult {
        if let reader = try? Mono16kStreamReader(url: sourceURL) {
            let writer = try WAVStreamWriter(destination: destURL)
            do {
                while !reader.isAtEnd {
                    let chunk = try reader.readNext()
                    if chunk.isEmpty { break }
                    try writer.append(chunk)
                }
                return try writer.finish(minSamples: minSamples)
            } catch let err as AudioStreamError {
                writer.abort()
                if err != .tooShort && err != .writeFailed && err != .wavTooLarge {
                    // fall through to ffmpeg fallback on macOS if available
                } else {
                    throw err
                }
            } catch {
                writer.abort()
            }
        }

        #if os(macOS)
        guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw AudioStreamError.unreadable
        }
        let dir = destURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(destURL.lastPathComponent).\(UUID().uuidString).ffmpeg.wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-v", "error", "-y", "-i", sourceURL.path, "-vn", "-ar", "\(sampleRate)", "-ac", "1", "-c:a", "pcm_s16le", "-f", "wav", tmp.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { throw AudioStreamError.unreadable }
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let audioFile = try? AVAudioFile(forReading: tmp),
              audioFile.length > 0 else {
            throw AudioStreamError.unreadable
        }
        let samples = Int(audioFile.length)
        guard samples >= minSamples else { throw AudioStreamError.tooShort }
        let fm = FileManager.default
        let fileSize = (try? fm.attributesOfItem(atPath: tmp.path)[.size] as? NSNumber)?.uint64Value ?? UInt64(44 + samples * 2)
        if fm.fileExists(atPath: destURL.path) {
            _ = try fm.replaceItemAt(destURL, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: destURL)
        }
        return WAVWriteResult(sampleCount: samples, byteSize: fileSize, duration: Double(samples) / Double(sampleRate))
        #else
        throw AudioStreamError.unreadable
        #endif
    }

    public static func mixToMono16kWAV(
        micURL: URL?,
        systemURL: URL?,
        systemOffsetSamples: Int,
        to destURL: URL,
        minSamples: Int = 1601
    ) throws -> WAVWriteResult {
        let micReader = micURL.flatMap { try? Mono16kStreamReader(url: $0) }
        let sysReader = systemURL.flatMap { try? Mono16kStreamReader(url: $0) }

        if micReader == nil && sysReader == nil {
            if let micURL, let result = try? transcodeToMono16kWAV(from: micURL, to: destURL, minSamples: minSamples) {
                return result
            }
            if let systemURL, let result = try? transcodeToMono16kWAV(from: systemURL, to: destURL, minSamples: minSamples) {
                return result
            }
            throw AudioStreamError.unreadable
        }

        let writer = try WAVStreamWriter(destination: destURL)
        do {
            if let reader = micReader, sysReader == nil {
                while !reader.isAtEnd {
                    let chunk = try reader.readNext()
                    if chunk.isEmpty { break }
                    try writer.append(chunk)
                }
                return try writer.finish(minSamples: minSamples)
            }
            if let reader = sysReader, micReader == nil {
                while !reader.isAtEnd {
                    let chunk = try reader.readNext()
                    if chunk.isEmpty { break }
                    try writer.append(chunk)
                }
                return try writer.finish(minSamples: minSamples)
            }

            guard let mic = micReader, let sys = sysReader else {
                writer.abort()
                throw AudioStreamError.unreadable
            }

            let chunkSize = defaultChunkFrames
            var micBuf: [Float] = []
            var sysBuf: [Float] = []
            var micDone = false
            var sysDone = false
            var sysPadRemaining = max(0, systemOffsetSamples)
            var sysDropRemaining = max(0, -systemOffsetSamples)

            while sysDropRemaining > 0 && !sysDone {
                let chunk = try sys.readNext(maxFrames: min(chunkSize, sysDropRemaining))
                if chunk.isEmpty {
                    sysDone = true
                    break
                }
                if chunk.count <= sysDropRemaining {
                    sysDropRemaining -= chunk.count
                } else {
                    sysBuf.append(contentsOf: chunk.dropFirst(sysDropRemaining))
                    sysDropRemaining = 0
                }
            }

            while true {
                while micBuf.count < chunkSize && !micDone {
                    let chunk = try mic.readNext()
                    if chunk.isEmpty { micDone = true; break }
                    micBuf.append(contentsOf: chunk)
                }
                while sysBuf.count < chunkSize && !sysDone {
                    if sysPadRemaining > 0 {
                        let pad = min(chunkSize - sysBuf.count, sysPadRemaining)
                        sysBuf.append(contentsOf: repeatElement(Float(0), count: pad))
                        sysPadRemaining -= pad
                    } else {
                        let chunk = try sys.readNext()
                        if chunk.isEmpty { sysDone = true; break }
                        sysBuf.append(contentsOf: chunk)
                    }
                }
                if micBuf.isEmpty && sysBuf.isEmpty { break }
                let count = min(chunkSize, max(micBuf.count, sysBuf.count))
                var mixed = [Float](repeating: 0, count: count)
                let micTake = min(count, micBuf.count)
                let sysTake = min(count, sysBuf.count)
                for i in 0..<micTake { mixed[i] += micBuf[i] }
                for i in 0..<sysTake { mixed[i] += sysBuf[i] }
                for i in 0..<count { mixed[i] = max(-1.0 as Float, min(1.0 as Float, mixed[i])) }
                try writer.append(mixed)
                if micTake > 0 { micBuf.removeFirst(micTake) }
                if sysTake > 0 { sysBuf.removeFirst(sysTake) }
            }
            return try writer.finish(minSamples: minSamples)
        } catch {
            writer.abort()
            throw error
        }
    }

    public static func nextBatchCut(in samples: [Float], maxBatchSamples: Int, searchWindowSeconds: Int = 28, rate: Int = sampleRate) -> Int {
        guard samples.count > maxBatchSamples else { return samples.count }
        let window = max(1, rate / 5)
        let minCut = max(rate, maxBatchSamples - searchWindowSeconds * rate)
        guard minCut + window <= maxBatchSamples else { return maxBatchSamples }
        var best = maxBatchSamples
        var bestEnergy = Float.greatestFiniteMagnitude
        var i = minCut
        while i + window <= maxBatchSamples {
            var e: Float = 0
            for j in stride(from: i, to: i + window, by: 4) {
                e += samples[j] * samples[j]
            }
            if e < bestEnergy {
                bestEnergy = e
                best = i + window / 2
            }
            i += max(1, window / 2)
        }
        return best
    }

    public static func waveform(of url: URL, bars: Int = 160, useCache: Bool = true) -> [Float] {
        guard bars > 0 else { return [] }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let cacheKey = "\(url.standardizedFileURL.path)|\(size)|\(mtime)|\(bars)"
        if useCache, let cached = waveformCache.get(cacheKey) {
            return cached
        }

        guard let file = try? AVAudioFile(forReading: url),
              file.length > Int64(bars) else { return [] }
        let format = file.processingFormat
        let totalFrames = file.length
        let channels = max(1, Int(format.channelCount))
        let strideStep = max(1, min(8, Int(totalFrames / Int64(bars * 8))))
        guard format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(defaultChunkFrames)) else {
            return []
        }

        var peaks = [Float](repeating: 0, count: bars)
        var processedFrames: Int64 = 0
        while processedFrames < totalFrames {
            buf.frameLength = 0
            do {
                try file.read(into: buf)
            } catch {
                break
            }
            let n = Int(buf.frameLength)
            guard n > 0, let channelData = buf.floatChannelData else { break }
            for i in stride(from: 0, to: n, by: strideStep) {
                let globalFrame = processedFrames + Int64(i)
                let bucket = min(bars - 1, Int((globalFrame * Int64(bars)) / totalFrames))
                let mag: Float
                if channels == 1 {
                    mag = abs(channelData[0][i])
                } else {
                    var sum: Float = 0
                    for c in 0..<channels { sum += channelData[c][i] }
                    mag = abs(sum / Float(channels))
                }
                if mag > peaks[bucket] { peaks[bucket] = mag }
            }
            processedFrames += Int64(n)
        }

        let result = peaks.map { min(1, $0.squareRoot() * 1.4) }
        if useCache {
            waveformCache.set(cacheKey, value: result)
        }
        return result
    }

    public static func clearWaveformCache() {
        waveformCache.clear()
    }

    public static func preferredAudioURL(ogg: URL, wav: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: ogg.path) { return ogg }
        if fm.fileExists(atPath: wav.path) { return wav }
        return nil
    }
}

public enum ASRPreferredEngine: String, Sendable, Equatable {
    case qwen, apple, cloud
}

public enum ASRRouteDecision: Sendable, Equatable {
    case cloud
    case qwen
    case apple
    case appleDegraded(reason: String)
    case blocked(title: String, detail: String)
}

public enum ASRRoutePolicy: Sendable {
    public static func resolve(
        preferred: ASRPreferredEngine,
        forceCloud: Bool,
        hasCloudConfig: Bool,
        hasQwenServer: Bool,
        hasQwenModel: Bool,
        retranscribing: Bool
    ) -> ASRRouteDecision {
        if forceCloud || preferred == .cloud {
            if hasCloudConfig { return .cloud }
            return .blocked(
                title: "云端转写还没配置好",
                detail: "请先在设置里填好云端转写的接口地址和模型，再重新转写。原有文字稿保持不变。"
            )
        }
        if preferred == .qwen {
            if hasQwenServer && hasQwenModel { return .qwen }
            let reason: String
            if !hasQwenServer && !hasQwenModel {
                reason = "没找到 llama-server，且本机 Qwen3‑ASR 模型还没下载"
            } else if !hasQwenServer {
                reason = "没找到 llama-server（本机转写服务）"
            } else {
                reason = "本机 Qwen3‑ASR 模型还没下载"
            }
            if retranscribing {
                return .blocked(
                    title: "本机 Qwen3‑ASR 未就绪，已取消重转",
                    detail: "\(reason)。为避免覆盖现有带时间戳的文字稿，本次未降级为系统语音识别。请先在设置里补齐模型或切换转写引擎。"
                )
            }
            return .appleDegraded(reason: reason)
        }
        return .apple
    }
}
