import BeanKit
import SwiftUI

/// 设置窗口。分成五个页签，每页一屏放完：以前是一条很长的表单，找一个选项要滚半天，
/// 而且把「llama-server」这种只有开发者认识的词直接摆在用户面前。
struct SettingsView: View {
    enum Pane: String { case general, dictation, models, vocabulary, connect }

    @Environment(BeanStore.self) private var store
    @AppStorage("settingsPane") private var pane = Pane.general

    var body: some View {
        TabView(selection: $pane) {
            Tab("通用", systemImage: "gearshape", value: Pane.general) { GeneralPane() }
            Tab("语音输入", systemImage: "mic", value: Pane.dictation) { DictationPane() }
            Tab("模型", systemImage: "cpu", value: Pane.models) { ModelsPane() }
            Tab("词库", systemImage: "character.book.closed", value: Pane.vocabulary) { VocabularyPane() }
            Tab("连接", systemImage: "link", value: Pane.connect) { ConnectPane() }
        }
        .preferredColorScheme(store.settings.appearance.scheme)
        .onAppear { store.refreshASRAvailability() }
    }
}

/// 「去设置」按钮：直接打开设置里的模型页。全应用里叫用户去设置的地方，缺的都是模型。
struct ModelSettingsLink: View {
    @Environment(\.openSettings) private var openSettings
    var title = String(localized: "去设置")

    var body: some View {
        Button(title) { SettingsView.open(.models, with: openSettings) }
    }
}

extension SettingsView {
    static func open(_ pane: Pane, with openSettings: OpenSettingsAction) {
        UserDefaults.standard.set(pane.rawValue, forKey: "settingsPane")
        openSettings()
    }
}

// MARK: 搭页面用的零件

/// 一页设置的外框：固定宽度，高度跟着内容走，窗口会自己变高变矮。
/// 每个页签的外框：窗口高度跟着内容走，但不超过屏幕；内容更高时在里面滚动（模型页就比一屏高）。
private struct PaneFrame<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var contentHeight: CGFloat = 0

    /// 留出菜单栏、标题栏、页签和程序坞的位置。
    private var maxHeight: CGFloat { max(360, min((NSScreen.main?.visibleFrame.height ?? 900) - 150, 860)) }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 22) { content }
                .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 26)
                .frame(width: 640)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 640, height: contentHeight > 0 ? min(contentHeight, maxHeight) : nil)
        .background(Backdrop())
    }
}

/// 一组设置：小标题、一张卡片、卡片下面的说明。卡片里每一行之间自动加分隔线。
struct SettingsGroup<Content: View, Accessory: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if title != nil || Accessory.self != EmptyView.self {
                HStack(spacing: 8) {
                    if let title { Text(title).font(.headline) }
                    Spacer(minLength: 0)
                    accessory
                }
                .padding(.horizontal, 4)
            }
            VStack(spacing: 0) {
                Group(subviews: content) { subviews in
                    ForEach(subviews) { sub in
                        sub.padding(.horizontal, 16).padding(.vertical, 11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if sub.id != subviews.last?.id { Divider().padding(.leading, 16) }
                    }
                }
            }
            .panel(radius: Theme.Radius.panel)
            if let footer {
                Text(footer).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            }
        }
    }
}

extension SettingsGroup where Accessory == EmptyView {
    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, footer: footer, accessory: { EmptyView() }, content: content)
    }
}

/// 一行设置：左边可选的小图标、标题和一行说明，右边是控件。
struct SettingRow<Trailing: View>: View {
    var icon: String?
    var title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let icon {
                Image(systemName: icon).font(.system(size: 17, weight: .regular)).foregroundStyle(.secondary)
                    .frame(width: 26)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

/// 「已就绪」「还差一步」这种状态小牌子。
private struct StatusPill: View {
    var ok: Bool
    var text: String

    var body: some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .font(.callout.weight(.medium))
            .foregroundStyle(ok ? Theme.ok : Theme.amber)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background((ok ? Theme.ok : Theme.amber).opacity(0.14), in: .capsule)
    }
}

// MARK: 通用

private struct GeneralPane: View {
    @Environment(BeanStore.self) private var store

    var body: some View {
        @Bindable var settings = store.settings
        PaneFrame {
            SettingsGroup(String(localized: "外观")) {
                HStack(spacing: 12) {
                    ForEach(AppSettings.Appearance.allCases) { mode in
                        AppearanceTile(mode: mode, selected: settings.appearance == mode) { settings.appearance = mode }
                    }
                }
                .padding(.vertical, 5)
            }

            LanguageSetting()

            SettingsGroup(String(localized: "我是做什么的"), footer: String(localized: "职业决定整理纪要时更看重什么。场景（会议、访谈、销售……）是每条录音自动判断的，判断错了可以在录音页面改。")) {
                SettingRow(icon: "person.crop.circle", title: String(localized: "我的职业"), detail: settings.profession.focus) {
                    Picker("我的职业", selection: $settings.profession) {
                        ForEach(Profession.allCases) { Text($0.name).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }

            SettingsGroup(String(localized: "视频素材")) {
                VideoKeepSettings().padding(.vertical, 6)
            }

            SettingsGroup(String(localized: "录音的时候和录完之后")) {
                SettingRow(icon: "captions.bubble", title: String(localized: "边录边出字"), detail: String(localized: "录音时在舞台上实时显示文字。")) {
                    Toggle("边录边出字", isOn: $settings.liveTranscribe).labelsHidden().toggleStyle(.switch)
                }
                SettingRow(icon: "doc.on.clipboard", title: String(localized: "识别剪贴板里的视频链接"), detail: String(localized: "复制了抖音、B 站、YouTube 这些链接，切回豆仓时提示一键导入。只看链接，不存剪贴板内容。")) {
                    Toggle("识别剪贴板里的视频链接", isOn: $settings.watchClipboard).labelsHidden().toggleStyle(.switch)
                }
                SettingRow(icon: "questionmark.bubble", title: String(localized: "录完先问一句留不留"), detail: String(localized: "录完弹一张小卡片，不要的话当场删掉，哪里都不留。十秒不理它就默认留着。")) {
                    Toggle("录完先问一句留不留", isOn: $settings.askKeep).labelsHidden().toggleStyle(.switch)
                }
                SettingRow(icon: "arrow.down.circle", title: String(localized: "自动从录音豆下载"), detail: String(localized: "录完一条、或者重新连上录音豆时，把还没下载的拉到这台 Mac 上。")) {
                    Toggle("自动从录音豆下载", isOn: $settings.autoDownload).labelsHidden().toggleStyle(.switch)
                }
                SettingRow(icon: "wand.and.sparkles", title: String(localized: "自动转写并整理"), detail: String(localized: "下载后直接出文字稿、纪要和待办。")) {
                    Toggle("自动转写并整理", isOn: $settings.autoProcess).labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }
}

/// 外观的一个选项：一张小窗口缩略图加名字，选中的有琥珀色描边。
private struct AppearanceTile: View {
    var mode: AppSettings.Appearance
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                preview
                    .frame(height: 74)
                    .clipShape(.rect(cornerRadius: Theme.Radius.card))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
                HStack(spacing: 5) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
                    Text(mode.name).fontWeight(selected ? .semibold : .regular)
                }
                .font(.callout)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(.background.opacity(selected ? 0.9 : 0.4), in: .rect(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.separator), lineWidth: selected ? 2 : 0.5))
            .contentShape(.rect(cornerRadius: Theme.Radius.card))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var preview: some View {
        switch mode {
        case .light: MiniWindow(dark: false)
        case .dark: MiniWindow(dark: true)
        case .system:
            // 左半浅、右半深：跟着系统走
            ZStack {
                MiniWindow(dark: false)
                MiniWindow(dark: true).mask(alignment: .trailing) {
                    GeometryReader { geo in Rectangle().frame(width: geo.size.width / 2).frame(maxWidth: .infinity, alignment: .trailing) }
                }
            }
        }
    }
}

/// 豆仓窗口的缩略图：左边侧栏、红色录音键、右边几条内容。
private struct MiniWindow: View {
    var dark: Bool

    var body: some View {
        let ink = dark ? Color.white : Color.black
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(Theme.rec).frame(width: 30, height: 7)
                ForEach(0..<3, id: \.self) { _ in Capsule().fill(ink.opacity(0.22)).frame(width: 24, height: 4) }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxHeight: .infinity)
            .background(ink.opacity(0.06))
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(ink.opacity(0.75)).frame(width: 52, height: 6)
                RoundedRectangle(cornerRadius: 4).fill(ink.opacity(0.1)).frame(height: 16)
                RoundedRectangle(cornerRadius: 4).fill(Theme.accent.opacity(0.55)).frame(width: 60, height: 16)
                Spacer(minLength: 0)
            }
            .padding(9)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(dark ? Theme.graphite : Theme.paper)
    }
}

// MARK: 语音输入

private struct DictationPane: View {
    @Environment(BeanStore.self) private var store
    @Environment(Dictation.self) private var dictation
    @State private var trusted = AXIsProcessTrusted()

    var body: some View {
        @Bindable var settings = store.settings
        let on = settings.dictationEnabled
        PaneFrame {
            SettingsGroup(footer: String(localized: "把录音豆当随身麦克风：在任何 App 里按住你选的那个键，对着录音豆说话，松开后文字出现在光标处。")) {
                SettingRow(icon: "mic.fill", title: String(localized: "按住按键说话，松开输入文字"), detail: on ? String(localized: "已打开。按住「\(Dictation.name(of: settings.dictationKey))」试试。") : String(localized: "关着的时候，豆仓不会监听任何按键。")) {
                    Toggle("语音输入", isOn: Binding(get: { settings.dictationEnabled }, set: {
                        settings.dictationEnabled = $0
                        dictation.refresh()
                        if $0, !AXIsProcessTrusted() { dictation.requestAccessibility() }
                    }))
                    .labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsGroup(String(localized: "怎么用")) {
                SettingRow(icon: "keyboard", title: String(localized: "按住这个键"), detail: dictation.recordingKey ? String(localized: "现在按下你想用的那个键…") : nil) {
                    Picker("按住这个键", selection: $settings.dictationKey) {
                        ForEach(Dictation.keys, id: \.code) { Text($0.name).tag($0.code) }
                        if !Dictation.keys.contains(where: { $0.code == settings.dictationKey }) {
                            Text(Dictation.name(of: settings.dictationKey)).tag(settings.dictationKey)
                        }
                    }
                    .labelsHidden().fixedSize()
                    Button(dictation.recordingKey ? "取消" : "换一个键…") {
                        dictation.recordingKey.toggle()
                        dictation.refresh()
                    }
                    .help("点一下，然后按下你想用的修饰键")
                }
                SettingRow(icon: "text.badge.checkmark", title: String(localized: "把口语理顺再输入"), detail: String(localized: "去掉嗯啊和重复，句子更通顺。要多等几秒。")) {
                    Toggle("把口语理顺再输入", isOn: $settings.dictationPolish).labelsHidden().toggleStyle(.switch)
                }
                SettingRow(icon: "keyboard", title: String(localized: "记下说过的话"), detail: String(localized: "打字的同时，把这句话记进侧栏的「语音输入」（声音 + 文字），能回听、拷贝、搜索。不进录音列表，也不做 AI 整理。")) {
                    Toggle("记下说过的话", isOn: $settings.dictationSave).labelsHidden().toggleStyle(.switch)
                }
                SettingRow(icon: "waveform.badge.minus", title: String(localized: "原声保留"), detail: String(localized: "到期只删声音，文字一直留着。")) {
                    Picker("原声保留", selection: $settings.dictationAudioDays) {
                        Text("7 天").tag(7); Text("30 天").tag(30); Text("90 天").tag(90); Text("一直留着").tag(0)
                    }
                    .labelsHidden().fixedSize()
                }
                .disabled(!settings.dictationSave)
                SettingRow(icon: "books.vertical", title: String(localized: "知识库里也搜"), detail: String(localized: "问知识库、AI 助手查询时，把语音输入说过的话也算进去。默认不算，免得零碎的话干扰回答。")) {
                    Toggle("知识库里也搜", isOn: $settings.dictationInKnowledge).labelsHidden().toggleStyle(.switch)
                }
                .disabled(!settings.dictationSave)
                SettingRow(icon: "play.circle", title: String(localized: "先试一次"), detail: String(localized: "录 5 秒，只显示识别结果，不会打进别的 App。")) {
                    Button("试一次") { dictation.tryOnce() }
                }
            }
            .disabled(!on)
            .opacity(on ? 1 : 0.5)

            SettingsGroup(String(localized: "权限"), footer: String(localized: "豆仓要靠「辅助功能」权限来听到这个按键、把文字打进其他 App。没有权限时，文字只会放进剪贴板。")) {
                SettingRow(icon: "hand.raised", title: String(localized: "辅助功能")) {
                    if trusted {
                        StatusPill(ok: true, text: String(localized: "已允许"))
                    } else {
                        StatusPill(ok: false, text: String(localized: "未允许"))
                        Button("去授权") { dictation.requestAccessibility() }
                        Button("重新检查") { trusted = AXIsProcessTrusted(); dictation.refresh() }
                    }
                }
            }
        }
        .onAppear { trusted = AXIsProcessTrusted() }
    }
}

// MARK: 模型

/// 模型页的一张大卡片：卡片里面顶上是图标、标题和状态牌子。
private struct ModelCard<Content: View>: View {
    var icon: String
    var title: String
    var ok: Bool
    var status: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 20)).foregroundStyle(.secondary).frame(width: 26).accessibilityHidden(true)
                Text(title).font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                StatusPill(ok: ok, text: status)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(radius: Theme.Radius.panel)
    }
}

private struct ModelsPane: View {
    @Environment(BeanStore.self) private var store
    @State private var advanced = false
    @State private var cloudSheet = false
    @State private var asrSheet = false
    @State private var testNote: String?
    @State private var testing = false
    @State private var lightExpanded = false

    var body: some View {
        @Bindable var settings = store.settings
        let server = QwenASR.locateServer(custom: settings.llamaServerPath)
        let asrOK: Bool = switch settings.engine {
        case .qwen: store.asrAvailable
        case .apple: true
        case .cloud: settings.asrConfig != nil
        }
        PaneFrame {
            // 设计稿 design/ui/ui_models2.png
            ModelCard(icon: "cpu", title: String(localized: "本机运行环境"), ok: server != nil, status: server != nil ? String(localized: "已就绪") : String(localized: "需要安装")) {
                line(String(localized: "推理程序 llama.cpp")) {
                    if let note = store.serverInstall {
                        ProgressView().controlSize(.small)
                        Text(note).foregroundStyle(.secondary)
                    } else if let server {
                        Text(server.path.hasPrefix("/Applications/") ? String(localized: "借用 \(server.pathComponents.dropFirst(2).first ?? String(localized: "其他 App"))") : String(localized: "已安装"))
                            .foregroundStyle(.secondary)
                        Button("重新检查") { store.refreshASRAvailability() }
                    } else {
                        Text("没找到").foregroundStyle(.secondary)
                        if BeanStore.brewPath != nil {
                            Button("安装") { store.installLlamaServer() }.buttonStyle(.glassProminent).tint(Theme.accent)
                        } else {
                            Link("怎么安装", destination: URL(string: "https://github.com/ggml-org/llama.cpp#quick-start")!)
                        }
                    }
                }
                Text(serverHint(server)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("高级", isExpanded: $advanced) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(server?.path ?? String(localized: "没找到")).font(.callout.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        TextField("自己指定 llama-server 的位置（可不填）", text: $settings.llamaServerPath).textFieldStyle(.roundedBorder)
                            .onSubmit { store.refreshASRAvailability() }
                    }
                    .padding(.top, 8)
                }
            }

            ModelCard(icon: "waveform", title: String(localized: "转写：把声音变成文字"), ok: asrOK, status: asrOK ? String(localized: "已就绪") : String(localized: "还差一步")) {
                line(String(localized: "引擎")) {
                    Picker("引擎", selection: $settings.engine) {
                        Text("本机 Qwen3‑ASR").tag(AppSettings.Engine.qwen)
                        Text("系统识别").tag(AppSettings.Engine.apple)
                        Text("云端").tag(AppSettings.Engine.cloud)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                switch settings.engine {
                case .qwen:
                    line(String(localized: "模型")) { downloadView(store.asrJob, ready: QwenASR.locateModel() != nil,
                                               readyText: String(localized: "\(QwenASR.displayName) · 已下载 · 1.0 GB"), size: String(localized: "约 1 GB")) { store.downloadASRModel() } }
                    Text(store.asrAvailable ? "在这台 Mac 上运行，录音不会上传。" : "还没准备好之前，暂时用系统语音识别顶上。")
                        .font(.callout).foregroundStyle(store.asrAvailable ? Color.secondary : Theme.amber)
                case .apple:
                    line(String(localized: "语言")) {
                        Picker("语言", selection: $settings.language) {
                            ForEach(Transcriber.languages, id: \.id) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    Text("用 macOS 自带的语音识别，在这台 Mac 上运行。").font(.callout).foregroundStyle(.secondary)
                case .cloud:
                    Text(settings.asrConfig == nil ? "还没设置云端转写服务，先点下面的「设置…」。" : "录音会发给你设置的云端服务转写。")
                        .font(.callout).foregroundStyle(settings.asrConfig == nil ? Theme.amber : Color.secondary)
                }
                Divider()
                line(settings.engine == .cloud ? String(localized: "云端转写服务") : String(localized: "云端重转")) {
                    Text(asrSummary).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button(settings.asrConfig == nil ? "设置…" : "更改…") { asrSheet = true }
                }
                if settings.engine != .cloud {
                    Text("本机转得不准的录音，可以在录音页的「⋯」菜单里按需交给云端再转一遍。").font(.callout).foregroundStyle(.secondary)
                }
            }

            ModelCard(icon: "doc.text", title: String(localized: "整理：写纪要、回答提问"), ok: store.analysisAvailable, status: store.analysisAvailable ? String(localized: "已就绪") : String(localized: "还没选模型")) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("用哪边的模型", selection: $settings.analysisMode) {
                        Text("云端优先").tag(AppSettings.AnalysisMode.auto)
                        Text("只用云端").tag(AppSettings.AnalysisMode.cloud)
                        Text("只用本机").tag(AppSettings.AnalysisMode.local)
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.large)
                    Text(modeHint(settings.analysisMode)).font(.callout).foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 18) {
                    half(String(localized: "本机模型"), dim: settings.analysisMode == .cloud) {
                        if let job = store.llmJob {
                            jobDetail(job, title: "Qwen3‑4B")
                        } else if store.localLLMReady || LocalLLM.modelURL != nil {
                            Text(LocalLLM.modelLabel).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                            Button("打开模型文件夹", action: openFolder)
                        } else {
                            Text("Qwen3‑4B · 还没下载").font(.body.weight(.medium))
                            HStack {
                                Button("下载（约 2.5 GB）") { store.downloadLocalLLM() }
                                Button("打开模型文件夹", action: openFolder)
                            }
                        }
                    }
                    Divider()
                    half(String(localized: "云端服务"), dim: settings.analysisMode == .local) {
                        Text(cloudSummary).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        if let light = settings.lightCloudEndpoint {
                            Text("轻量：\(light.model)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        HStack {
                            Button(settings.llmConfigured ? "更改…" : "设置…") { cloudSheet = true }
                            if settings.llmConfigured {
                                Button("测试") { test() }.disabled(testing)
                                if testing { ProgressView().controlSize(.small) }
                            }
                        }
                        if let testNote { Text(testNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("逐句润色").font(.body.weight(.medium))
                    Picker("逐句润色", selection: $settings.polishMode) {
                        Text("规则去语气词（免费）").tag(LLMPolishMode.rules)
                        Text("AI 逐句润色").tag(LLMPolishMode.llm)
                        Text("关闭").tag(LLMPolishMode.off)
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.large)
                    Text(polishHint(settings.polishMode))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("自动模式下优先用本机 Qwen3‑4B 处理轻量任务", isOn: $settings.lightUseLocalFirst)
                        .disabled(settings.analysisMode != .auto)
                    Text("分块摘要（长录音）、逐句润色、重起标题、语音输入润色默认先走本机或下方轻量模型，不直接烧主模型。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup(isExpanded: $lightExpanded) {
                        VStack(alignment: .leading, spacing: 10) {
                            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                                GridRow {
                                    Text("模型名")
                                    TextField("模型名", text: $settings.lightLLMModel, prompt: Text("如 gpt-4o-mini / qwen-turbo / deepseek-chat"))
                                        .textFieldStyle(.roundedBorder)
                                }
                                GridRow {
                                    Text("接口地址")
                                    TextField("接口地址", text: $settings.lightLLMBaseURL, prompt: Text("留空则继承主云端服务"))
                                        .textFieldStyle(.roundedBorder)
                                }
                                GridRow {
                                    Text("密钥")
                                    SecureField("API Key（留空则继承同域主密钥）", text: $settings.lightLLMKey)
                                        .textFieldStyle(.roundedBorder)
                                }
                            }
                            HStack {
                                Text(lightSummary)
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                if settings.lightLLMConfigured || !settings.lightLLMBaseURL.isEmpty || !settings.lightLLMKey.isEmpty {
                                    Button("清空轻量配置") {
                                        settings.lightLLMModel = ""
                                        settings.lightLLMBaseURL = ""
                                        settings.lightLLMKey = ""
                                    }
                                }
                            }
                        }
                        .padding(12)
                        .panel(radius: Theme.Radius.card)
                    } label: {
                        HStack {
                            Text("轻量模型（可选）").font(.body.weight(.medium))
                            Spacer()
                            Text(settings.lightCloudEndpoint?.model ?? String(localized: "未单独设置"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("下载断了会从断点接着下；HuggingFace 太慢时自动换国内镜像，下完按 SHA‑256 校验。本机模型不联网；云端纪要质量更高，但文字稿会发给服务商，录音本身不会。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            ModelCard(icon: "character.bubble", title: String(localized: "翻译：把外语译成你要的语言"), ok: store.analysisAvailable, status: store.analysisAvailable ? String(localized: "用整理的模型") : String(localized: "还没选模型")) {
                line(String(localized: "译成")) {
                    Picker("译成", selection: $settings.translateTo) {
                        ForEach(translateLanguages, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                Divider()
                line(String(localized: "默认风格")) {
                    Picker("默认风格", selection: $settings.translateStyle) {
                        ForEach(TranslateStyle.allCases) { Text($0.name).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                Text(settings.translateStyle.hint).font(.callout).foregroundStyle(.secondary)
                if settings.translateStyle == .custom {
                    TextField("自定义提示词，比如：译成小红书风格，口语化，每段不超过三句", text: $settings.translatePrompt, axis: .vertical)
                        .lineLimit(2...5).textFieldStyle(.roundedBorder)
                }
                Divider()
                Toggle("外语素材整理完自动翻译", isOn: $settings.autoTranslate).toggleStyle(.switch)
                Text("用的是上面整理纪要的那个模型（云端优先），按句翻译，原文和译文一句对一句。").font(.callout).foregroundStyle(.secondary)
            }
            let usage = store.usageSummary
            ModelCard(
                icon: "chart.bar",
                title: String(localized: "AI 用量统计"),
                ok: true,
                status: usage.totalCalls > 0 ? String(localized: "已记录 \(usage.totalCalls) 次") : String(localized: "暂无调用")
            ) {
                HStack(spacing: 12) {
                    usageMetricBox(
                        title: String(localized: "今日"),
                        value: LLMUsageLedger.formatTokens(usage.todayTokens),
                        detail: String(localized: "云端 \(LLMUsageLedger.formatTokens(usage.todayCloudTokens))")
                    )
                    usageMetricBox(
                        title: String(localized: "近 30 天"),
                        value: LLMUsageLedger.formatTokens(usage.last30DaysTokens),
                        detail: String(localized: "云端 \(LLMUsageLedger.formatTokens(usage.last30DaysCloudTokens))")
                    )
                    usageMetricBox(
                        title: String(localized: "累计"),
                        value: LLMUsageLedger.formatTokens(usage.totalTokens),
                        detail: String(localized: "云端 \(LLMUsageLedger.formatTokens(usage.cloudTokens)) · 本机 \(LLMUsageLedger.formatTokens(usage.localTokens))")
                    )
                }
                if !usage.byTask.isEmpty {
                    let taskItems = usage.byTask
                        .sorted { $0.value == $1.value ? $0.key.rawValue < $1.key.rawValue : $0.value > $1.value }
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("按环节分布").font(.callout.weight(.medium))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], alignment: .leading, spacing: 6) {
                            ForEach(taskItems, id: \.key) { item in
                                HStack {
                                    Text(taskLabel(item.key)).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(LLMUsageLedger.formatTokens(item.value)).monospacedDigit()
                                }
                                .font(.caption)
                            }
                        }
                    }
                }
                if !usage.byModel.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("按模型明细").font(.callout.weight(.medium))
                        ForEach(usage.byModel) { row in
                            HStack(spacing: 8) {
                                Text(row.model).lineLimit(1).truncationMode(.middle)
                                Text(row.builtInLocal ? "本机" : row.providerHost)
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.quaternary.opacity(0.4), in: .capsule)
                                Spacer()
                                Text("\(row.calls) 次").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                Text("\(LLMUsageLedger.formatTokens(row.totalTokens)) tokens")
                                    .font(.caption.weight(.medium)).monospacedDigit()
                            }
                            .font(.callout)
                        }
                    }
                }
                HStack {
                    Text("仅在本机记录 token 统计与接口域名，不保存接口密钥或文本内容（最多保留 5,000 条）。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("清空统计") { store.clearUsageLedger() }
                        .disabled(store.usageEntries.isEmpty)
                }
            }
        }
        .sheet(isPresented: $cloudSheet) { CloudServiceSheet() }
        .sheet(isPresented: $asrSheet) { CloudASRSheet() }
        .onAppear { store.restorePausedDownloads(); store.refreshASRAvailability() }
    }

    private var lightSummary: String {
        if let endpoint = store.settings.lightCloudEndpoint {
            return String(localized: "当前将走 \(endpoint.providerHost) · \(endpoint.model)")
        }
        if store.settings.lightLLMConfigured {
            return String(localized: "请先设置主云端接口地址，或在这里填写轻量接口地址")
        }
        return String(localized: "未单独设置时，需要云端调用的轻量任务将回落到主云端模型")
    }

    private func polishHint(_ mode: LLMPolishMode) -> String {
        switch mode {
        case .rules: String(localized: "默认用本地规则去掉「呃、嗯、就是」等口头禅，零 token 开销；需要时可在单条录音「更多」里点「用 AI 润色文字稿」。")
        case .llm: String(localized: "每次整理纪要后自动调用轻量模型逐句润色文字稿，保留原句并替换口头禅。")
        case .off: String(localized: "不做自动润色，保留原始转写分句。")
        }
    }

    private func taskLabel(_ task: LLMTaskKind) -> String {
        switch task {
        case .analyzeChunk: String(localized: "长文分块")
        case .analyzeFinal: String(localized: "纪要整理")
        case .polish: String(localized: "逐句润色")
        case .retitle: String(localized: "重起标题")
        case .dictation: String(localized: "语音输入")
        case .rewrite: String(localized: "改写")
        case .ask: String(localized: "知识库提问")
        case .translate: String(localized: "翻译")
        case .study: String(localized: "英语学习")
        }
    }

    private func usageMetricBox(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .panel(radius: Theme.Radius.card)
    }

    private func serverHint(_ server: URL?) -> String {
        if store.serverInstall != nil { return String(localized: "正在用 Homebrew 安装 llama.cpp，大约 1 分钟，装好会自动检测。") }
        if let server, server.path.hasPrefix("/Applications/") {
            return String(localized: "本机转写和本机整理模型都靠它运行。现在借用的是别的 App 里带的那份，那个 App 删掉就用不了了；建议点「高级」看看位置，或者用 Homebrew 装一份（brew install llama.cpp）。")
        }
        if server != nil { return String(localized: "本机转写和本机整理模型都靠它运行。") }
        return BeanStore.brewPath != nil
            ? String(localized: "本机转写和本机整理模型都靠它运行。点「安装」会用 Homebrew 装，大约 1 分钟。")
            : String(localized: "本机转写和本机整理模型都靠它运行。这台 Mac 上没有 Homebrew，先按链接里的说明装好 llama.cpp。")
    }

    /// 模型下载那一格：没下 → 下载按钮；下载中 → 进度、来源、速度、暂停/取消；下好了 → 一行字。
    @ViewBuilder
    private func downloadView(_ job: DownloadJob?, ready: Bool, readyText: String, size: String, start: @escaping () -> Void) -> some View {
        if let job {
            VStack(alignment: .trailing, spacing: 6) { jobDetail(job, title: nil) }.frame(width: 300)
        } else if ready {
            Text(readyText).foregroundStyle(.secondary)
        } else {
            Button("下载（\(size)）", action: start)
        }
    }

    @ViewBuilder
    private func jobDetail(_ job: DownloadJob, title: String?) -> some View {
        let gb = { (b: Int64) in String(format: "%.1f", Double(b) / 1_000_000_000) }
        let head: String = switch job.state {
        case .running: String(localized: "正在下载 \(Int(job.fraction * 100))%")
        case .paused: String(localized: "已暂停 \(Int(job.fraction * 100))%")
        case .verifying: String(localized: "正在校验…")
        case .failed: String(localized: "没下完")
        }
        Text([title, head].compactMap { $0 }.joined(separator: " · ")).font(.body.weight(.medium)).monospacedDigit()
        ProgressView(value: job.fraction).tint(Theme.accent)
        if case .failed(let why) = job.state {
            Text(why).font(.caption).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
        } else {
            Text("\(gb(job.received)) / \(gb(job.total)) GB · \(job.source.name)" + (job.state == .running && job.speed > 0 ? String(format: " · %.1f MB/s", job.speed / 1_000_000) : ""))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        HStack {
            switch job.state {
            case .running: Button("暂停") { job.pause() }
            case .paused, .failed: Button("继续") { job.start() }
            case .verifying: EmptyView()
            }
            Button("取消") { job.cancel() }.disabled(job.state == .verifying)
        }
        .controlSize(.small)
    }

    private func test() {
        guard let config = store.cloudConfig else { return }
        testing = true; testNote = nil
        Task {
            defer { testing = false }
            testNote = await CloudServiceSheet.runTest(config, store: store).text
        }
    }

    private func line<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Text(title)
            Spacer(minLength: 12)
            trailing()
        }
    }

    private func half<Content: View>(_ title: String, dim: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(dim ? 0.45 : 1)
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: LocalLLM.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(LocalLLM.folder)
    }

    private func modeHint(_ mode: AppSettings.AnalysisMode) -> String {
        switch mode {
        case .auto: String(localized: "平时用云端，连不上的时候自动换成本机。")
        case .cloud: String(localized: "只用云端。连不上的时候不整理，等能连上再说。")
        case .local: String(localized: "只用本机。文字稿不会离开这台电脑。")
        }
    }

    private var cloudSummary: String {
        let s = store.settings
        guard s.llmConfigured else { return String(localized: "还没设置") }
        let name = AppSettings.presets.first { $0.url == s.llmBaseURL }?.name ?? String(localized: "自定义服务")
        return "\(name) · \(s.llmModel)"
    }

    private var asrSummary: String {
        let s = store.settings
        guard s.asrConfig != nil else { return String(localized: "未设置") }
        let name = CloudASR.presets.first { $0.url == s.asrBaseURL }?.name ?? String(localized: "自定义服务")
        return "\(name) · \(s.asrModel)"
    }
}

/// 云端整理服务（设计稿 design/ui/ui_cloud_providers.png）：选一家 → 地址自动填好 → 选模型、填密钥 → 测试。
private struct CloudServiceSheet: View {
    @Environment(BeanStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var models: [String] = []
    @State private var loadingModels = false
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?
    @State private var custom = false

    private var cloud: [AppSettings.Provider] { AppSettings.presets.filter { !$0.local } }
    private var local: [AppSettings.Provider] { AppSettings.presets.filter(\.local) }
    private var current: AppSettings.Provider? { AppSettings.presets.first { $0.url == store.settings.llmBaseURL } }

    var body: some View {
        @Bindable var settings = store.settings
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("云端服务").font(.title2.bold())
                Text("任何兼容 OpenAI 接口的服务都能用。密钥存在系统钥匙串里。").font(.callout).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                ForEach(cloud) { p in tile(p) }
            }
            HStack(spacing: 8) {
                ForEach(local) { p in chip(p.name, picked: settings.llmBaseURL == p.url) { pick(p) } }
                chip(String(localized: "自定义…"), picked: custom || (current == nil && !settings.llmBaseURL.isEmpty)) {
                    custom = true; settings.llmBaseURL = ""; settings.llmModel = ""; models = []; testResult = nil
                }
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("接口地址").gridColumnAlignment(.leading)
                    TextField("接口地址", text: $settings.llmBaseURL, prompt: Text("https://…/v1")).textFieldStyle(.roundedBorder)
                    Text(current != nil && !custom ? "已自动填好" : "").font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                }
                GridRow {
                    Text("模型")
                    HStack(spacing: 6) {
                        TextField("模型", text: $settings.llmModel, prompt: Text(models.isEmpty ? "填模型名，或点右边从列表里选" : "从右边的列表里选")).textFieldStyle(.roundedBorder)
                        Menu {
                            ForEach(models, id: \.self) { m in Button(m) { settings.llmModel = m } }
                            if models.isEmpty { Text(loadingModels ? "正在获取…" : "这个服务没给列表（可能要先填密钥）") }
                        } label: { Image(systemName: "chevron.down") }
                        .menuIndicator(.hidden).fixedSize().disabled(settings.llmBaseURL.isEmpty)
                    }
                    Button("刷新列表") { Task { await loadModels() } }.buttonStyle(.link).foregroundStyle(Theme.accent).disabled(settings.llmBaseURL.isEmpty)
                }
                if !settings.llmIsLocal {
                    GridRow {
                        Text("密钥")
                        SecureField("API Key", text: $settings.llmKey).textFieldStyle(.roundedBorder)
                        if let page = current?.keyPage, !page.isEmpty, let url = URL(string: page) {
                            Link("去获取密钥", destination: url).foregroundStyle(Theme.accent)
                        } else { Text("") }
                    }
                }
            }
            .padding(14).panel(radius: Theme.Radius.card)
            HStack(alignment: .center) {
                if let testResult {
                    Text(testResult.text).font(.callout).foregroundStyle(testResult.ok ? Theme.ok : Theme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if testing { ProgressView().controlSize(.small) }
                Button("测试一下") { test() }.disabled(!settings.llmConfigured || testing)
                Button("完成") { dismiss() }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 620)
        .task(id: settings.llmBaseURL + settings.llmKey) {
            guard !settings.llmBaseURL.isEmpty else { return }
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            await loadModels()
        }
    }

    private func pick(_ p: AppSettings.Provider) {
        let s = store.settings
        custom = false
        guard s.llmBaseURL != p.url else { return }
        s.llmBaseURL = p.url
        s.llmModel = p.model
        models = []; testResult = nil
    }

    private func tile(_ p: AppSettings.Provider) -> some View {
        let picked = store.settings.llmBaseURL == p.url && !custom
        return Button { pick(p) } label: {
            VStack(spacing: 8) {
                Text(p.badge).font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 34, height: 34).background(Color.secondary.opacity(0.14), in: .circle)
                Text(p.name).font(.callout.weight(.medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(Color(nsColor: .controlBackgroundColor).opacity(picked ? 1 : 0.6), in: .rect(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(picked ? Theme.accent : Color.secondary.opacity(0.22), lineWidth: picked ? 2 : 0.5))
            .overlay(alignment: .topTrailing) {
                if picked { Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Theme.accent).padding(5) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(picked ? String(localized: "\(p.name)，已选中") : p.name)
    }

    private func chip(_ title: String, picked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.callout).padding(.horizontal, 14).padding(.vertical, 6)
                .overlay(Capsule().strokeBorder(picked ? Theme.accent : Color.secondary.opacity(0.3), lineWidth: picked ? 1.5 : 0.5))
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }

    private func loadModels() async {
        loadingModels = true
        models = await Analyzer.listModels(baseURL: store.settings.llmBaseURL, key: store.settings.llmKey)
        loadingModels = false
    }

    private func test() {
        guard let config = store.cloudConfig else { return }
        testing = true; testResult = nil
        Task {
            defer { testing = false }
            testResult = await Self.runTest(config, store: store)
        }
    }

    /// 拿一段销售通话试整理，看判对场景没有。模型页的「测试」也用它。
    static func runTest(_ config: LLMConfig, store: BeanStore) async -> (ok: Bool, text: String) {
        let t0 = Date()
        do {
            let a = try await Analyzer.analyze(
                transcript: "王总您好，我是小李。这套系统年费三万八，含五个席位。您说预算三万以内，我申请到这个月签可以三万二，再送两个月服务。除了您还要财务张姐确认对吧？我周四把合同发您邮箱，周五再给您打电话。",
                duration: 40, profession: store.settings.profession, fixedScene: nil, config: config)
            store.upgradeRoughNotes()
            let secs = String(format: "%.1f", Date().timeIntervalSince(t0))
            return a.scene == .sales || a.scene == .call
                ? (ok: true, text: String(localized: "测试通过 · \(secs) 秒 · 把销售通话判成了「\(a.scene.name)」"))
                : (ok: false, text: String(localized: "能连上（\(secs) 秒），但把销售通话判成了「\(a.scene.name)」，这个模型可能偏弱。"))
        } catch {
            return (ok: false, text: error.localizedDescription)
        }
    }
}

/// 云端转写服务（Mac 上之前没有界面）：兼容 OpenAI「/audio/transcriptions」接口的服务。
private struct CloudASRSheet: View {
    @Environment(BeanStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var testing = false
    @State private var result: (ok: Bool, text: String)?

    var body: some View {
        @Bindable var settings = store.settings
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("云端转写").font(.title2.bold())
                Text("兼容 OpenAI「/audio/transcriptions」接口的服务都能用；小米 MiMo 走它自己的转写模型。用它转写时，录音会发给这家服务商。密钥存在系统钥匙串里。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                ForEach(CloudASR.presets, id: \.url) { p in
                    let picked = settings.asrBaseURL == p.url
                    Button {
                        settings.asrBaseURL = p.url; settings.asrModel = p.model; result = nil
                    } label: {
                        Text(p.name).font(.callout).padding(.horizontal, 14).padding(.vertical, 6)
                            .overlay(Capsule().strokeBorder(picked ? Theme.accent : Color.secondary.opacity(0.3), lineWidth: picked ? 1.5 : 0.5))
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("接口地址")
                    TextField("接口地址", text: $settings.asrBaseURL, prompt: Text("https://…/v1")).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("模型")
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("模型", text: $settings.asrModel, prompt: Text("比如 whisper-1")).textFieldStyle(.roundedBorder)
                        if CloudASR.isMiMo(settings.asrBaseURL), CloudASR.mimoModel(settings.asrModel) != settings.asrModel {
                            Text("「\(settings.asrModel)」是对话模型，不能转写。转写会用 \(CloudASR.mimoModel(settings.asrModel))。")
                                .font(.caption).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                GridRow {
                    Text("密钥")
                    SecureField("API Key", text: $settings.asrKey).textFieldStyle(.roundedBorder)
                }
            }
            .padding(14).panel(radius: Theme.Radius.card)
            HStack {
                if let result {
                    Text(result.text).font(.callout).foregroundStyle(result.ok ? Theme.ok : Theme.amber).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if testing { ProgressView().controlSize(.small) }
                Button("测试一下") { test() }.disabled(settings.asrConfig == nil || testing)
                Button("完成") { dismiss() }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 560)
    }

    private func test() {
        guard let config = store.settings.asrConfig else { return }
        testing = true; result = nil
        Task {
            defer { testing = false }
            do { try await CloudASR.test(config); result = (true, String(localized: "测试通过，接口能用。")) }
            catch { result = (false, error.localizedDescription) }
        }
    }
}

// MARK: 词库

private struct VocabularyPane: View {
    @Environment(BeanStore.self) private var store
    @State private var wrong = ""
    @State private var right = ""
    @FocusState private var focus: Field?
    private enum Field { case wrong, right }

    private var canAdd: Bool {
        !wrong.trimmingCharacters(in: .whitespaces).isEmpty && !right.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        let settings = store.settings
        PaneFrame {
            SettingsGroup(String(localized: "纠错词库"), footer: String(localized: "模型老是听错的人名、产品名、术语记在这里，以后转写出来会自动改成正确的写法。在文字稿里改一个词，也会记到这里。")) {
                HStack(spacing: 10) {
                    TextField("听成了", text: $wrong, prompt: Text("听成了，比如：豆苍")).textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .wrong).onSubmit { focus = .right }
                    Image(systemName: "arrow.right").font(.callout).foregroundStyle(.tertiary).accessibilityHidden(true)
                    TextField("应该是", text: $right, prompt: Text("应该是，比如：豆仓")).textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .right).onSubmit(add)
                    Button("记住", action: add).disabled(!canAdd)
                }
                if settings.vocabulary.isEmpty {
                    Text("还没有记住任何词。").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(settings.vocabulary) { entry in
                                HStack(spacing: 10) {
                                    Text(entry.wrong).foregroundStyle(.secondary)
                                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
                                    Text(entry.right)
                                    Spacer()
                                    Button("删除「\(entry.wrong)」", systemImage: "minus.circle") { settings.vocabulary.removeAll { $0 == entry } }
                                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                                }
                                .padding(.vertical, 7)
                                if entry != settings.vocabulary.last { Divider() }
                            }
                        }
                    }
                    .frame(height: min(CGFloat(settings.vocabulary.count) * 36, 288))
                }
            }
        }
    }

    private func add() {
        guard canAdd else { return }
        let w = wrong.trimmingCharacters(in: .whitespaces), r = right.trimmingCharacters(in: .whitespaces)
        store.settings.vocabulary.removeAll { $0.wrong == w }
        store.settings.vocabulary.insert(.init(wrong: w, right: r), at: 0)
        wrong = ""; right = ""
        focus = .wrong
    }
}

// MARK: 连接

private struct ConnectPane: View {
    @Environment(BeanStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(Connector.self) private var connector
    @State private var copied = false
    @State private var rotated = false

    var body: some View {
        PaneFrame {
            SettingsGroup(String(localized: "AI 助手"), footer: String(localized: "连上之后，在它们那边就能直接查你的录音、纪要和待办，也能把文字和音频存进豆仓。")) {
                SettingRow(icon: "link", title: "Claude、Codex、OpenClaw、Grok Bot",
                           detail: connector.connectedCount > 0 ? String(localized: "已经连上 \(connector.connectedCount) 个。") : String(localized: "还没有连上任何一个。")) {
                    Button("打开连接页面…") { openWindow(id: "connect") }
                }
                SettingRow(icon: "film", title: String(localized: "Renoise（做视频）"), detail: String(localized: "把改写好的稿子做成口播视频要用它。安装和登录也在连接页面里。")) {
                    Button("去看看…") { openWindow(id: "connect") }
                }
            }

            LoginsGroup()

            SettingsGroup(String(localized: "给其他工具用"), footer: String(localized: "命令行入口随时可用。网址入口默认关闭，仅监听 127.0.0.1 且需要令牌鉴权。")) {
                SettingRow(icon: "network", title: String(localized: "本机网址入口（HTTP MCP）"),
                           detail: String(localized: "仅给 Grok Bot 等只认网址的工具用，开启后需带令牌访问。")) {
                    Toggle("本机网址入口（HTTP MCP）", isOn: Binding(
                        get: { store.settings.httpMCPEnabled },
                        set: { store.setHTTPMCPEnabled($0) }
                    ))
                    .labelsHidden().toggleStyle(.switch)
                }
                if store.settings.httpMCPEnabled {
                    SettingRow(icon: "key", title: String(localized: "接入地址")) {
                        Text(store.mcpMaskedAddress).font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button(copied ? "已拷贝" : "拷贝含令牌地址") {
                            if let addr = store.mcpAuthenticatedAddress() {
                                copy(addr)
                                copied = true
                                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                            }
                        }
                        Button(rotated ? "已重置" : "重置令牌") {
                            if store.rotateMCPToken() {
                                rotated = true
                                Task { try? await Task.sleep(for: .seconds(1.5)); rotated = false }
                            }
                        }
                    }
                }
                SettingRow(icon: "terminal", title: String(localized: "命令行"), detail: String(localized: "在终端里也能查录音、存内容。")) {
                    Text("beanpod").font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .task { await connector.refresh() }
    }
}

/// 从链接导入时登录过的平台。登录状态只存在这台 Mac 上，这里可以一个个清掉。
private struct LoginsGroup: View {
    @Environment(BeanStore.self) private var store
    @State private var refresh = 0

    var body: some View {
        let list = store.loggedInPlatforms
        let _ = refresh
        SettingsGroup(String(localized: "从链接导入时登录过的平台"), footer: String(localized: "导入要登录才能看的内容时，豆仓会弹出登录窗口让你自己登录。登录状态只存在这台 Mac 上。")) {
            if list.isEmpty {
                Text("还没有登录过任何平台。").foregroundStyle(.secondary)
            }
            ForEach(list, id: \.self) { platform in
                SettingRow(icon: "person.crop.circle.badge.checkmark", title: platform) {
                    Button("退出登录") { store.forgetLogin(platform); refresh += 1 }
                }
            }
        }
    }
}
