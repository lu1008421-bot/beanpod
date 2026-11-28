@preconcurrency import AVFoundation
import BeanKit
import Foundation

/// 用 llama.cpp 在本机跑 Qwen3‑ASR。录音不出这台电脑。
/// 做法：起一个只监听本机的 llama-server，把录音切成不超过 28 秒的小段逐段送进去。
actor QwenASR {
    static let shared = QwenASR()

    static let modelName = "Qwen3-ASR-0.6B-Q8_0.gguf"
    static let projectorName = "mmproj-Qwen3-ASR-0.6B-Q8_0.gguf"
    static let displayName = "Qwen3‑ASR 0.6B"

    nonisolated static var modelFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeanPod/Models/qwen3-asr-0.6b", isDirectory: true)
    }

    nonisolated static func locateServer(custom: String) -> URL? {
        let candidates = [custom, "/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server",
                          "/Applications/Capwise.app/Contents/Helpers/llama-server/llama-server"]
        return candidates.filter { !$0.isEmpty }.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    nonisolated static func locateModel() -> (model: URL, projector: URL)? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folders = [modelFolder, home.appendingPathComponent("Library/Application Support/so.cap.desktop/transcription_models/qwen3-asr-0.6b")]
        for f in folders {
            let m = f.appendingPathComponent(modelName), p = f.appendingPathComponent(projectorName)
            if FileManager.default.fileExists(atPath: m.path), FileManager.default.fileExists(atPath: p.path) { return (m, p) }
        }
        return nil
    }

    private var process: Process?
    private var port = 0

    // MARK: 服务

    private func ensureRunning(serverPath: String) async throws -> Int {
        if let process, process.isRunning { return port }
        guard let server = Self.locateServer(custom: serverPath) else { throw ASRError.noServer }
        guard let files = Self.locateModel() else { throw ASRError.noModel }

        port = Int.random(in: 39000...39900)
        let p = Process()
        // 用一层 sh 盯着豆仓的进程：豆仓退出（哪怕是崩溃），转写服务也跟着退，不留孤儿进程
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", #"parent=$1; shift; "$@" & child=$!; while kill -0 "$parent" 2>/dev/null && kill -0 "$child" 2>/dev/null; do sleep 1; done; kill "$child" 2>/dev/null"#,
                       "beanpod-asr", String(ProcessInfo.processInfo.processIdentifier), server.path,
                       "-m", files.model.path, "--mmproj", files.projector.path,
                       "--host", "127.0.0.1", "--port", String(port), "-c", "4096", "-np", "1", "--log-disable"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw ASRError.startFailed(error.localizedDescription) }
        process = p

        let health = URL(string: "http://127.0.0.1:\(port)/health")!
        for _ in 0..<120 {
            try await Task.sleep(for: .milliseconds(500))
            if !p.isRunning { process = nil; throw ASRError.startFailed(String(localized: "进程退出了，可能是模型文件损坏或内存不够")) }
            if let (_, r) = try? await URLSession.shared.data(from: health), (r as? HTTPURLResponse)?.statusCode == 200 { return port }
        }
        stop()
        throw ASRError.startFailed(String(localized: "等了一分钟还没就绪"))
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    // MARK: 转写

    /// 提前把模型装进内存。语音输入在按下按键时调用，松手时就不用等加载了。
    func warmUp(serverPath: String) async { _ = try? await ensureRunning(serverPath: serverPath) }

    /// 转一小段已经在内存里的声音（16 kHz 单声道），用于语音输入。
    func transcribe(samples: [Float], serverPath: String) async throws -> String {
        let port = try await ensureRunning(serverPath: serverPath)
        var parts: [String] = []
        for c in Self.chunk(samples) {
            let piece = Array(samples[c])
            guard Self.rms(piece) > 0.0015 else { continue }
            let text = try await recognize(Self.wav(piece), port: port)
            if !text.isEmpty { parts.append(text) }
        }
        return parts.joined()
    }

    func transcribe(_ url: URL, serverPath: String, progress: @Sendable @escaping (Double) -> Void) async throws -> [Segment] {
        let port = try await ensureRunning(serverPath: serverPath)
        let reader: Mono16kStreamReader
        do { reader = try Mono16kStreamReader(url: url) } catch { throw ASRError.badAudio }
        let rate = AudioStream.sampleRate
        let longest = 15 * rate
        let totalEstimated = max(1, reader.estimatedTotalFrames)
        var buffer: [Float] = []
        var processedFrames = 0
        var out: [Segment] = []

        while true {
            try Task.checkCancellation()
            while buffer.count <= longest && !reader.isAtEnd {
                let next: [Float]
                do { next = try reader.readNext() } catch { throw ASRError.badAudio }
                if next.isEmpty { break }
                buffer.append(contentsOf: next)
            }
            if buffer.count > longest {
                let window = Array(buffer[..<longest])
                let frames = BeanStore.lastPause(in: window, forced: true) ?? (longest / 320)
                let cut = max(rate * 3 / 2, min(frames * 320, longest))
                let piece = Array(buffer[..<cut])
                buffer.removeFirst(cut)
                progress(min(0.99, Double(processedFrames) / Double(totalEstimated)))
                if BeanStore.hasSpeech(piece) {
                    let text = try await recognize(Self.wav(piece), port: port)
                    if !text.isEmpty, !BeanStore.isFiller(text) {
                        out.append(Segment(start: Double(processedFrames) / Double(rate), text: text))
                    }
                }
                processedFrames += cut
            } else if reader.isAtEnd {
                if buffer.count > rate / 4 {
                    progress(min(0.99, Double(processedFrames) / Double(totalEstimated)))
                    if BeanStore.hasSpeech(buffer) {
                        let text = try await recognize(Self.wav(buffer), port: port)
                        if !text.isEmpty, !BeanStore.isFiller(text) {
                            out.append(Segment(start: Double(processedFrames) / Double(rate), text: text))
                        }
                    }
                }
                break
            }
        }
        progress(1)
        return out
    }

    private func recognize(_ wav: Data, port: Int) async throws -> String {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!, timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "temperature": 0, "max_tokens": 512,
            "messages": [["role": "user", "content": [["type": "input_audio",
                                                        "input_audio": ["data": wav.base64EncodedString(), "format": "wav"]]]]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw ASRError.http(code, String(decoding: data, as: UTF8.self)) }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { return "" }
        return Self.clean(content)
    }

    /// 模型的原始输出形如「language Chinese<asr_text>正文</asr_text>」，只留正文。
    nonisolated static func clean(_ raw: String) -> String {
        var s = raw
        if let r = s.range(of: "<asr_text>") { s = String(s[r.upperBound...]) }
        if let r = s.range(of: "</asr_text>") { s = String(s[..<r.lowerBound]) }
        return s.replacingOccurrences(of: "<|im_end|>", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
