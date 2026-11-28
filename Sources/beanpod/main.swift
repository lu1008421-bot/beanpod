// beanpod：让别的工具读写豆仓。
//
//   beanpod mcp                       作为 MCP 服务运行（stdio），给 Claude、OpenClaw、Grok 等 agent 用
//   BEANPOD_MCP_TOKEN=... beanpod serve [--port 8791]  作为 MCP 服务运行（HTTP），仅监听 127.0.0.1，强制令牌鉴权
//   beanpod search 关键词 [选项]       搜索录音
//   beanpod show <id> [--transcript]  看一条录音的纪要（和文字稿）
//   beanpod todos [--all]             待办
//   beanpod topics                    话题、场景、人物一览
//   beanpod add-note 标题 < 文本       把一段文字存进豆仓
//   beanpod add-audio 文件路径         把一个音频文件交给豆仓转写整理
//
// 读是直接读豆仓的记录文件，只读不改。写是把文件放进豆仓的收件箱，由豆仓 App 自己入库。

import BeanKit
import Darwin
import Foundation
import Network

// MARK: - 数据

// 指定了 BEANPOD_DATA_DIR（比如 App 用 -data-dir 隔离出来的测试库）就读写那一份；没指定读正式库
let root = ProcessInfo.processInfo.environment["BEANPOD_DATA_DIR"]
    .map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BeanPod", isDirectory: true)
let libraryURL = root.appendingPathComponent("Recordings/library.json")
let inboxURL = root.appendingPathComponent("Inbox", isDirectory: true)

let sceneNames = ["meeting": "会议", "interview": "访谈", "sales": "销售", "talk": "沟通", "call": "电话",
                  "media": "自媒体", "conference": "大会", "lesson": "课程", "memo": "灵感", "other": "其他"]

struct Rec {
    let raw: [String: Any]
    var id: Int { (raw["id"] as? NSNumber)?.intValue ?? 0 }
    var date: Date? { (raw["date"] as? NSNumber).map { Date(timeIntervalSinceReferenceDate: $0.doubleValue) } }
    var duration: Double { (raw["duration"] as? NSNumber)?.doubleValue ?? 0 }
    var scene: String { raw["scene"] as? String ?? "other" }
    var sceneName: String { sceneNames[scene] ?? "其他" }
    var summary: String { raw["summary"] as? String ?? "" }
    var transcript: String { raw["transcript"] as? String ?? "" }
    var tags: [String] { raw["tags"] as? [String] ?? [] }
    var people: [String] { raw["people"] as? [String] ?? [] }
    var sections: [(heading: String, items: [String])] {
        (raw["sections"] as? [[String: Any]] ?? []).map { ($0["heading"] as? String ?? "", $0["items"] as? [String] ?? []) }
    }
    var todos: [(text: String, done: Bool)] {
        (raw["todos"] as? [[String: Any]] ?? []).map { ($0["text"] as? String ?? "", ($0["done"] as? Bool) ?? false) }
    }
    var segments: [(start: Double, text: String)] {
        (raw["segments"] as? [[String: Any]] ?? []).map { (($0["start"] as? NSNumber)?.doubleValue ?? 0, $0["text"] as? String ?? "") }
    }
    var title: String {
        if let t = raw["title"] as? String, !t.isEmpty { return t }
        return date.map(stamp) ?? "录音 \(id)"
    }
}

func load() -> [Rec] {
    guard let data = try? Data(contentsOf: libraryURL),
          let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
    // 语音输入（按住键说的话）默认不给 AI 助手查，和豆仓里知识库的设置一致
    let withDictation = UserDefaults(suiteName: "com.andyhu.beanpod")?.bool(forKey: "dictationInKnowledge") ?? false
    return list.filter { withDictation || ($0["origin"] as? String) != "语音输入" }
        .map(Rec.init).sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
}

func stamp(_ d: Date) -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f.string(from: d)
}

func clock(_ t: Double) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }

/// 接受 2026-11-12、today、yesterday、7d（七天前）这几种写法。
func parseDay(_ s: String, endOfDay: Bool) -> Date? {
    let cal = Calendar.current, today = cal.startOfDay(for: Date())
    var day: Date?
    switch s.lowercased() {
    case "today", "今天": day = today
    case "yesterday", "昨天": day = cal.date(byAdding: .day, value: -1, to: today)
    default:
        if s.hasSuffix("d"), let n = Int(s.dropLast()) { day = cal.date(byAdding: .day, value: -n, to: today) }
        else { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; day = f.date(from: s) }
    }
    guard let day else { return nil }
    return endOfDay ? cal.date(byAdding: .day, value: 1, to: day) : day
}

// MARK: - 查询

struct Query {
    var text = ""
    var scene: String?
    var person: String?
    var tag: String?
    var from: Date?
    var to: Date?
    var limit = 10
}

func matchScene(_ r: Rec, _ s: String) -> Bool { r.scene == s.lowercased() || r.sceneName == s }

func search(_ q: Query) -> String {
    var out: [String] = []
    let words = q.text.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    for r in load() {
        if let s = q.scene, !matchScene(r, s) { continue }
        if let p = q.person, !(r.people.contains { $0.contains(p) } || r.transcript.contains(p) || r.summary.contains(p)) { continue }
        if let t = q.tag, !r.tags.contains(where: { $0.contains(t) }) { continue }
        if let f = q.from, (r.date ?? .distantPast) < f { continue }
        if let t = q.to, (r.date ?? .distantFuture) >= t { continue }

        var hits: [String] = []
        if !words.isEmpty {
            let notes = [r.title, r.summary, r.tags.joined(separator: " "), r.people.joined(separator: " ")]
                + r.sections.flatMap { $0.items } + r.todos.map { $0.text }
            let all = notes.joined(separator: "\n") + "\n" + r.transcript
            guard words.allSatisfy({ all.range(of: $0, options: .caseInsensitive) != nil }) else { continue }
            for seg in r.segments where words.contains(where: { seg.text.range(of: $0, options: .caseInsensitive) != nil }) {
                hits.append("  - [\(clock(seg.start))] \(snippet(seg.text, words))")
                if hits.count >= 3 { break }
            }
        }
        var block = "### \(r.title)\n- id：\(r.id) ｜ \(r.date.map(stamp) ?? "时间未知") ｜ \(r.sceneName) ｜ \(clock(r.duration))"
        if !r.people.isEmpty { block += "\n- 人物：\(r.people.joined(separator: "、"))" }
        if !r.tags.isEmpty { block += "\n- 话题：\(r.tags.joined(separator: "、"))" }
        if !r.summary.isEmpty { block += "\n- 摘要：\(r.summary)" }
        if !hits.isEmpty { block += "\n- 文字稿里的命中：\n" + hits.joined(separator: "\n") }
        out.append(block)
        if out.count >= q.limit { break }
    }
    return out.isEmpty ? "没有找到符合条件的录音。" : "找到 \(out.count) 条（用 show <id> 看完整纪要）：\n\n" + out.joined(separator: "\n\n")
}

func snippet(_ text: String, _ words: [String]) -> String {
    guard let w = words.first(where: { text.range(of: $0, options: .caseInsensitive) != nil }),
          let r = text.range(of: w, options: .caseInsensitive) else { return String(text.prefix(80)) }
    let a = text.index(r.lowerBound, offsetBy: -30, limitedBy: text.startIndex) ?? text.startIndex
    let b = text.index(r.upperBound, offsetBy: 60, limitedBy: text.endIndex) ?? text.endIndex
    return (a > text.startIndex ? "…" : "") + text[a..<b] + (b < text.endIndex ? "…" : "")
}

func show(_ id: Int, transcript: Bool) -> String {
    guard let r = load().first(where: { $0.id == id }) else { return "没有 id 为 \(id) 的录音。" }
    var md = "# \(r.title)\n\n- 时间：\(r.date.map(stamp) ?? "未知")\n- 场景：\(r.sceneName)\n- 时长：\(clock(r.duration))\n"
    if !r.people.isEmpty { md += "- 人物：\(r.people.joined(separator: "、"))\n" }
    if !r.tags.isEmpty { md += "- 话题：\(r.tags.joined(separator: "、"))\n" }
    if !r.summary.isEmpty { md += "\n## 摘要\n\n\(r.summary)\n" }
    for s in r.sections { md += "\n## \(s.heading)\n\n" + s.items.map { "- \($0)" }.joined(separator: "\n") + "\n" }
    if !r.todos.isEmpty { md += "\n## 待办\n\n" + r.todos.map { "- [\($0.done ? "x" : " ")] \($0.text)" }.joined(separator: "\n") + "\n" }
    if transcript {
        md += "\n## 文字稿\n\n"
        md += r.segments.isEmpty ? r.transcript : r.segments.map { "[\(clock($0.start))] \($0.text)" }.joined(separator: "\n\n")
        md += "\n"
    } else if !r.transcript.isEmpty {
        md += "\n（文字稿共 \(r.transcript.count) 字，需要时加上 transcript 参数再取。）\n"
    }
    return md
}

func todos(all: Bool) -> String {
    var lines: [String] = []
    for r in load() {
        for t in r.todos where all || !t.done {
            lines.append("- [\(t.done ? "x" : " ")] \(t.text)　（来自《\(r.title)》，id \(r.id)，\(r.date.map(stamp) ?? "")）")
        }
    }
    return lines.isEmpty ? "没有\(all ? "" : "未完成的")待办。" : lines.joined(separator: "\n")
}

func topics() -> String {
    let recs = load()
    func count(_ items: [String]) -> String {
        Dictionary(items.map { ($0, 1) }, uniquingKeysWith: +).sorted { $0.value > $1.value }
            .prefix(30).map { "\($0.key)（\($0.value)）" }.joined(separator: "、")
    }
    let total = recs.reduce(0) { $0 + $1.duration }
    return """
    共 \(recs.count) 条录音，合计 \(Int(total / 60)) 分钟。
    场景：\(count(recs.map { $0.sceneName }))
    话题：\(count(recs.flatMap { $0.tags }))
    人物：\(count(recs.flatMap { $0.people }))
    """
}

// MARK: - 写入（经收件箱）

func addNote(title: String, text: String) -> String {
    let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return "内容是空的，没有保存。" }
    try? FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
    let name = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).md"
    let safeTitle = title.replacingOccurrences(of: "\n", with: " ")
    do {
        try "# \(safeTitle)\n\n\(body)\n".write(to: inboxURL.appendingPathComponent(name), atomically: true, encoding: .utf8)
        return "已放进豆仓收件箱。豆仓 App 开着的话，几秒内会入库并整理。"
    } catch { return "保存失败：\(error.localizedDescription)" }
}

func addAudio(path: String) -> String {
    let src = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    guard FileManager.default.fileExists(atPath: src.path) else { return "找不到文件：\(src.path)" }
    let ok = ["wav", "mp3", "m4a", "aac", "caf", "aiff", "aif", "mp4", "mov", "flac", "ogg", "opus", "amr", "silk"]
    guard ok.contains(src.pathExtension.lowercased()) else { return "不支持的文件类型：\(src.pathExtension)" }
    try? FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
    let dst = inboxURL.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(src.lastPathComponent)")
    do {
        try FileManager.default.copyItem(at: src, to: dst)
        return "已把「\(src.lastPathComponent)」放进豆仓收件箱。豆仓 App 开着的话会自动转写整理，稍后可以用 search 查到。"
    } catch { return "复制失败：\(error.localizedDescription)" }
}

// MARK: - MCP（stdio 上的 JSON-RPC，一行一条）

func prop(_ type: String, _ desc: String) -> [String: Any] { ["type": type, "description": desc] }

let tools: [[String: Any]] = [
    ["name": "search_recordings",
     "description": "搜索用户用录音豆录下并整理过的录音（会议、访谈、销售通话、灵感备忘等）。可以按关键词、时间范围、场景、人物、话题筛选，条件之间是「并且」。不给任何条件时返回最近的录音。",
     "inputSchema": ["type": "object", "properties": [
        "query": prop("string", "关键词，多个词用空格分开，要求都出现。在标题、摘要、要点、待办和文字稿里找。"),
        "from": prop("string", "起始日期，YYYY-MM-DD，或 today、yesterday、7d（7 天前）"),
        "to": prop("string", "结束日期（含当天），格式同上"),
        "scene": prop("string", "场景：会议、访谈、销售、沟通、电话、自媒体、大会、课程、灵感、其他"),
        "person": prop("string", "人名或称呼，比如「王总」"),
        "tag": prop("string", "话题标签"),
        "limit": prop("integer", "最多返回几条，默认 10"),
     ]]],
    ["name": "get_recording",
     "description": "取一条录音的完整纪要：摘要、分栏要点、待办、人物、话题。需要逐字内容时把 transcript 设为 true。",
     "inputSchema": ["type": "object", "required": ["id"], "properties": [
        "id": prop("integer", "录音 id，来自 search_recordings 的结果"),
        "transcript": prop("boolean", "是否附上带时间戳的文字稿，默认不附"),
     ]]],
    ["name": "list_todos",
     "description": "列出所有录音里整理出来的待办事项，默认只列未完成的。",
     "inputSchema": ["type": "object", "properties": ["include_done": prop("boolean", "是否包含已完成的")]]],
    ["name": "list_topics",
     "description": "豆仓概览：录音总数和时长，各场景、话题、人物出现的次数。想知道用户最近在忙什么、有哪些素材时先调这个。",
     "inputSchema": ["type": "object", "properties": [:] as [String: Any]]],
    ["name": "add_note",
     "description": "把一段文字（聊天记录、想法、摘录、语音转出来的文字）存进豆仓，豆仓会像对待录音一样判断场景并整理成纪要。",
     "inputSchema": ["type": "object", "required": ["title", "text"], "properties": [
        "title": prop("string", "一句话标题"), "text": prop("string", "正文"),
     ]]],
    ["name": "add_audio",
     "description": "把这台电脑上的一个音频文件（比如微信里收到的语音、电话录音）交给豆仓转写并整理。",
     "inputSchema": ["type": "object", "required": ["path"], "properties": ["path": prop("string", "音频文件的绝对路径")]]],
]

func call(_ name: String, _ a: [String: Any]) -> String {
    func str(_ k: String) -> String? { (a[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    switch name {
    case "search_recordings":
        var q = Query()
        q.text = str("query") ?? ""; q.scene = str("scene"); q.person = str("person"); q.tag = str("tag")
        q.from = str("from").flatMap { parseDay($0, endOfDay: false) }
        q.to = str("to").flatMap { parseDay($0, endOfDay: true) }
        if let n = (a["limit"] as? NSNumber)?.intValue, n > 0 { q.limit = min(n, 50) }
        return search(q)
    case "get_recording":
        guard let id = (a["id"] as? NSNumber)?.intValue ?? (a["id"] as? String).flatMap(Int.init) else { return "缺少 id。" }
        return show(id, transcript: (a["transcript"] as? Bool) ?? false)
    case "list_todos": return todos(all: (a["include_done"] as? Bool) ?? false)
    case "list_topics": return topics()
    case "add_note": return addNote(title: str("title") ?? "未命名", text: str("text") ?? "")
    case "add_audio": return addAudio(path: str("path") ?? "")
    default: return "没有这个工具：\(name)"
    }
}

func send(_ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
    FileHandle.standardOutput.write(data + Data([0x0A]))
}

/// 处理一条 JSON-RPC 消息。通知（没有 id）不回话，返回 nil。
func handle(_ msg: [String: Any]) -> [String: Any]? {
    guard let method = msg["method"] as? String, let id = msg["id"] else { return nil }
    let params = msg["params"] as? [String: Any] ?? [:]
    let result: [String: Any]
    switch method {
    case "initialize":
        result = ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                  "capabilities": ["tools": [:] as [String: Any]],
                  "serverInfo": ["name": "beanpod", "version": "0.2.0"],
                  "instructions": "豆仓保存着用户用录音豆录下的内容和整理出的纪要。回答涉及用户说过什么、开过什么会、答应过什么事时，先用这里的工具查，并在回答里说明依据的是哪条录音。"]
    case "ping": result = [:]
    case "tools/list": result = ["tools": tools]
    case "tools/call":
        let text = call(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:])
        result = ["content": [["type": "text", "text": text]]]
    default:
        return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "不支持的方法：\(method)"]]
    }
    return ["jsonrpc": "2.0", "id": id, "result": result]
}

func runMCP() {
    while let line = readLine(strippingNewline: true) {
        guard let msg = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
        if let reply = handle(msg) { send(reply) }
    }
}

// MARK: - MCP（HTTP）

var parentWatchTimer: DispatchSourceTimer?

func sendHTTPAndClose(_ conn: NWConnection, _ data: Data) {
    conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
}

/// 同一套工具，换成 HTTP 入口：POST /mcp，一个请求一个 JSON 回答。只监听 127.0.0.1，且强制令牌鉴权。
func runHTTP(port: UInt16, parentPID: Int32?) {
    let token = ProcessInfo.processInfo.environment["BEANPOD_MCP_TOKEN"] ?? ""
    guard MCPHTTPPolicy.isValidTokenFormat(token) else {
        let msg = "启动 HTTP MCP 失败：请通过环境变量 BEANPOD_MCP_TOKEN 提供至少 \(MCPHTTPPolicy.minimumTokenLength) 位非空白 ASCII 令牌。\n"
        FileHandle.standardError.write(Data(msg.utf8))
        exit(1)
    }
    let params = NWParameters.tcp
    params.allowLocalEndpointReuse = true
    guard let nwPort = NWEndpoint.Port(rawValue: port) else {
        print("端口 \(port) 用不了"); exit(1)
    }
    params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
    guard let listener = try? NWListener(using: params) else {
        print("端口 \(port) 用不了"); exit(1)
    }
    if let ppid = parentPID, ppid > 1 {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler {
            if kill(ppid, 0) != 0 && errno == ESRCH { exit(0) }
        }
        timer.resume()
        parentWatchTimer = timer
    }
    listener.newConnectionHandler = { conn in
        conn.start(queue: .global())
        receive(conn, Data(), port: port, expectedToken: token)
    }
    listener.stateUpdateHandler = { state in
        if case .failed(let e) = state { print("监听失败：\(e)"); exit(1) }
        if case .waiting(let e) = state { print("端口 \(port) 暂时用不了：\(e)"); exit(1) }
        if case .ready = state { print("豆仓 MCP 已在 http://127.0.0.1:\(port)/mcp 就绪（已启用本机令牌鉴权）"); fflush(stdout) }
    }
    listener.start(queue: .global())
    dispatchMain()
}

func receive(_ conn: NWConnection, _ buffer: Data, port: UInt16, expectedToken: String) {
    conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, error in
        var buf = buffer
        if let data { buf.append(data) }
        // 等头部收完，先做 Host / Origin / 方法 / 令牌校验，再按 Content-Length 收正文
        if let headEnd = buf.range(of: Data("\r\n\r\n".utf8)) {
            let headBytes = buf[..<headEnd.lowerBound]
            guard headBytes.count <= MCPHTTPPolicy.maxHeaderBytes else {
                sendHTTPAndClose(conn, MCPHTTPPolicy.formatResponse(status: "431 Request Header Fields Too Large", body: MCPHTTPPolicy.errorBody("headers too large")))
                return
            }
            let head = String(decoding: headBytes, as: UTF8.self)
            switch MCPHTTPPolicy.parseRequestHead(head) {
            case .error(let status, let message):
                sendHTTPAndClose(conn, MCPHTTPPolicy.formatResponse(status: status, body: MCPHTTPPolicy.errorBody(message)))
                return
            case .ok(let req):
                switch MCPHTTPPolicy.validate(req, port: port, expectedToken: expectedToken) {
                case .reject(let status, let message, let extraHeaders):
                    sendHTTPAndClose(conn, MCPHTTPPolicy.formatResponse(status: status, body: MCPHTTPPolicy.errorBody(message), extraHeaders: extraHeaders))
                    return
                case .health:
                    sendHTTPAndClose(conn, MCPHTTPPolicy.formatResponse(status: "200 OK", body: Data("{\"ok\":true}".utf8)))
                    return
                case .mcp:
                    let body = buf[headEnd.upperBound...]
                    if body.count >= req.contentLength {
                        handleMCPBody(conn, Data(body.prefix(req.contentLength)))
                        return
                    }
                }
            }
        } else if buf.count > MCPHTTPPolicy.maxHeaderBytes {
            sendHTTPAndClose(conn, MCPHTTPPolicy.formatResponse(status: "431 Request Header Fields Too Large", body: MCPHTTPPolicy.errorBody("headers too large")))
            return
        }
        if done || error != nil || buf.count > MCPHTTPPolicy.maxHeaderBytes + MCPHTTPPolicy.maxBodyBytes {
            conn.cancel()
            return
        }
        receive(conn, buf, port: port, expectedToken: expectedToken)
    }
}

func handleMCPBody(_ conn: NWConnection, _ body: Data) {
    guard let json = try? JSONSerialization.jsonObject(with: body) else {
        sendHTTPAndClose(conn, MCPHTTPPolicy.formatResponse(status: "400 Bad Request", body: MCPHTTPPolicy.errorBody("bad json")))
        return
    }
    let messages = (json as? [[String: Any]]) ?? (json as? [String: Any]).map { [$0] } ?? []
    let replies = messages.compactMap(handle)
    if replies.isEmpty {
        sendHTTPAndClose(conn, MCPHTTPPolicy.formatResponse(status: "202 Accepted", body: Data()))
        return
    }
    let payload: Any = (json is [Any]) ? replies : replies[0]
    let encoded = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
    sendHTTPAndClose(conn, MCPHTTPPolicy.formatResponse(status: "200 OK", body: encoded))
}

// MARK: - 命令行

var args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> Bool { if let i = args.firstIndex(of: name) { args.remove(at: i); return true }; return false }
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
}

let command = args.isEmpty ? "help" : args.removeFirst()
switch command {
case "mcp": runMCP()
case "serve":
    let port = option("--port").flatMap(UInt16.init) ?? 8791
    let parentPID = option("--parent-pid").flatMap(Int32.init)
    runHTTP(port: port, parentPID: parentPID)
case "search":
    var q = Query()
    q.scene = option("--scene"); q.person = option("--person"); q.tag = option("--tag")
    q.from = option("--from").flatMap { parseDay($0, endOfDay: false) }
    q.to = option("--to").flatMap { parseDay($0, endOfDay: true) }
    if let n = option("--limit").flatMap(Int.init) { q.limit = n }
    q.text = args.joined(separator: " ")
    print(search(q))
case "show":
    let t = flag("--transcript")
    print(args.first.flatMap(Int.init).map { show($0, transcript: t) } ?? "用法：beanpod show <id> [--transcript]")
case "todos": print(todos(all: flag("--all")))
case "topics": print(topics())
case "add-note":
    let text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    print(addNote(title: args.joined(separator: " ").isEmpty ? "未命名" : args.joined(separator: " "), text: text))
case "add-audio": print(args.first.map(addAudio) ?? "用法：beanpod add-audio <文件路径>")
default:
    print("""
    beanpod：让别的工具读写豆仓

      beanpod mcp                                       作为 MCP 服务运行，给 Claude、OpenClaw 等 agent 用
      BEANPOD_MCP_TOKEN=<令牌> beanpod serve [--port 8791]  同上，但走 HTTP，仅监听 http://127.0.0.1:8791/mcp
      beanpod search [关键词] [--from 日期] [--to 日期] [--scene 场景] [--person 人物] [--tag 话题] [--limit N]
      beanpod show <id> [--transcript]                  一条录音的纪要
      beanpod todos [--all]                             待办
      beanpod topics                                    场景、话题、人物一览
      beanpod add-note 标题 < 文本                       把文字存进豆仓
      beanpod add-audio <文件>                           把音频交给豆仓转写整理

    日期可以写 2026-11-12、today、yesterday、7d。
    """)
}
