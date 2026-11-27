# BeanPod「人物」功能分支执行计划

交给负责实现的 agent。功能分支沿用 `feat/friends-circle`，App 侧栏及界面一级模块正式定名为「人物」（英文对应 `People`）。交付物是 Mac 端一个可使用的一级模块：从导入或录下新对话，到认出老朋友、整理说定的事、就地或回跳原话核实，整条路径都要在真实 App 中走通。

## 1. 最终用户体验与审美规范

1. **侧栏与双栏布局**：在侧栏点「人物」（图标 `person.2.fill`），与「知识库」构成「事（知识库）— 人（人物）」并列结构。页内采用与 `RecordingsView` 一致的双栏布局：左侧人物列表（宽度 `300–340pt`），右侧人物详情（正文区 `maxWidth 820pt`）。首页主列表按最近交流时间倒序列出**已命名人物**，支持按姓名或备注搜索；「待认识的声音」折叠收纳在列表顶部轻提示条中（如「有 N 个常出现的声音还没记名字」），点击后再展开核对，不与熟人混排。
2. **色彩与材质纪律**：严格遵守 `Shared/Theme.swift` 规范（暖灰纸面底、单一玫瑰红强调色、**严禁蓝和紫**）。圆角只用 `Theme.Radius` 三档（`panel: 10`、`card: 8`、`chip: 6`；仅纯圆形头像与开关使用圆/胶囊）。人物圆头像（显示姓或名首字）按 UUID 稳定映射 `Theme.speakers` 的低饱和暖/中性色板（琥珀、珊瑚、鼠尾草绿、沙、赭、暖灰）或同色温暖色，采用「14% 浅色底 + 同色系深字」，禁止高饱和实心彩球。待认识声音统一使用 `Theme.warm200` 暖灰底加虚线描边。
3. **反噪音门槛与稳定编号**：单条录音内清晰单人发言累计不足 `30 秒` 且未跨录音复现的偶发路人，只保留为该条录音内的说话人标签，不自动升格进人物首页（用户可在文字稿说话人菜单手动升格为联系人）。跨录音复现或单次足够清晰的长发言（`≥ 30 秒`）才会建为待认识卡片；同一次对话内同一人的多句话只建一张卡，后续录音可靠匹配时沿用该卡。内部编号按 `A–Z`、`AA`、`AB` 顺序递增，跨天、改名、重启保持稳定且不回收；界面优先展示出现语境（如「未记名 · 周四《供应商报价沟通》」），内部编号作为次级标识。
4. **详情页按生熟分工、无内容不占位**：
   - **待认识声音**：首屏置顶 2–3 段清晰代表发言的试听条，直接提供「记下名字」「关联已有的人」「忽略这位声音」入口。
   - **已确认人物**：首屏聚焦「简要背景 → 说定的事 / 提到的事 → 最近聊过 → 按日期排列的对话时间线」。声音样本管理收进姓名旁的状态胶囊（如「3 段声音样本」）和右上角 `IconMenu("ellipsis")` 菜单，不常驻首屏抢占视线。没有可核实内容的栏目整栏隐藏，不摆空的交易表格；往来事项复用豆仓现有待办卡片与原话引用样式。
5. **就地回听优先与跨页返回**：点击话题、事项或对话条目旁的播放按钮，直接在当前人物页内调用片段播放（`BeanStore.playSpan`），不打断阅读跳转页面。仅当用户点击录音标题或「去文字稿查看」时，才通过 `Navigator` 切到该录音的文字稿页签（`tab = 1`）、定位并高亮目标句；此时录音详情顶部显示轻量返回条（`← 返回 某人`），一键回到同一人物页。
6. **「我的声音」、单句纠错与两卡合并撤销**：
   - 第一次启用时可添加「我的声音」，本人作为对话参与者参与识别，不占联系人名额；未设置本人声纹时，可直接在句子或人物菜单手动标「我」或确认「这是我参与的对话」，无需先录本人声音才能使用人物模块。
   - 发现某句归错人，在原句说话人菜单直接改归属（支持批量同批纠正），其他句保持原归属；单句改归属不得把整张人物卡改名。
   - 发现同人两卡（系统推荐或手动选择），并排试听、预览样本与冲突资料后单事务合并，同一场会议的重复引用自动去重；合并记入变更日志并支持重启后撤销，撤销只回滚本次合并而不伤及合并后其他人物的新增操作。

## 2. 实测实现条件、基线和代码入口

### 2.1 本机实测条件（2026-11-27 核验）

- **硬件与系统**：macOS 27.0（`26A5388g`），Apple Silicon `arm64`，`24 GB` 内存，可用磁盘 `625 GB`。
- **开发与运行时工具链**：Xcode 27.2（`27B52`，已安装 macOS 27.2、iOS 27.2 及 iOS Simulator 27.2 SDK），Swift 6.4.2，`xcodegen`（`/Users/luweiwei/.local/bin/xcodegen`），`llama-server`（`/Users/luweiwei/.local/bin/llama-server`），系统自带 `sqlite3` 3.54.0（App 内直接 `import SQLite3`，零外部数据库依赖）。
- **关键约束（决定技术路线）**：
  - 本机**未安装 `brew` 与 `ffmpeg`**，系统 `/usr/bin/python3` 为 **Python 3.9.6**（不满足新版 PyTorch / pyannote 3.x / SpeechBrain 的运行与分发要求）。
  - 因此**放弃 Python + PyTorch 栈**，全面采用原生 SwiftPM + C/C++ ONNX 静态库方案；导入音频样本与本地解码统一走系统原生 `AVAudioFile` / `AVAudioConverter`（CoreAudio 原生支持 WAV、M4A、MP3、AAC、CAF、AIFF、MP4、MOV），不依赖 `ffmpeg`。

### 2.2 本机声纹与说话人分割技术栈（已核实上游仓库与模型校验值）

- **推理引擎**：接入官方 SwiftPM 包 `https://github.com/k2-fsa/sherpa-onnx`（已核实其根 `Package.swift` 提供预编译 macOS 静态 XCFramework `sherpa-onnx-v2.0.3-macos-static.xcframework.zip` 与 `csukuangfj/onnxruntime-libs` `1.28.2`，支持 macOS 10.15+）。仅链接进 Mac 主目标 `BeanPod`，**不引入 `BeanPodMobile`**，保持 iOS 端与 `BeanKit` 轻量。
- **Swift API 边界与并发隔离**：
  - `project.yml` 对 `BeanPod` 默认开启 `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`，而 `sherpa-onnx` Swift 封装（`SherpaOnnx.swift`）持有 C `OpaquePointer`。必须将分割与声纹推理封装在 `App/` 目录下的独立 `actor`（如 `SpeakerEngine`）中，后台线程运行，通过 `Sendable` 纯值类型返回给界面和 `BeanStore`。
  - 使用 `SherpaOnnxOfflineSpeakerDiarizationWrapper`（`sherpaOnnxFastClusteringConfig(numClusters: -1, threshold: ...)`）完成录音内分人，输出按开始时间排序的 `(start, end, speaker)`；使用 `SherpaOnnxSpeakerEmbeddingExtractorWrapper` 对纯净单人语音段提取固定维度的声纹向量用于建档和跨录音余弦匹配。
  - **重叠处理**：`SherpaOnnxOfflineSpeakerDiarizationSegmentWrapper` 结构无独立 `overlap` 布尔字段。Swift 侧需对不同 `speaker` 输出的时间区间求时间交集并标记 `overlap = true`；送入 `SherpaOnnxSpeakerEmbeddingExtractorWrapper` 提取声纹前，先剔除所有重叠区间。P1 需实测验证默认聚类是否抑制短重叠并记录结果。
  - **备选对比**：`FluidInference/FluidAudio`（Swift 6.0，CoreML / ANE 跑 Pyannote + WeSpeaker）仅在 P1 实测 `sherpa-onnx` CPU 性能或中文切分质量明显不达标时再做对照实验（注意其 WeSpeaker 权重偏英文）。
- **免门控、免 Token ONNX 模型清单（已核实 `gated: False`、字节数与 SHA-256，合计约 `34 MB`）**：

| 用途 | 仓库与固定 Revision / 许可 | 文件名 | 大小（字节） | SHA-256 |
|---|---|---|---|---|
| 说话人分割（首选） | `csukuangfj/sherpa-onnx-pyannote-segmentation-3-0` · rev `9403a6902bb58e3d5ae8c7e77c3422de279db2e0` · MIT | `model.onnx` | `5,992,913` | `220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079` |
| 说话人分割（轻量备选） | 同上 | `model.int8.onnx` | `1,540,506` | `d582f4b4c6b48205de7e0643c57df0df5615a3c176189be3fc461e9d18827b5d` |
| 中英声纹向量（首选，192 维 CAM++） | `csukuangfj/speaker-embedding-models` · rev `a8055d6daef723a6a4ecf4de233708575bf4994f` · 上游 3D-Speaker Apache-2.0 | `3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx` | `28,281,165` | `53cab20ba8f2eb2f6e2d89ecc18e88ef3222169b61b4419cbc13666744a4574b` |
| 中文声纹向量（P1 对照组，ERes2Net） | 同上 | `3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx` | `39,593,762` | `f1ee61be04000b50392a63442e5dd9feaea7e81dddd494d3647cf1c3d88a1498` |

- **下载器改造注意点**：已实测 `huggingface.co` 与 `hf-mirror.com` 均可直连拉取上述文件，但 `Shared/ModelDownloader.swift` 当前 `ModelSource.modelscope` 硬编码路径对 `csukuangfj/*` 返回 `404`。需给 `ModelFile` 增加可选 `fallbackURLs: [URL]`（可挂 `github.com/k2-fsa/sherpa-onnx` Releases `speaker-segmentation-models` 与 `speaker-recongition-models` 直链），继续沿用 `DownloadJob` 的断点续传、超时切源与 SHA-256 校验。模型存放于 `Application Support/BeanPod/Models/speaker/`，受用户显式点击「下载」触发，未下载时所有已有录音与手工人物维护不受影响。

### 2.3 分支现状、开工检查和代码入口

当前功能分支 `feat/friends-circle` 基于 `0e883bbe9daff0c1f13ea6ad4e3165ea2b2fc734`（与本地 `main`、`upstream/main` 一致）。远端 `origin/main` 已推进至 `5164136`（包含 PR #2 `b99a228` Xcode 27 `TornBottom` 修复、PR #3 `98cd076` HTTP MCP 安全加固、PR #4 `8faf990` 大音频流式解码与异步导入）。接手先检查：

```sh
git status --short --branch
git branch --show-current
git log -3 --oneline
git worktree list
```

看到 `feat/friends-circle` 后继续；若仍在 `0e883bb` 基线开发，P0 单独 `git cherry-pick ab8b06f`（或 `b99a228`）解除 Xcode 27 编译阻塞，并按 P3 自建分窗音频读取；若经用户明确授权先变基到 `origin/main`（`5164136`），则可直接复用其 Xcode 27 修复与流式解码并跳过手工 cherry-pick。遇到用户未提交改动时保留并避开冲突文件，禁止用 `reset`、`clean` 或覆盖重建起点。

| 已核对的入口 | 接手时要看与改造什么 |
|---|---|
| `App/Views.swift` | `Route` 新增 `.people`；`Navigator` 增加 `selectedPersonID`、`returnRoute`、`returnPersonID`、`pendingTranscriptTarget`；`Sidebar` 新增一级入口「人物」；`RecordingDetail` 支持外部跳入直接切到文字稿 `tab = 1` 并显示返回条；`TranscriptView.speakerMenu` 接入人物选择、标为「我」、手动升格路人及单句纠错。 |
| `Shared/Theme.swift` | `Theme.speakers`（6 色暖/中性色板）、`Theme.Radius`、`Theme.warm200`/`warm50..warm900`、`Theme.accent`。所有人物头像、状态胶囊与卡片底板严格复用此文件色值和圆角。 |
| `Shared/Domain.swift` | `Recording.id` 为 `UInt32`，`Recording.people` 与 `Recording.speakers`；`Segment` 增加可选 `end: TimeInterval?`（缺省向后兼容旧 `library.json`），`speaker` 保持录音内下标；`isMaterial`、`isDictation`、`recordedOn`、`sourceDetail`、`textOnly`、`scene` 参与来源过滤。 |
| `Shared/BeanStore.swift` | `folder` 增加启动参数 `-data-dir <路径>` / 环境变量 `BEANPOD_DATA_DIR` 隔离测试库（优先于 `-demo` 之外的默认路径）；复用 `wavURL`、`loadLibrary`、`saveLibrary`、`playSpan`、`play(_:at:)`、`decodeAnyAudio`；新增受管样本文件独立试听（与主播放器互斥）。 |
| `Shared/ModelDownloader.swift`、`App/SettingsView.swift` | `ModelFile` 增可选 `fallbackURLs`（遇 404 或慢源自动回退直链）；`SettingsView` 模型页新增「说话人识别（声纹）」下载卡，并展示就绪状态与模型存放目录。 |
| `Shared/Pipeline.swift`、`App/QwenASR.swift`、`Shared/AudioTools.swift` | 新增本机「先分人、再按说话人边界 + 停顿切块送 ASR」流水线路径，使 `Segment` 带精确 `start`/`end` 与单人归属；`QwenASR.sentenceChunks` 仅在同人超 `15 秒` 发言内二次切分；长音频分窗读取，保证 `QwenASR`、`SpeakerEngine`、`LocalLLM` 不同时常驻占满内存。 |
| `Shared/Trash.swift`、`App/FeishuSync.swift`、`App/KnowledgeView.swift`、`Sources/beanpod/main.swift` | `moveToTrash` / `restore` / `deleteForever` 同步隐藏/恢复/清理人物时间线与派生摘要；人物库改名、合并、单句纠错后同步回写 `Recording.people` 与 `speakers` 显示名投影，直接打通纪要底栏、`KnowledgeView.searchFilters`、Markdown 导出及 `beanpod-cli` / MCP（`search_recordings`、`list_topics`）；不得为人物建档触发飞书补下载。 |
| `Shared/Analyzer.swift`、`App/LocalLLM.swift` | P5 复用 `LocalLLM`（`Qwen3-4B-Q4_K_M.gguf`）或带安全边界的本地兼容服务；按整场带 `[#句号]` 索引的文字稿一次性抽取所有人物信息与证据句号，严禁让模型直接输出时间戳。 |
| `project.yml`、`Package.swift`、`App/Localizable.xcstrings` | 仅在 `project.yml` 的 Mac 目标 `BeanPod` 引入 `sherpa-onnx` SwiftPM 包，保持 `BeanPodMobile` 与 `Package.swift` 不引入重型推理包；补充「人物」模块中英文词条及可运行测试目标。 |

本分支交付 Mac 界面、本机声纹识别、SQLite 人物存储、流水线接入、有依据人物摘要与验收。暂不扩展 iOS 人物界面、云端声纹、飞书写回、消息发送或全历史默认扫描；保持原有转写、播放、手工说话人、导出、CLI 和手机端兼容。`fix/feishu-audio-retry` 为独立维护分支，不整支合入。

## 3. 实施顺序与逐阶段验收

### P0　先修构建阻塞、建隔离测试库与样本集

**已实测的开工阻塞（2026-11-26 / 11-27 复核）**：基线 `0e883bb` 上 `swift test` 通过全部 22 项，但 Mac 目标在 Xcode 27.2 下编译失败，错误位于 `App/NotchShow.swift:256`（`conformance of 'TornBottom' to protocol 'Shape' crosses into main actor-isolated code`）。在干净副本仅应用提交 `ab8b06f`（`TornBottom` 加 `nonisolated`）后同一 Mac 构建通过。接手时先检查 `git show --stat ab8b06f`，若当前分支仍缺此行且未变基到 `origin/main`，先单独执行 `git cherry-pick ab8b06f` 再跑构建。

- **隔离测试根目录**：在 `Shared/BeanStore.swift` 的 `folder` 初始化加入启动参数 `--args -data-dir <绝对路径>`（或环境变量 `BEANPOD_DATA_DIR`）支持，确保测试和自动化验收完全写入临时目录，不碰 `~/Library/Application Support/BeanPod/Recordings/library.json` 正式库，也不依赖会覆盖固定 Demo 目录的演示脚本。
- **记录环境与准备分集音频**：记录提交号、macOS/Xcode 版本、可用内存与磁盘。准备获参与者同意的去标识测试音频并在库外保存人工答案（说话人、起止时间、是否重叠、采集信道）：
  - **登记集 / 调参集 / 最终验证集严格隔离**，同一段录音的切片不得跨集合。
  - 场景至少覆盖：「我」与两位熟人跨天重逢录音（近场录音豆/麦克风）、未登记新人、快速轮流接话（无 0.3 秒明显停顿）、多人抢话重叠、噪声与远近变化、单人短路人（`< 30 秒` 偶发插话）、电脑外放二次拾音录音、无原音旧文稿/飞书纯文字、播客/视频链接素材、损坏音频，以及超过 1 小时的拼接长音频。
- **退出条件**：Mac 构建与 `swift test` 全绿；确认 `-data-dir` 隔离库可独立启动并写入；列明已有样本清单及缺项（缺跨天或外放样本时标明「待补」，继续推进数据结构与界面工程）。

### P1　用独立 Swift 测试跑通 sherpa-onnx 声纹实验

- 在 `App/` 目录新建独立于 SwiftUI 的声纹识别模块（如 `actor SpeakerEngine`）及对应的测试脚本或单元测试入口，接入 `sherpa-onnx`（`2.0.3` 静态 XCFramework）与本方案第 2.2 节指定的两套无门控 ONNX 模型。
- **核心算法约束**：
  1. 先用 `SherpaOnnxOfflineSpeakerDiarizationWrapper` 对音频分出 `(start, end, localSpeaker)`，再对不同 `localSpeaker` 的时间区间求交集并标记 `overlap = true`。
  2. 抽取可跨录音比对的声纹向量前，剔除重叠区间与低于最短有效语音时长（如 `< 1.2 秒`）或能量过低的静音/噪声段，使用 `SherpaOnnxSpeakerEmbeddingExtractorWrapper` 计算归一化 192 维余弦向量。
  3. 用独立调参集对比 `3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx` 与 `3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx`，校准「自动认作某人」「建议人工确认」「证据不足（判为新人或待确认）」三个分数区间及第一/第二候选最小间距（Margin），解决相似声音误认。
  4. 单独记录**近场直录**与**系统/外放二次拾音**两条信道下的余弦分数分布差异。
- **下载与离线验收**：改造 `Shared/ModelDownloader.swift` 支持 `fallbackURLs`，验证从零下载 `model.onnx`（`5.99 MB`）与 CAM++ 模型（`28.28 MB`）并校验精确 SHA-256；断网后离线复跑测试。
- **退出条件**：同条多人快接话录音能切分出不同说话人；另一天同一人录音能比对出正确候选；未登记新人不被强行塞给已知人；保存去标识实验报告（模型版本、阈值、RTF、峰值内存与失败样例）。

### P2　建立 SQLite 人物库并打通既有字段投影

在数据根目录旁建 `People/people.sqlite`（与 `Recordings/` 平行，按正式库 / `-demo` / `-data-dir` 天然隔离），使用系统原生 `SQLite3` 开启 WAL 模式，记录 `PRAGMA user_version` 并附带迁移单元测试。外部 `SpeakerEngine` 接口只接收文件 URL、音频指纹、任务 ID 和模型版本，区间统一从原始音频零点起算（左闭右开毫秒），拒绝负时间、倒置区间和越界区间。

| 表 / 对象 | 必需字段与核心约束 |
|---|---|
| `persons`（人物） | `id` (UUID)、`display_name`、`stranger_index` (唯一递增整数，A–Z/AA/AB，不回收)、`color_index` (映射 `Theme.speakers`)、`status` (`confirmed` / `pending` / `ignored`)、`is_me` (全局至多一人)、`note`、`created_at`、`last_met_at`。允许同名；改名沿用 UUID。 |
| `voice_samples`（声音样本） | `id` (UUID)、`person_id`、`source_kind` (`recording_span` / `imported_file`)、`recording_id`、`start_ms`、`end_ms`、`managed_file` (外部导入复制到 `People/Samples/`，原文件不动)、`channel` (`near_field` / `speaker_loopback` / `unknown`)、`confirmed` (仅人工确认样本进入标准声纹均值)、`model_version`、`embedding` (BLOB)、`content_hash` (去重)。删改样本后重算该人物中心向量。 |
| `utterances`（发言归属） | `id`、`recording_id`、`audio_fingerprint`、`start_ms`、`end_ms`、`local_speaker`、`overlap`、`person_id` (可空)、`source` (`auto` / `manual` / `unknown`)、`score`、`model_version`。严格以原音毫秒区间定位，ASR 句子下标仅做展示关联。 |
| `person_insights`（资料与往来） | `id`、`person_id`、`kind` (`bio` / `topic` / `commitment`)、`text`、`recording_id`、`start_ms`、`end_ms`、`occurred_at`、`edited_by_user`、`model_version`、`stale`。同一场多人会议只在关联人名下计 1 次对话记录。 |
| `jobs_and_audits`（作业与纠错） | 记录任务输入指纹、模型与规则版本、进度、失败原因；`rejected_pairs`（防重新分析反复推荐已驳回候选）；`merge_logs`（单事务合并前后快照，支持精准撤销）。 |

**权威源同步规则（打通老功能）**：人物库为跨录音人物身份的**唯一权威源**。每当分析完成、人物改名、单句改归属或两卡合并/撤销时，同步更新受影响 `Recording.people`（去重后的已确认人物名）与 `Recording.speakers` 显示名投影并写回 `library.json`（保留历史无音频或未绑定人物的手工 `speakers` 标签）。由此纪要页底部人物标签、`KnowledgeView` 的人物下拉筛选、Markdown 导出 `people:` 头信息及 `Sources/beanpod/main.swift`（CLI 与 MCP）无需另写兼容层即可立即生效。

**退出条件**：旧 `library.json`（无 `Segment.end`）可无损打开；同名两人共存；改名、样本增删、陌生人序号重启稳定；重复提交或中途退出不残留脏数据或半合并状态；数据库异常高版本/损坏时报告可恢复错误，禁止静默清空覆盖。

### P3　改造流水线：先分人后转写与双层来源筛选

1. **双路径切分与对齐（解决快接话痛点）**：
   - **路径 A（本机 `Qwen3-ASR` + 声纹模型就绪）**：先运行 `SpeakerEngine` 说话人分割，按「说话人切换边界 + `lastPause`（单人连续发言超过 `15 秒` 时再沿停顿切细）」切块送入 `QwenASR`，生成的 `Segment` 同时写入 `start` 与 `end`、初始 `speaker` 下标及毫秒级 `utterances` 关联，从源头杜绝二人一问一答混入同一句。
   - **路径 B（云端 ASR / 系统单段转写 / 已有文字稿）**：保留声学区间并计算与 `Segment` 的时间交集；单句交集占比清晰且唯一时绑定人物，一句跨多人时标为「多人 / 待确认」；系统识别若整篇只有 `start = 0` 一段，保留可点播的声学时间线，文字稿顶部标明「无逐句时间戳，无法逐句归人」，禁止把整篇误标给单人。
2. **两层来源筛选（防播客与外放污染）**：
   - **第一层（确定性元数据拦截）**：`isMaterial`（链接导入素材）、`isDictation`（语音输入）、`Mac · 电脑声音`（纯系统内录），以及场景判为 `大会 / 课程 / 自媒体 / 灵感` 或 `textOnly` 笔记，默认**不自动参与声纹建卡、不自动生成陌生人**；仅允许用户单条手动开启分析或手工关联人物。
   - **第二层（声学信道与本人参与门控）**：近场录音（录音豆、得到录音卡、Mac/iPhone 麦克风）在确认含「我」的声音或经用户手动标「我」参与后，纳入正式社交往来统计；`channel = speaker_loopback`（外放或系统混音）仅做辅助参考提示，**禁止自动写入人物标准声纹库**，避免同一熟人在近场与外放间裂变成两张卡。
3. **长音频分窗与内存互斥**：在 `Shared/AudioTools.swift` 实现按固定时长窗（如 `5 分钟` 窗长、`30 秒` 重叠步进）流式读取大 WAV，不一次性把数小时全天 PCM 全部常驻内存；重叠边界区间通过声纹相似度与时间重叠去重连接各窗临时说话人。后台队列串行调度，执行声纹分析前按需释放 `QwenASR` / `LocalLLM`，支持取消（清理临时文件）、休眠恢复与断点重试。
4. **生命周期联动**：重转写同一原音时保留人工指定的区间与人物归属并重新对齐文字；音频移入回收站（`Shared/Trash.swift`）即在人物时间线和摘要中隐藏，恢复后原样恢复，永久删除或到期清理时级联移除派生 `utterances`、`person_insights` 与源自该录音的 `voice_samples`（独立导入音频样本不受录音删除影响）。

**退出条件**：新导入或录下的对话可自动出现在对应人物时间线；单句快接话不混句；外放与链接素材不污染陌生人列表；重跑不重复；回收站删/恢复全实测；无声纹模型时原有转写整理功能完全正常。

### P4　完成「人物」双栏界面、样本导入与纠错闭环

- **双栏通讯录（`App/` 新增视图，`App/Views.swift` 接入 `.people` 路由）**：
  - 左栏顶部：搜索框（按姓名、备注）+ 「待认识的声音（N）」折叠条（仅当存在符合门槛的待认识声音时出现）+ 「添加人物」按钮；主体列表只放已命名人物（按最近交流倒序，空库展示清晰引导「添加联系人」「去录音里认人」）。
  - 左栏行样式：圆形暖色首字母头像（遵循 `Theme.speakers`）+ 姓名（本人显示「我」标签）+ 最近交流时间 + 一行最新话题（无则留空）。
- **右栏人物详情**：
  - 待认识声音：顶部显示出现语境（如「未记名 A · 11-24《供应商报价》」）、代表原声试听卡片（内置波形/播放进度条），以及「记下名字」「关联已有联系人」「以后不提示」三个直接操作。
  - 已确认人物：头部为头像、姓名（支持直接改名）、备注、状态胶囊（「N 段声音样本」，点击可弹出样本管理抽屉，也可在右上角 `IconMenu("ellipsis")` 管理/补录/添加样本）。主体仅展示有真实内容的栏目：简要背景、说定的事 / 提到的事、最近聊过、按日期分组的对话时间线。
  - **就地试听与跨页返回**：每条话题、事项、原话旁带播放按钮，点击直接调用 `BeanStore.playSpan` 在本页播放，播放高亮当前条目；点录音标题或「去文字稿查看」跳转 `RecordingDetail` 文字稿页签定位滚动，顶部显示 `← 返回 某人`。
- **外部音频导入样本**：多选弹窗声明系统原生可解码格式（WAV、M4A、MP3、AAC、CAF、AIFF、MP4、MOV），使用 `AVAudioFile` / `AVAudioConverter` 校验解码并裁剪区间；坏文件逐项报错但不阻断批次；已导入样本受管存放在 `People/Samples/`，拔掉外置盘仍可试听，且**严禁写入 `Recordings/library.json`**。
- **单句纠错与两卡合并**：
  - 在 `TranscriptView.speakerMenu` 选「改归另一人」「待确认」「标为我」「升格为待认识人物」，支持同录音内同临时说话人一键批量改归属并预览影响条数；人工修改优先级永远高于重跑模型。
  - 合并两张卡（系统相似声纹推荐或手动多选合并）：并排试听双方样本、对比对话数与备注冲突、选择保留主卡后单事务合并并记录 `merge_logs`；撤销按钮恢复原人物、原样本和仅属于合并前的对话归属，合并后新增且无法自动区分的保留待确认。

**退出条件**：从待认识命名、关联已有联系人、就地试听原话、跳文字稿再返回、单句改归属、两卡合并并重启后撤销，全程用鼠标在 Mac App 真实跑通。

### P5　从谈话提取有依据的人物背景与往来事项

1. **防幻觉输入/输出设计（适配本机 `Qwen3-4B`）**：
   - 将已纳入对话中经确认或高置信归属的发言，按时间顺序编号传给模型，格式如 `[#12] 王总：下周二前把三万尾款打过去`。
   - 单次整场对话推理同时输出所有在场人物的更新项，**模型只输出引用的句号列表 `segment_indices: [12]`**，严禁让 4B 模型直接计算或生成毫秒/秒数时间戳；程序校验 `segment_indices` 存在、归属匹配后，从对应 `Segment` / `utterance` 反查精确声学起止时间并落库。
2. **严谨语义约束**：
   - 人物简要信息只摘取明确原文依据的称呼、职责、关系，无证据留空。
   - 严格区分说话人自述、他人转述与会议中提及的第三人；区分报价与成交、预计付款与已付款、口头邀约与已赴约，完整保留否定词与前提条件（如「还没付」「如果本周上线就签」）。多人会议里提到第三人或他人的款项，不得记到说话人或错误参与者名下。
3. **本地优先与隐私边界**：优先复用 `LocalLLM`（本机 `Qwen3-4B`）；无本机整理模型时，人物页直接展示最近归属给该人的高置信原句并标记「原话」，不因人物模块静默把声纹、人物关系或带真实姓名的全量档案送往云端服务。人工编辑和删除的条目设为 `edited_by_user = 1`，后续重跑模型不得覆盖或恢复已删项；原录音被移入回收站或永久删除时，对应 `person_insights` 同步隐藏或清理，来源失效内容绝不作为事实展示。

**退出条件**：用含「下周付」「还没付」「第三人已经付过」的多人测试录音跑 P5，逐条核对归属、状态、`segment_indices` 反查区间和人物页就地试听；手工修改摘要并删除一条待办后重跑分析，人工状态完整保留。

## 4. 自动署名与全天处理的放行条件

以下为首版试用放行参考门槛（非公共榜单引用），需**按近场直录与系统/外放两条信道分别汇报**实际分子、分母与样本量：

| 检验维度 | 测量口径与放行标准 |
|---|---|
| 名字是否标对（精准率） | 未参与调参的跨天验证集上：`正确自动署名发言数 / 全部自动署名发言数`；首轮至少核对 `50` 个可独立判定的单人发言、覆盖 `≥ 2` 天；自动署名放行建议该批误认数为 `0`。样本不足或出现误认时保持「建议确认」模式。 |
| 系统是否有用（召回与拒识） | 已登记人物 `正确自动署名数 / 这些人可辨全部发言数` 建议 `≥ 70%`；`陌生人被错标成已知人次数 / 陌生人发言总数` 应为 `0`。单独汇报重叠、短句（`< 1.2s`）和路人被置为待确认的数量，不得靠全置待确认虚高准确率。 |
| 陌生人聚散是否稳定 | 核对同一陌生人跨天重逢是否聚到同一卡、不同陌生人是否隔离、`30 秒` 以下单次路人是否未刷屏首页，以及每次错合后的拆分/改归属能力。 |
| 可否日常跑全天（性能） | 在目标 Mac（当前 `arm64 / 24 GB`）跑 `≥ 1 小时` 连续长音频及日常批次，记录：总音频时长、墙钟耗时、实时系数（RTF = 耗时 / 时长）、峰值内存（重点观察与 `QwenASR` / `LocalLLM` 切换时）、额外磁盘占用、Mac 休眠唤醒恢复及 UI 响应度。 |

若识别指标未过自动署名门槛，仍可先交付「手动认人 + 推荐候选（关闭自动落库署名）」供日常使用，并在回执中如实标注未过项。

## 5. 端到端验收清单

执行者逐行记录「已验证 / 部分验证 / 未验证」、样本集、分子分母数据与证据。私人原音与真实姓名不得入库或附截图。

| 编号 | 操作 | 预期可见结果与核验点 |
|---|---|---|
| A01 | 用 `--args -data-dir <隔离目录>` 启动 App，打开「人物」建同名两人，给其中一人导入两段原生格式音频（如 WAV/M4A） | 侧栏「人物」一级入口可达，无蓝紫色、头像严格使用 `Theme.speakers` 暖色；两张独立身份卡，重启后姓名、颜色与受管样本均在。 |
| A02 | 导入两天的三人近场对话 + 一段含 `< 20 秒` 偶发路人插话的录音 | 偶发路人未刷屏首页，留于录音内标签；「我」不占联系人名额；熟人跨天自动认出，长期未登记的新人收纳在顶部待认识提示中。 |
| A03 | 在待认识试听并命名为「陈工」，再到另一条录音与知识库中查看 | 待认识人数减一，「陈工」进入主列表，头像颜色与原卡稳定一致；对应录音纪要人物芯片、`KnowledgeView` 筛选与 `beanpod-cli` 同步更新为「陈工」。 |
| A04 | 在快速一问一答（无长停顿）的双人录音中，核对切分结果并手工改错一条发言的归属，再重跑分析 | 本机 `Qwen3-ASR` 按说话人边界切句不混句；改归属句更新至目标人物时间线与摘要；重跑后人工纠错保持不被覆盖。 |
| A05 | 对重复建卡的同一人触发合并（双方共同参会一次），重启后撤销合并 | 合并后同一场会议仅计 1 次对话，双边样本保留且已去重；重启后点撤销，两张卡还原且不损坏合并后新建/编辑的其他人物记录。 |
| A06 | 分别导入普通话多人抢话、电脑外放会议录音、系统识别单段（`start=0`）录音 | 多人重叠标待确认并可试听；外放录音不自动写入人物标准声纹库；单段 `start=0` 不强行整篇归人，保留声学时间线回听。 |
| A07 | 导入链接素材、语音输入、纯文字笔记、播客/大会音频 | 不自动建立陌生人或写入声纹样本，不触发飞书补下载；纯文字支持手工关联人物并标「无原音」。 |
| A08 | 在无 `ffmpeg` 环境下导入受损音频、无声纹模型状态、磁盘只读失败、取消长任务、重启重试 | 坏文件逐项报错不崩；无模型时界面可手工维护人物并给出下载引导；任务可取消且清理临时文件，重试不产生重复记录。 |
| A09 | 对已关联人物的录音执行重转写、移入回收站、恢复、彻底删除测试副本 | 重转写保留人工人物归属并重对齐文本；进回收站后人物页与摘要隐藏，恢复后复原，彻底删除后级联清理派生样本与引用。 |
| A10 | 切换 `-data-dir` 隔离库、`-demo` 与老版本 `library.json`，验证导出 Markdown 与 `beanpod-cli` | 各库完全隔离、不污染正式库；无 `Segment.end` 的老记录正常读写播放；CLI/MCP 查询与导出结果包含同步后人物名。 |
| A11 | 在人物详情页分别点击事项旁「就地试听」和录音「去文字稿查看」，再点返回 | 就地试听直接在人物页播放片段不跳页；点去文字稿直达 `tab = 1` 并滚动定位高亮；点顶部返回条回到同一人物。 |
| A12 | 断网状态使用已下载的 `sherpa-onnx` 模型跑完整新录音识别与 `≥ 1 小时` 长音频分窗测试 | 全程零外网依赖跑通；产出第 4 节要求的 RTF、峰值内存（含与 ASR/LLM 切换）及跨天分信道统计数据。 |
| A13 | 删除人物某段样本、手工编辑一条背景与待办、将一条录音设为「排除出人物」，重启后重跑分析 | 被删样本不再参与匹配，排除的录音不再出现在时间线；含「还没付 / 第三人付过」的录音正确区分主客与条件且不覆盖人工修改。 |

## 6. 提交节奏和故障处理

每个阶段完成一个独立可审查、可回退的本地提交：P0（隔离库启动参数 + 构建基线）、P1（`sherpa-onnx` 包接入 + `SpeakerEngine` 与实验测试）、P2（SQLite 人物库 + 投影同步 + `ModelDownloader` 扩展）、P3（先分人后转写流水线 + 分窗与筛选）、P4（「人物」双栏 UI + 导入与纠错撤销）、P5（`segment_indices` 摘要抽取与验收测试）。演示数据、真实人物声纹、`*.onnx` / `*.sqlite` 大文件、密钥、临时构建目录不入 Git。

模型下载失败时保留手工人物模式并报告缺项及报错；无真实标注样本时严禁调低识别门槛凑数字；同一编译或推理故障连续 3 次尝试无新证据时立即停下，汇报精确命令、完整错误输出、已排除原因和缺失条件，其余独立阶段照常推进。严禁未获授权推送远端、合入主线或修改正式录音库。

## 7. 构建、实测和交付回执

在功能分支根目录执行验证（临时构建目录可替换）：

```sh
xcodegen generate
swift test
xcodebuild -project BeanPod.xcodeproj -scheme BeanPod -configuration Debug -destination 'platform=macOS' -derivedDataPath build/friends-qa CODE_SIGNING_ALLOWED=NO build
```

启动测试 App 时严禁直接读写默认正式库，使用 `-demo` 或新建的隔离数据目录：

```sh
open -n build/friends-qa/Build/Products/Debug/BeanPod.app --args -demo -data-dir /tmp/beanpod-people-qa
```

因修改涉及 `Shared/`，同步验证 `BeanPodMobile`（iOS Simulator 27.2 SDK 已在本机核实存在）：

```sh
xcodebuild -project BeanPod.xcodeproj -scheme BeanPodMobile -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath build/friends-ios CODE_SIGNING_ALLOWED=NO build
```

最终交付回执须包含：所在分支与各阶段提交哈希、起点及改动文件清单、功能开关与关闭方式、模型来源与存放路径、隔离测试库入口、实际执行的构建/测试命令及原始结果、A01–A13 逐项结论、第 4 节跨天识别分子分母（分近场/外放信道）与误认实例、长录音 RTF 与峰值内存、剩余未验证项。附三项可视或可检查证据（人物双栏页、人物页就地试听与跨页返回、合并后重启撤销，使用虚构姓名）。未在真实 Mac App 中操作的交互项标「界面未实测」，缺真实多天录音验证的自动识别指标标「真实效果未验证」。
