@preconcurrency import AVFoundation
import BeanKit
import Foundation

nonisolated enum ASRError: LocalizedError {
    case noServer, noModel, startFailed(String), http(Int, String), badAudio

    var errorDescription: String? {
        switch self {
        case .noServer: String(localized: "没找到 llama-server。请安装 llama.cpp（brew install llama.cpp），或在设置里指定它的位置。")
        case .noModel: String(localized: "没找到 Qwen3‑ASR 模型文件。请在设置里下载。")
        case .startFailed(let why): String(localized: "本机转写服务没启动起来：\(why)")
        case .http(let code, let body): String(localized: "转写服务返回错误 \(code)：\(String(body.prefix(160)))")
        case .badAudio: String(localized: "这条录音读不出来")
        }
    }
}

/// 读音频、切段、算音量、写 WAV。Mac 上的本机转写和手机上的云端转写都用这一套。
extension QwenASR {
    // MARK: 音频处理

    nonisolated static func loadMono16k(_ url: URL) throws -> [Float] {
        do { return try AudioStream.loadMono16k(url) }
        catch { throw ASRError.badAudio }
    }

    /// 切成不超过 28 秒的段，切点选在 20–28 秒之间最安静的地方，尽量不把一句话拦腰切断。
    nonisolated static func chunk(_ samples: [Float], rate: Int = 16000) -> [Range<Int>] {
        let maxLen = 28 * rate, minLen = 20 * rate, window = rate / 5
        var ranges: [Range<Int>] = []
        var start = 0
        while samples.count - start > maxLen {
            var best = start + maxLen, bestEnergy = Float.greatestFiniteMagnitude
            var i = start + minLen
            while i + window <= start + maxLen {
                var e: Float = 0
                for j in stride(from: i, to: i + window, by: 4) { e += samples[j] * samples[j] }
                if e < bestEnergy { bestEnergy = e; best = i + window / 2 }
                i += window / 2
            }
            ranges.append(start..<best)
            start = best
        }
        if samples.count - start > rate / 4 { ranges.append(start..<samples.count) }
        return ranges
    }

    /// 沿着停顿把整段声音切成句子：每段最长 15 秒，切点落在停顿上。
    nonisolated static func sentenceChunks(_ samples: [Float], rate: Int = 16000) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        let longest = 15 * rate
        while samples.count - start > longest {
            let window = Array(samples[start..<(start + longest)])
            let frames = BeanStore.lastPause(in: window, forced: true) ?? (longest / 320)
            let cut = max(rate * 3 / 2, min(frames * 320, longest))
            ranges.append(start..<(start + cut))
            start += cut
        }
        if samples.count - start > rate / 4 { ranges.append(start..<samples.count) }
        return ranges
    }

    nonisolated static func rms(_ s: [Float]) -> Float {
        guard !s.isEmpty else { return 0 }
        var e: Float = 0
        for v in s { e += v * v }
        return (e / Float(s.count)).squareRoot()
    }

    nonisolated static func wav(_ samples: [Float], rate: Int = 16000) -> Data {
        AudioStream.encodeWAV(samples, rate: rate)
    }
}
