import BeanKit
import Foundation
import SwiftUI

/// 从飞书妙记把录音拉回豆仓（设计稿 design/ui/ui_feishu.png）。
///
/// 为什么要有：录音豆同一时间只连一台设备。手机上的录音豆 App 先连上的话，会把录音同步进飞书妙记，
/// 录音豆上就没有了，豆仓连上也拿不到。这里借飞书官方命令行工具 lark-cli（用户自己授权）去妙记里找回来。
///
/// - 列表：按时间搜「我的妙记」，和录音库对一遍——已经在豆仓的（包括「最近删除」里的）标「已在豆仓」，其它是「新的」。
/// - 拉回：有「导出妙记音视频」权限就下载音频，交给豆仓自己转写整理；没有就先拿飞书的文字稿整理成纪要。
/// - 自动同步：第一次由用户勾选；之后新出现的妙记自动拉回。没勾的记下来，不再问。
@MainActor @Observable
final class FeishuSync {
    static let shared = FeishuSync()

    enum Link: Equatable {
        case unknown, checking
        case noTool                 // 这台 Mac 没装 lark-cli
        case notLoggedIn            // 装了但没配置 / 没授权
        case ready
        case failed(String)
    }

    struct Minute: Identifiable, Equatable {
        let id: String              // minute_token
        var title: String
        /// 上传到飞书的时间（不是录音开始的时间）
        var uploaded: Date?
        /// 从「soundcore Work_11-12 22:40」这种标题里读出来的录音时间
        var recorded: Date?
        var duration: TimeInterval
        var url: String
        /// 录音大概是什么时候开始的：标题里有就用标题的，否则用上传时间往前推一个时长
        var start: Date { recorded ?? uploaded.map { $0.addingTimeInterval(-duration) } ?? .now }
    }

    enum Status: Equatable { case new, inLibrary(UInt32), removed, skipped, pulling, failed(String) }

    var link: Link = .unknown
    var minutes: [Minute] = []
    var lastChecked: Date?
    var pulling: Set<String> = []
    var errors: [String: String] = [:]
    /// 勾选（新的默认勾上）
    var picked: Set<String> = []
    /// 下载音频被拒（没开「导出妙记音视频」权限）
    var audioDenied = false
    var auto: Bool = UserDefaults.standard.object(forKey: "feishuAuto") as? Bool ?? true {
        didSet { UserDefaults.standard.set(auto, forKey: "feishuAuto") }
    }

    /// 拉回过的：妙记 → 录音编号
    private(set) var imported: [String: UInt32] = (UserDefaults.standard.dictionary(forKey: "feishuImported") as? [String: NSNumber] ?? [:]).mapValues(\.uint32Value) {
        didSet { UserDefaults.standard.set(imported.mapValues { NSNumber(value: $0) }, forKey: "feishuImported") }
    }
    /// 用户没勾、不想要的妙记
    private(set) var skipped: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "feishuSkipped") ?? []) {
        didSet { UserDefaults.standard.set(Array(skipped), forKey: "feishuSkipped") }
    }
    /// 第一次检查的时间。之后上传的才自动拉；这之前的等用户自己勾。
    private var baseline: Date? = UserDefaults.standard.object(forKey: "feishuBaseline") as? Date {
        didSet { UserDefaults.standard.set(baseline, forKey: "feishuBaseline") }
    }
    /// 录音编号 → 飞书里的链接（详情页「在飞书妙记里打开」用）
    private var links: [String: String] = UserDefaults.standard.dictionary(forKey: "feishuLinks") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(links, forKey: "feishuLinks") }
    }

    private weak var store: BeanStore?
    private var tool: String?
    private var loop: Task<Void, Never>?

    func link(for id: UInt32) -> URL? { links[String(id)].flatMap(URL.init(string:)) }

    /// 启动时调一次：先查一遍，之后每 30 分钟查一次（自动同步开着才会自己拉）。
    func attach(_ store: BeanStore) {
        self.store = store
        guard !BeanStore.demo else { showDemo(); return }
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.check(autoPull: true)
                try? await Task.sleep(for: .seconds(30 * 60))
            }
        }
    }

    /// 示例数据模式：不连飞书，摆几条虚构的妙记（README 截图用）
    private func showDemo() {
        let now = Date.now
        minutes = [
            Minute(id: "demo1", title: "门店晨会：冬季新品试喝反馈", uploaded: now.addingTimeInterval(-3_000), recorded: nil, duration: 1_386, url: ""),
            Minute(id: "demo2", title: "soundcore Work_\(Self.short(now.addingTimeInterval(-7_200)))", uploaded: now.addingTimeInterval(-6_000),
                   recorded: now.addingTimeInterval(-7_200), duration: 42, url: ""),
            Minute(id: "demo3", title: "供应商报价沟通", uploaded: now.addingTimeInterval(-90_000), recorded: nil, duration: 1_104, url: ""),
        ]
        picked = ["demo1", "demo2"]
        lastChecked = now.addingTimeInterval(-120)
        link = .ready
    }

    private static func short(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; return f.string(from: d)
    }

    // MARK: 查

    func status(of m: Minute) -> Status {
        if pulling.contains(m.id) { return .pulling }
        if let id = imported[m.id] {
            let still = store?.recordings.contains(where: { $0.id == id }) == true || store?.trash.contains(where: { $0.recording.id == id }) == true
            // 拉回过、后来又被彻底删掉的：不再当成新的，免得自动同步又拉回来
            return still ? .inLibrary(id) : .removed
        }
        if let id = match(m) { return .inLibrary(id) }
        if let e = errors[m.id] { return .failed(e) }
        return skipped.contains(m.id) ? .skipped : .new
    }

    var newOnes: [Minute] { minutes.filter { status(of: $0) == .new } }

    /// 录音库（和最近删除）里已经有的同一段：时长差不到 2 秒，而且时间对得上——
    /// 标题里带录音时间的，差两分钟以内；没有的（飞书给改了标题），要录在上传之前、一周以内。
    private func match(_ m: Minute) -> UInt32? {
        guard let store else { return nil }
        let all = store.recordings.filter { !$0.isMaterial } + store.trash.map(\.recording)
        return all.first { r in
            guard abs(r.duration - m.duration) < 2, let d = r.date else { return false }
            if let rec = m.recorded { return abs(d.timeIntervalSince(rec)) < 120 }
            guard m.duration >= 20, let up = m.uploaded else { return false }     // 太短的只靠时长容易撞
            return d <= up.addingTimeInterval(600) && up.timeIntervalSince(d) < 7 * 86_400
        }?.id
    }

    func check(autoPull: Bool = false) async {
        guard link != .checking, !BeanStore.demo else { return }
        link = .checking
        if tool == nil { tool = await Self.findLark() }
        guard let tool else { link = .noTool; return }
        let since = Calendar.current.date(byAdding: .day, value: -30, to: .now)!
        var found: [Minute] = []
        var pageToken: String?
        for _ in 0..<4 {
            var args = ["minutes", "+search", "--owner-ids", "me", "--start", Self.day.string(from: since), "--page-size", "30", "--format", "json"]
            if let pageToken { args += ["--page-token", pageToken] }
            let r = await BeanStore.runTool(tool, args) { _ in }
            guard let obj = Self.reply(r) else { link = .failed(String(localized: "飞书没有回话：\(r.errors.prefix(120))")); return }
            if let err = obj["error"] as? [String: Any] {
                let type = err["type"] as? String ?? ""
                link = type == "config" || type == "authorization" || type == "auth" ? .notLoggedIn : .failed(err["message"] as? String ?? String(localized: "飞书报错"))
                return
            }
            let data = obj["data"] as? [String: Any] ?? [:]
            for item in data["items"] as? [[String: Any]] ?? [] {
                if let m = Self.minute(item) { found.append(m) }
            }
            pageToken = data["page_token"] as? String
            guard data["has_more"] as? Bool == true, pageToken != nil else { break }
        }
        minutes = found.sorted { ($0.uploaded ?? .distantPast) > ($1.uploaded ?? .distantPast) }
        lastChecked = .now
        link = .ready
        // 以前只拉回了文字稿的，现在有音频权限就补上
        if autoPull, !textOnlyImports.isEmpty { await fillAudio() }
        let fresh = newOnes
        // 新的默认勾上——只勾最近一天传上去的；更早的（比如几天前的会议）列着，要的话自己勾，免得第一次一下拉回几十条
        let recent = Date.now.addingTimeInterval(-86_400)
        picked.formUnion(fresh.filter { ($0.uploaded ?? .distantPast) > recent }.map(\.id))
        if baseline == nil { baseline = .now; return }      // 第一次：等用户勾，不自动拉
        if autoPull, auto, let baseline {
            let late = fresh.filter { ($0.uploaded ?? .distantPast) > baseline }
            if !late.isEmpty { await pull(late.map(\.id), skipRest: false) }
        }
    }

    // MARK: 拉回

    /// 拉回选中的；skipRest 时把没勾的新妙记记成「不要」，以后不再问。
    func pull(_ ids: [String], skipRest: Bool) async {
        guard let tool, let store else { return }
        // 最近一天里新的、用户特意取消勾选的：记成不要，以后不再问（更早的本来就没勾，不算）
        if skipRest {
            let recent = Date.now.addingTimeInterval(-86_400)
            let rest = newOnes.filter { !ids.contains($0.id) && ($0.uploaded ?? .distantPast) > recent }.map(\.id)
            skipped.formUnion(rest)
        }
        var done = 0
        for token in ids {
            // 另一轮拉回（定时的或手动的）可能已经把它拉进来了：轮到它时再看一眼
            guard let m = minutes.first(where: { $0.id == token }), !pulling.contains(token) else { continue }
            switch status(of: m) {
            case .new, .skipped, .failed: break
            default: continue
            }
            pulling.insert(token); errors[token] = nil
            defer { pulling.remove(token) }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("feishu-\(token)", isDirectory: true)
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            var id: UInt32?
            // 先要音频
            // lark-cli 只认当前目录下的相对路径：在临时文件夹里跑，输出到「.」
            let dl = await BeanStore.runTool(tool, ["minutes", "+download", "--minute-tokens", token, "--output-dir", ".", "--overwrite", "--format", "json"], cwd: dir) { _ in }
            if let err = Self.reply(dl)?["error"] as? [String: Any] {
                if (err["subtype"] as? String) == "missing_scope" { audioDenied = true }
                else { store.addLog("飞书妙记 \(token) 下载音频失败：\(err["message"] as? String ?? "")") }
            } else if let audio = Self.firstFile(in: dir, ext: ["m4a", "mp3", "mp4", "aac", "wav", "ogg", "webm", "opus", "mov"]) {
                audioDenied = false
                id = await store.importFeishuAudio(audio, minute: m)
            }
            // 拿不到音频：拿飞书的文字稿
            if id == nil {
                let det = await BeanStore.runTool(tool, ["minutes", "+detail", "--minute-tokens", token, "--transcript", "--output-dir", ".", "--overwrite", "--format", "json"], cwd: dir) { _ in }
                if let file = Self.firstFile(in: dir, ext: ["txt"]), let raw = try? String(contentsOf: file, encoding: .utf8) {
                    id = store.importFeishuText(Self.cleanTranscript(raw), minute: m)
                } else {
                    let why = (Self.reply(det)?["error"] as? [String: Any])?["message"] as? String ?? String(localized: "飞书没给文字稿")
                    errors[token] = why
                    store.addLog("飞书妙记 \(token) 文字稿没拿到：\(why)")
                }
            }
            if let id {
                imported[token] = id
                links[String(id)] = m.url
                done += 1
            }
        }
        if done > 0 {
            store.announce("arrow.down.circle.fill", String(localized: "从飞书妙记拉回了 \(done) 条录音"), body: audioDenied ? String(localized: "飞书没给音频，先用飞书的文字稿整理。") : String(localized: "正在转写整理。"))
        }
    }

    /// 以前没有音频权限、只拉回了文字稿的：现在能下音频了就补上，重新转写（带上每句的时间，才能点句子回听）。
    var textOnlyImports: [UInt32] {
        imported.values.filter { id in store?.recordings.contains { $0.id == id && $0.textOnly } == true }
    }

    func fillAudio() async {
        guard let tool, let store, !textOnlyImports.isEmpty else { return }
        var done = 0
        for (token, id) in imported where textOnlyImports.contains(id) {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("feishu-audio-\(token)", isDirectory: true)
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let dl = await BeanStore.runTool(tool, ["minutes", "+download", "--minute-tokens", token, "--output-dir", ".", "--overwrite", "--format", "json"], cwd: dir) { _ in }
            if let err = Self.reply(dl)?["error"] as? [String: Any] {
                if (err["subtype"] as? String) == "missing_scope" { audioDenied = true; return }
                store.addLog("飞书妙记 \(token) 补音频失败：\(err["message"] as? String ?? "")")
                continue
            }
            guard let audio = Self.firstFile(in: dir, ext: ["m4a", "mp3", "mp4", "aac", "wav", "ogg", "webm", "opus", "mov"]) else { continue }
            audioDenied = false
            if await store.attachFeishuAudio(audio, to: id) { done += 1 }
        }
        if done > 0 { store.announce("waveform", String(localized: "给 \(done) 条飞书录音补上了音频"), body: String(localized: "正在重新转写，转完就能点句子回听。")) }
    }

    // MARK: 解析

    private static let day: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f }()
    private static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy.MM.dd HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX"); return f }()

    /// 成功的回话在标准输出，报错在标准错误里
    private static func reply(_ r: (status: Int32, output: String, errors: String)) -> [String: Any]? {
        json(r.output) ?? json(r.errors)
    }

    private static func json(_ text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(text[start...].utf8)) as? [String: Any]
    }

    /// 搜索结果的一条：display_info 第一行是标题；description 里有「开始时间: 2026.11.16 13:35:39 时长: 44 分 38 秒」。
    static func minute(_ item: [String: Any]) -> Minute? {
        guard let token = item["token"] as? String else { return nil }
        let meta = item["meta_data"] as? [String: Any] ?? [:]
        let info = item["display_info"] as? String ?? ""
        let title = info.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? "飞书妙记"
        let desc = meta["description"] as? String ?? info
        var uploaded: Date?
        if let r = desc.range(of: #"\d{4}\.\d{2}\.\d{2} \d{2}:\d{2}:\d{2}"#, options: .regularExpression) { uploaded = stamp.date(from: String(desc[r])) }
        return Minute(id: token, title: title, uploaded: uploaded, recorded: recordedDate(title, near: uploaded ?? .now),
                      duration: duration(desc), url: meta["app_link"] as? String ?? "")
    }

    /// 「时长: 1 小时 2 分 3 秒」→ 秒
    static func duration(_ desc: String) -> TimeInterval {
        guard let r = desc.range(of: "时长:") ?? desc.range(of: "时长：") else { return 0 }
        let s = String(desc[r.upperBound...])
        func num(_ unit: String) -> Double {
            guard let u = s.range(of: #"(\d+)\s*"# + unit, options: .regularExpression) else { return 0 }
            return Double(s[u].filter(\.isNumber)) ?? 0
        }
        return num("小时") * 3600 + num("分") * 60 + num("秒")
    }

    /// 录音豆 App 传上去的默认标题「soundcore Work_11-12 22:40」里带着录音时间（没有年份：取上传时间那年，晚于上传就算去年）。
    static func recordedDate(_ title: String, near: Date) -> Date? {
        guard let r = title.range(of: #"(\d{2})-(\d{2}) (\d{2}):(\d{2})$"#, options: .regularExpression) else { return nil }
        let p = title[r].split(whereSeparator: { $0 == "-" || $0 == " " || $0 == ":" }).compactMap { Int($0) }
        guard p.count == 4 else { return nil }
        let cal = Calendar.current
        var c = DateComponents(year: cal.component(.year, from: near), month: p[0], day: p[1], hour: p[2], minute: p[3])
        guard var d = cal.date(from: c) else { return nil }
        if d > near.addingTimeInterval(86_400) { c.year! -= 1; d = cal.date(from: c) ?? d }
        return d
    }

    /// 飞书文字稿：开头是「时间|时长」和关键词，之后是「Speaker 1 00:00:02.770」一行、正文一行。只留正文，按说话人分段。
    static func cleanTranscript(_ raw: String) -> String {
        var out: [String] = []
        var speaker: String?
        var started = false
        for line in raw.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.range(of: #"^(.+?)\s+\d{2}:\d{2}:\d{2}(\.\d+)?$"#, options: .regularExpression) != nil {
                started = true
                speaker = t.components(separatedBy: " ").dropLast().joined(separator: " ")
                continue
            }
            guard started, !t.isEmpty else { continue }
            out.append(speaker.map { "\($0)：\(t)" } ?? t)
            speaker = nil
        }
        return out.isEmpty ? raw : out.joined(separator: "\n\n")
    }

    private static func firstFile(in dir: URL, ext: [String]) -> URL? {
        let all = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return all.first { ext.contains($0.pathExtension.lowercased()) }
    }

    /// lark-cli 一般装在 npm 的全局目录里，图形界面启动的应用拿不到终端的 PATH，先看常见位置。
    nonisolated static func findLark() async -> String? {
        let home = NSHomeDirectory()
        for dir in ["\(home)/.npm-global/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"] {
            let p = dir + "/lark-cli"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return await BeanStore.findTool("lark-cli")
    }
}

extension BeanStore {
    /// 新录音的编号：录音豆用开始录音的 Unix 秒，这里也按开始时间取，撞了往后挪。
    private func freshID(near date: Date) -> UInt32 {
        var id = UInt32(max(0, date.timeIntervalSince1970))
        while recordings.contains(where: { $0.id == id }) || trash.contains(where: { $0.recording.id == id }) { id += 1 }
        return id
    }

    /// 标题：录音豆 App 的默认标题（「soundcore Work_11-12 22:40」）不要，让豆仓整理时自己起；飞书起过的留着。
    private func feishuTitle(_ m: FeishuSync.Minute) -> String? { m.recorded == nil ? m.title : nil }

    func importFeishuAudio(_ file: URL, minute m: FeishuSync.Minute) async -> UInt32? {
        let id = allocateRecordingID(near: m.start)
        defer { reservedImportIDs.remove(id) }
        let dest = wavURL(id)
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try AudioStream.transcodeToMono16kWAV(from: file, to: dest, minSamples: 1601)
            }.value
            var rec = Recording(id: id, size: UInt32(clamping: result.byteSize), date: m.start, duration: result.duration)
            rec.downloaded = true; rec.origin = Self.feishuOrigin; rec.title = feishuTitle(m)
            insertImported(rec)
            addLog("从飞书妙记拉回音频 \(m.id) → \(id)")
            if settings.autoProcess { process(id) }
            return id
        } catch AudioStreamError.unreadable, AudioStreamError.tooShort {
            try? FileManager.default.removeItem(at: dest)
            addLog("飞书妙记 \(m.id) 的音频解不开")
            return nil
        } catch {
            try? FileManager.default.removeItem(at: dest)
            addLog("飞书妙记写不进磁盘：\(error.localizedDescription)")
            return nil
        }
    }

    func importFeishuText(_ text: String, minute m: FeishuSync.Minute) -> UInt32? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let id = freshID(near: m.start)
        var rec = Recording(id: id, size: UInt32(text.utf8.count), date: m.start, duration: m.duration)
        rec.downloaded = true; rec.textOnly = true; rec.origin = Self.feishuOrigin
        rec.title = feishuTitle(m); rec.transcript = text; rec.transcribedBy = "飞书妙记"
        insertImported(rec)
        addLog("从飞书妙记拉回文字稿 \(m.id) → \(id)")
        process(id)
        return id
    }

    static let feishuOrigin = "飞书妙记"

    /// 给只有文字稿的飞书录音补上音频：写 wav、不再是纯文字，重新转写（纪要、标题、标签照常更新）。
    func attachFeishuAudio(_ file: URL, to id: UInt32) async -> Bool {
        // 正在处理（转写或整理）的先不动：process 会因为它在队列里直接返回，补上的音频就没被转写，以后也不会再补
        guard stages[id] == nil else { addLog("飞书录音 \(id) 正在处理，等处理完再补音频"); return false }
        guard recordings.contains(where: { $0.id == id }) else { return false }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("beanpod-feishu-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let result: WAVWriteResult
        do {
            result = try await Task.detached(priority: .userInitiated) {
                try AudioStream.transcodeToMono16kWAV(from: file, to: tmp, minSamples: 1601)
            }.value
        } catch {
            return false
        }
        guard stages[id] == nil, let i = recordings.firstIndex(where: { $0.id == id }) else { return false }
        let dest = wavURL(id)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: dest)
            }
        } catch { return false }
        recordings[i].textOnly = false
        recordings[i].duration = result.duration
        recordings[i].size = UInt32(clamping: result.byteSize)
        saveLibrary()
        addLog("飞书录音 \(id) 补上音频，重新转写")
        process(id, retranscribe: true)
        return true
    }

    private func insertImported(_ rec: Recording) {
        recordings.append(rec)
        recordings.sort { ($0.date ?? .distantPast, $0.id) > ($1.date ?? .distantPast, $1.id) }
        saveLibrary()
    }
}
