import CryptoKit
import Foundation
import Observation

/// 模型文件：固定仓库、固定版本，下载完按 SHA‑256 校验。
nonisolated struct ModelFile: Sendable {
    var name: String
    var repo: String
    var revision: String
    var size: Int64
    var sha256: String
    /// 兜底直链。HuggingFace/镜像/魔搭都下不来（比如魔搭上没有 `csukuangfj/*`）时按顺序回退，
    /// 仍沿用同一条 `DownloadJob` 的断点续传、超时切源与 SHA‑256 校验。
    var fallbackURLs: [URL] = []
}

/// 下载源。HuggingFace 在国内常常很慢或连不上，所以带两个国内镜像；三处的文件一样，靠 SHA‑256 保证。
nonisolated enum ModelSource: String, CaseIterable, Sendable {
    case huggingface, hfMirror, modelscope

    var name: String {
        switch self {
        case .huggingface: "HuggingFace"
        case .hfMirror: String(localized: "国内镜像")
        case .modelscope: String(localized: "魔搭社区")
        }
    }

    func url(_ f: ModelFile) -> URL {
        switch self {
        case .huggingface: URL(string: "https://huggingface.co/\(f.repo)/resolve/\(f.revision)/\(f.name)")!
        case .hfMirror: URL(string: "https://hf-mirror.com/\(f.repo)/resolve/\(f.revision)/\(f.name)")!
        // 魔搭上没有 HuggingFace 的提交号，取主分支；内容不对的话 SHA‑256 校验会拦下来
        case .modelscope: URL(string: "https://www.modelscope.cn/models/\(f.repo)/resolve/master/\(f.name)")!
        }
    }
}

/// 一次下载（可能包含好几个文件）。界面直接看它的进度、速度、用的哪个源。
@Observable
final class DownloadJob {
    enum State: Equatable { case running, paused, verifying, failed(String) }

    let files: [ModelFile]
    let folder: URL
    var state: State = .running
    var received: Int64 = 0
    var speed: Double = 0           // 字节/秒
    var source: ModelSource = .huggingface
    var total: Int64 { files.reduce(0) { $0 + $1.size } }
    var fraction: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }

    /// 完成或放弃后调用（成功为 true）。
    var onFinish: ((Bool) -> Void)?

    private var task: Task<Void, Never>?
    private var fetcher: RangeFetcher?

    init(files: [ModelFile], folder: URL) {
        self.files = files
        self.folder = folder
    }

    static func part(_ f: ModelFile, in folder: URL) -> URL { folder.appendingPathComponent(f.name + ".part") }

    func start() {
        guard task == nil else { return }
        state = .running
        task = Task { await run() }
    }

    func pause() {
        guard state == .running else { return }
        state = .paused
        fetcher?.cancel()
        task?.cancel(); task = nil
    }

    /// 放弃：停掉并删掉下了一半的文件。
    func cancel() {
        fetcher?.cancel()
        task?.cancel(); task = nil
        for f in files { try? FileManager.default.removeItem(at: Self.part(f, in: folder)) }
        onFinish?(false)
    }

    private func run() async {
        defer { task = nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fm = FileManager.default
        for f in files {
            let target = folder.appendingPathComponent(f.name)
            if fm.fileExists(atPath: target.path) { continue }
            let part = Self.part(f, in: folder)
            if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
            refreshReceived()

            // 轮流试下载源：一个源连不上、出错、或慢到不像话，就换下一个，从已经下到的地方接着下；
            // 三个仓库源都试过再挂直链兜底。
            var order = ModelSource.allCases
            if let i = order.firstIndex(of: source) { order = Array(order[i...] + order[..<i]) }
            let candidates = order.map { $0.url(f) } + f.fallbackURLs
            var tries = 0
            var ok = false
            while !ok, !Task.isCancelled, tries < candidates.count {
                let url = candidates[tries]
                if tries < order.count { source = order[tries] }
                tries += 1
                let result = await fetch(f, at: url, to: part)
                switch result {
                case .done: ok = true
                case .cancelled: return
                case .slow, .failed: continue
                }
            }
            guard ok else { fail(String(localized: "所有下载源都没下下来，检查网络后点「继续」再试。")); return }

            // 校验
            state = .verifying
            let sum = await Task.detached { Self.sha256(of: part) }.value
            guard sum == f.sha256 else {
                try? fm.removeItem(at: part)
                fail(String(localized: "「\(f.name)」下载下来的文件不完整，已删掉，点「继续」重新下载。"))
                return
            }
            try? fm.removeItem(at: target)
            do { try fm.moveItem(at: part, to: target) } catch { fail(String(localized: "下载好了，但没能放进模型文件夹：\(error.localizedDescription)")); return }
            state = .running
        }
        refreshReceived()
        onFinish?(true)
    }

    private func fail(_ why: String) {
        state = .failed(why)
    }

    private func refreshReceived() {
        let fm = FileManager.default
        received = files.reduce(0) { sum, f in
            let done = folder.appendingPathComponent(f.name)
            if fm.fileExists(atPath: done.path) { return sum + f.size }
            return sum + Self.fileSize(Self.part(f, in: folder))
        }
    }

    private enum FetchResult { case done, slow, failed, cancelled }

    /// 从一个 URL 接着下一个文件。前 20 秒平均不到 300 KB/s，或者 15 秒一个字节都没来，就算慢，换源。
    private func fetch(_ f: ModelFile, at url: URL, to part: URL) async -> FetchResult {
        let start = Self.fileSize(part)
        if start >= f.size { return .done }
        let fetcher = RangeFetcher(url: url, offset: start, file: part)
        self.fetcher = fetcher
        defer { self.fetcher = nil }

        let began = Date()
        var lastBytes = start, lastTick = Date()
        fetcher.start()
        while true {
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { fetcher.cancel(); return .cancelled }
            let now = Date()
            let bytes = start + fetcher.written
            let dt = now.timeIntervalSince(lastTick)
            if dt >= 1 {
                speed = Double(bytes - lastBytes) / dt
                lastBytes = bytes; lastTick = now
            }
            refreshReceived()
            switch fetcher.status {
            case .running:
                let elapsed = now.timeIntervalSince(began)
                if now.timeIntervalSince(fetcher.lastData ?? began) > 15 { fetcher.cancel(); return .slow }
                if elapsed > 20, Double(fetcher.written) / elapsed < 300_000 { fetcher.cancel(); return .slow }
            case .finished:
                return Self.fileSize(part) >= f.size ? .done : .failed
            case .failed:
                return .failed
            }
        }
    }

    nonisolated static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    nonisolated static func sha256(of url: URL) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// 用 HTTP Range 从指定位置接着下，边收边写进文件。
nonisolated final class RangeFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Status { case running, finished, failed }

    private let url: URL
    private let offset: Int64
    private let file: URL
    private let lock = NSLock()
    private var handle: FileHandle?
    private var session: URLSession?
    private var _written: Int64 = 0
    private var _status: Status = .running
    private var _lastData: Date?

    var written: Int64 { lock.withLock { _written } }
    var status: Status { lock.withLock { _status } }
    var lastData: Date? { lock.withLock { _lastData } }

    init(url: URL, offset: Int64, file: URL) {
        self.url = url; self.offset = offset; self.file = file
    }

    func start() {
        handle = try? FileHandle(forWritingTo: file)
        _ = try? handle?.seekToEnd()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        var req = URLRequest(url: url)
        if offset > 0 { req.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        session?.dataTask(with: req).resume()
    }

    func cancel() {
        session?.invalidateAndCancel()
        lock.withLock { if _status == .running { _status = .failed } }
        try? handle?.close(); handle = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 要了断点却回 200（不支持续传）：只有从头下时才接受
        if code == 206 || (code == 200 && offset == 0) { return .allow }
        lock.withLock { _status = .failed }
        return .cancel
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let handle else { return }
        do { try handle.write(contentsOf: data) } catch { lock.withLock { _status = .failed }; dataTask.cancel(); return }
        lock.withLock { _written += Int64(data.count); _lastData = Date() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.withLock { if _status == .running { _status = error == nil ? .finished : .failed } }
        try? handle?.close(); handle = nil
        session.finishTasksAndInvalidate()
    }
}
