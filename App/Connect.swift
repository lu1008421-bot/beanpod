import AppKit
import SwiftUI

/// 能接上豆仓的 AI 助手。接上之后，可以在它们那边直接问「我昨天开会说了什么」，或者让它们把内容存进豆仓。
enum Assistant: String, CaseIterable, Identifiable {
    case claudeCode, claudeDesktop, codex, openclaw, grok
    var id: String { rawValue }

    var name: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .claudeDesktop: String(localized: "Claude 桌面版")
        case .codex: "Codex"
        case .openclaw: "OpenClaw"
        case .grok: "Grok Bot"
        }
    }

    var icon: String {
        switch self {
        case .claudeCode: "terminal"
        case .claudeDesktop: "macwindow"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .openclaw: "bubble.left.and.bubble.right"
        case .grok: "sparkle"
        }
    }

    /// 接上之后能怎么用，给一句照着说就行的话。
    var example: String {
        switch self {
        case .claudeCode: String(localized: "在 Claude Code 里说：「查一下豆仓里昨天的会议，把待办列出来」")
        case .claudeDesktop: String(localized: "在 Claude 里说：「豆仓里关于新品发布都说过什么？」")
        case .codex: String(localized: "在 Codex 里说：「把豆仓里最新一条录音的脚本拿出来，做成网页」")
        case .openclaw: String(localized: "在微信里对它说：「帮我查豆仓，这周答应了谁什么事」")
        case .grok: String(localized: "在 Grok Bot 里添加上面的地址，然后说：「搜一下豆仓里提到黄仁勋的录音」")
        }
    }

    /// 连接时改了什么，明明白白告诉用户。
    var touches: String {
        switch self {
        case .claudeCode: String(localized: "用 claude 命令添加，写在 ~/.claude.json")
        case .claudeDesktop: String(localized: "改 ~/Library/Application Support/Claude/claude_desktop_config.json，改之前会留一份备份。要在 Claude 完全退出的时候连")
        case .codex: String(localized: "用 codex 命令添加，写在 ~/.codex/config.toml")
        case .openclaw: String(localized: "用 openclaw 命令添加，写在 ~/.openclaw/openclaw.json")
        case .grok: String(localized: "Grok Bot 只认网址：需要先开启本机网址入口，再把含令牌的地址粘贴到它的设置里。豆仓要开着才连得上")
        }
    }

    /// 靠命令行连接的那几个，命令叫什么。
    var command: String? {
        switch self {
        case .claudeCode: "claude"
        case .codex: "codex"
        case .openclaw: "openclaw"
        default: nil
        }
    }
}

@Observable
final class Connector {
    struct State: Equatable {
        var installed = false
        /// nil 表示看不出来（Grok Bot 的设置豆仓读不到）。
        var connected: Bool? = false
    }

    var states: [Assistant: State] = [:]
    var busy: Set<Assistant> = []
    /// 每个助手最近一次操作的结果，显示在它的卡片上。
    var notes: [Assistant: (ok: Bool, text: String)] = [:]
    var checking = false

    private static let cli = BeanStore.cliPath
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static var desktopConfig: URL { home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json") }

    var cliInstalled: Bool { FileManager.default.isExecutableFile(atPath: Self.cli) }
    var connectedCount: Int { states.values.filter { $0.connected == true }.count }

    /// 在用户自己的登录环境里跑一条命令（这几个工具装在哪，只有登录环境的 PATH 知道）。
    nonisolated private static func shell(_ command: String) async -> (ok: Bool, output: String) {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", command]
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return (false, String(localized: "命令没能运行")) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
        }.value
    }

    private static func json(_ url: URL) -> [String: Any]? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// 看一遍：每个助手装了没有、接上豆仓没有。只读，不改任何东西。
    func refresh() async {
        checking = true
        defer { checking = false }
        let found = await Self.shell("for c in claude codex openclaw; do command -v $c >/dev/null 2>&1 && echo $c; done").output
        let fm = FileManager.default
        var next: [Assistant: State] = [:]
        for a in Assistant.allCases {
            var s = State()
            switch a {
            case .claudeCode:
                s.installed = found.contains("claude")
                let servers = Self.json(Self.home.appendingPathComponent(".claude.json"))?["mcpServers"] as? [String: Any]
                s.connected = servers?["beanpod"] != nil
            case .claudeDesktop:
                s.installed = fm.fileExists(atPath: "/Applications/Claude.app")
                let servers = Self.json(Self.desktopConfig)?["mcpServers"] as? [String: Any]
                s.connected = servers?["beanpod"] != nil
            case .codex:
                s.installed = found.contains("codex")
                let toml = (try? String(contentsOf: Self.home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)) ?? ""
                s.connected = toml.contains("[mcp_servers.beanpod]")
            case .openclaw:
                s.installed = found.contains("openclaw")
                let mcp = Self.json(Self.home.appendingPathComponent(".openclaw/openclaw.json"))?["mcp"] as? [String: Any]
                s.connected = (mcp?["servers"] as? [String: Any])?["beanpod"] != nil
            case .grok:
                s.installed = fm.fileExists(atPath: "/Applications/Grok Bot.app")
                s.connected = nil
            }
            next[a] = s
        }
        states = next
    }

    func connect(_ a: Assistant, store: BeanStore) async {
        guard cliInstalled else { notes[a] = (false, String(localized: "豆仓的命令行工具还没装好，连不了。")); return }
        busy.insert(a); defer { busy.remove(a) }
        let cli = "'\(Self.cli)'"
        switch a {
        case .claudeCode:
            let r = await Self.shell("claude mcp add --scope user beanpod -- \(cli) mcp")
            notes[a] = r.ok ? (true, String(localized: "接上了。新开一个 Claude Code 会话就能用。")) : (false, String(localized: "没接上：\(Self.tail(r.output))"))
        case .codex:
            let r = await Self.shell("codex mcp add beanpod -- \(cli) mcp")
            notes[a] = r.ok ? (true, String(localized: "接上了。新开一个 Codex 会话就能用。")) : (false, String(localized: "没接上：\(Self.tail(r.output))"))
        case .openclaw:
            let r = await Self.shell("openclaw mcp add beanpod --command \(cli) --arg mcp")
            notes[a] = r.ok ? (true, String(localized: "接上了。")) : (false, String(localized: "没接上：\(Self.tail(r.output))"))
        case .claudeDesktop:
            // Claude 开着的时候会用自己内存里的设置把文件写回去，这条改动会被冲掉：要先退出它
            let running = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop").isEmpty
            if running {
                notes[a] = (false, String(localized: "Claude 现在开着。它开着的时候会把设置文件写回原样，连接留不住。请先完全退出 Claude，再回来点一次「连接」。"))
                return
            }
            notes[a] = editDesktopConfig { servers in servers["beanpod"] = ["command": Self.cli, "args": ["mcp"]] }
                ? (true, String(localized: "接上了。现在打开 Claude 就能用。")) : (false, String(localized: "没能改 Claude 的设置文件。"))
        case .grok:
            if !store.settings.httpMCPEnabled {
                store.setHTTPMCPEnabled(true)
            } else if !store.mcpServerRunning {
                store.startMCPServer()
            }
            guard let addr = store.mcpAuthenticatedAddress() else {
                notes[a] = (false, String(localized: "无法生成本机访问令牌，请检查系统钥匙串权限。"))
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(addr, forType: .string)
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Grok Bot.app"))
            notes[a] = (true, String(localized: "已开启本机网址入口并拷贝含令牌地址，Grok Bot 也打开了。到它的设置里添加一个 MCP，把地址粘贴进去。"))
        }
        await refresh()
    }

    func disconnect(_ a: Assistant) async {
        busy.insert(a); defer { busy.remove(a) }
        switch a {
        case .claudeCode:
            let r = await Self.shell("claude mcp remove --scope user beanpod")
            notes[a] = r.ok ? (true, String(localized: "已经断开。")) : (false, String(localized: "没断开：\(Self.tail(r.output))"))
        case .codex:
            let r = await Self.shell("codex mcp remove beanpod")
            notes[a] = r.ok ? (true, String(localized: "已经断开。")) : (false, String(localized: "没断开：\(Self.tail(r.output))"))
        case .openclaw:
            let r = await Self.shell("openclaw mcp unset beanpod")
            notes[a] = r.ok ? (true, String(localized: "已经断开。")) : (false, String(localized: "没断开：\(Self.tail(r.output))"))
        case .claudeDesktop:
            notes[a] = editDesktopConfig { $0["beanpod"] = nil } ? (true, String(localized: "已经断开。重开 Claude 之后生效。")) : (false, String(localized: "没能改 Claude 的设置文件。"))
        case .grok:
            notes[a] = (true, String(localized: "到 Grok Bot 的设置里把豆仓那一条删掉就行。"))
        }
        await refresh()
    }

    /// 试一下：豆仓这边的入口通不通；Claude Code 还能问它自己连上没有。
    func test(_ a: Assistant, store: BeanStore) async {
        busy.insert(a); defer { busy.remove(a) }
        // 像助手那样给豆仓发一次握手，再要一次工具清单
        let hello = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"beanpod-test","version":"1"}}}"#
        let list = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
        let ours = await Self.shell("printf '%s\\n%s\\n' '\(hello)' '\(list)' | '\(Self.cli)' mcp")
        let tools = ours.output.components(separatedBy: "\"name\"").count - 1
        guard ours.ok, ours.output.contains("search_recordings") else {
            notes[a] = (false, String(localized: "豆仓这边的入口没有应答。"))
            return
        }
        switch a {
        case .claudeCode:
            let r = await Self.shell("claude mcp get beanpod")
            notes[a] = r.output.contains("Connected") ? (true, String(localized: "通了：Claude Code 报告已连接，豆仓给了它 \(max(tools - 1, 1)) 个可用的动作。"))
                : (false, String(localized: "豆仓这边正常，但 Claude Code 说没连上：\(Self.tail(r.output))"))
        case .grok:
            guard store.settings.httpMCPEnabled else {
                notes[a] = (false, String(localized: "本机网址入口还没开启。请先打开下方「本机网址入口」开关，再试一次。"))
                return
            }
            if !store.mcpServerRunning { store.startMCPServer() }
            let token = store.mcpToken(createIfMissing: false)
            guard !token.isEmpty, let url = URL(string: BeanStore.mcpAddress) else {
                notes[a] = (false, String(localized: "本机访问令牌还没就绪，请尝试重置令牌后再试。"))
                return
            }
            var req = URLRequest(url: url, timeoutInterval: 4)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = Data(list.utf8)
            let ok: Bool
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               String(decoding: data, as: UTF8.self).contains("search_recordings") {
                ok = true
            } else {
                ok = false
            }
            notes[a] = ok ? (true, String(localized: "豆仓的网址入口是通的（已通过令牌校验）。Grok Bot 那边有没有填对，要在它里面问一句才知道。"))
                : (false, String(localized: "豆仓的网址入口没应答，可以试一下关掉再重开开关。"))
        default:
            notes[a] = (true, String(localized: "豆仓这边的入口是通的。\(a.name) 那边要新开一个会话问一句才算真的验证。"))
        }
    }

    /// 改 Claude 桌面版的设置：先备份，再只动 mcpServers 里豆仓那一条，别的原样留着。
    private func editDesktopConfig(_ change: (inout [String: Any]) -> Void) -> Bool {
        let url = Self.desktopConfig
        var root = Self.json(url) ?? [:]
        if FileManager.default.fileExists(atPath: url.path) {
            let backup = url.deletingLastPathComponent().appendingPathComponent("claude_desktop_config.backup-by-beanpod.json")
            try? FileManager.default.removeItem(at: backup)
            guard (try? FileManager.default.copyItem(at: url, to: backup)) != nil else { return false }
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        change(&servers)
        root["mcpServers"] = servers.isEmpty ? nil : servers
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    private static func tail(_ output: String) -> String {
        let line = output.split(separator: "\n").last.map(String.init) ?? String(localized: "没有给出原因")
        return String(line.prefix(120))
    }
}

/// 「连接 AI 助手」页面：每个助手一张卡，看得出装没装、连没连，点一下就连。
struct ConnectView: View {
    @Environment(BeanStore.self) private var store
    @Environment(Connector.self) private var connector

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    MascotView(mood: connector.connectedCount > 0 ? .happy : .idle, power: .mid).frame(width: 92, height: 92).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("连接 AI 助手").font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("接上之后，在你常用的 AI 助手里就能直接问豆仓里的录音、纪要和待办，也能让它们把内容存进豆仓。")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !connector.cliInstalled {
                    HStack(spacing: 12) {
                        Label("豆仓的命令行工具还没装好（应该在 ~/.local/bin/beanpod），下面的连接暂时都用不了。", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.accent).frame(maxWidth: .infinity, alignment: .leading)
                        if BeanStore.bundledCLI != nil {
                            Button("装上") {
                                if store.installCLI() { Task { await connector.refresh() } }
                                else { store.toast("exclamationmark.triangle", String(localized: "没装上，详情看日志")) }
                            }
                            .buttonStyle(.glassProminent).fixedSize()
                        }
                    }
                    .padding(12).panel(radius: Theme.Radius.card)
                }

                ForEach(Assistant.allCases) { card($0) }

                Text("创作工具").font(.system(size: 20, weight: .semibold, design: .rounded)).padding(.top, 8)
                RenoiseCard()

                VStack(alignment: .leading, spacing: 8) {
                    Text("别的工具").font(.headline)
                    Text("支持 MCP 的工具都能接。能运行命令的填（推荐）：").font(.callout).foregroundStyle(.secondary)
                    copyRow(BeanStore.cliPath + " mcp")
                    Toggle("本机网址入口（HTTP MCP，默认关闭）：", isOn: Binding(
                        get: { store.settings.httpMCPEnabled },
                        set: { store.setHTTPMCPEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .font(.callout)
                    .padding(.top, 4)
                    if store.settings.httpMCPEnabled {
                        HStack(spacing: 8) {
                            Text(store.mcpMaskedAddress).font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("拷贝含令牌地址") {
                                if let addr = store.mcpAuthenticatedAddress() {
                                    copy(addr)
                                    store.toast("doc.on.doc", String(localized: "已拷贝含令牌地址"))
                                } else {
                                    store.toast("exclamationmark.triangle", String(localized: "获取本机令牌失败"))
                                }
                            }
                            Button("重置令牌") {
                                if store.rotateMCPToken() {
                                    store.toast("key.fill", String(localized: "令牌已重置，旧地址已失效"))
                                } else {
                                    store.toast("exclamationmark.triangle", String(localized: "重置令牌失败"))
                                }
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: Theme.Radius.card))
                    } else {
                        Text("为防止本机浏览器网页越权访问，网址入口默认关闭；仅当 Grok Bot 等只认网址的工具需要时再开启。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("两个入口都只在这台 Mac 上有效，HTTP 入口只监听 127.0.0.1 并要求访问令牌。助手拿到内容之后怎么处理，取决于那个助手自己。")
                        .font(.caption).foregroundStyle(.tertiary).padding(.top, 2)
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading).panel()
            }
            .padding(24)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .background(Backdrop())
        .task { await connector.refresh() }
        .preferredColorScheme(store.settings.appearance.scheme)
        .tint(Theme.accent)
    }

    private func copyRow(_ text: String) -> some View {
        HStack {
            Text(text).font(.callout.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("拷贝") { copy(text); store.toast("doc.on.doc", String(localized: "已拷贝")) }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: Theme.Radius.card))
    }

    private func card(_ a: Assistant) -> some View {
        let state = connector.states[a] ?? .init()
        let busy = connector.busy.contains(a)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: a.icon).font(.system(size: 17, weight: .medium))
                    .foregroundStyle(state.installed ? Theme.accent : Color.secondary)
                    .frame(width: 40, height: 40)
                    .background((state.installed ? Theme.accent : Color.secondary).opacity(0.14), in: .rect(cornerRadius: Theme.Radius.card))
                VStack(alignment: .leading, spacing: 3) {
                    Text(a.name).font(.title3.weight(.semibold))
                    HStack(spacing: 6) {
                        Circle().fill(dot(state)).frame(width: 7, height: 7)
                        Text(status(state)).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                if state.installed {
                    if state.connected == true {
                        Button("试一下") { Task { await connector.test(a, store: store) } }.disabled(busy)
                        Button("断开") { Task { await connector.disconnect(a) } }.disabled(busy)
                    } else {
                        if a == .grok { Button("试一下") { Task { await connector.test(a, store: store) } }.disabled(busy) }
                        Button(a == .grok ? "拷贝地址并打开" : "连接") { Task { await connector.connect(a, store: store) } }
                            .buttonStyle(.glassProminent).disabled(busy || !connector.cliInstalled)
                    }
                }
            }
            .controlSize(.large)

            if state.installed {
                if let note = connector.notes[a] {
                    Label(note.text, systemImage: note.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.callout).foregroundStyle(note.ok ? Theme.ok : Theme.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if state.connected == true || a == .grok {
                    Text(a.example).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text(a.touches).font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
        .opacity(state.installed ? 1 : 0.55)
        .accessibilityElement(children: .contain)
    }

    private func status(_ s: Connector.State) -> String {
        if !s.installed { return String(localized: "这台 Mac 上没检测到") }
        switch s.connected {
        case .some(true): return String(localized: "已连接")
        case .some(false): return String(localized: "还没连接")
        case .none: return String(localized: "已安装 · 连没连上豆仓看不出来")
        }
    }

    private func dot(_ s: Connector.State) -> Color {
        guard s.installed else { return .secondary.opacity(0.4) }
        return s.connected == true ? Theme.ok : s.connected == nil ? Theme.accent : .secondary.opacity(0.5)
    }
}
