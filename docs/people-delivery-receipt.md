# 「人物」功能分支交付回执（feat/friends-circle）

## 1. 分支与提交

- 分支：`feat/friends-circle`（起点 `2dce45e` = `0e883bb` + 2 个 docs 提交）
- 阶段提交（按序，均可独立回退）：

| 提交 | 阶段 | 内容 |
|---|---|---|
| `0436e1c` | P0 | cherry-pick TornBottom `nonisolated`，解除 Xcode 27 编译阻塞 |
| `ff9cb62` | P0 | `-data-dir`/`BEANPOD_DATA_DIR` 隔离测试库 |
| `9994084` | P1 | 接入 sherpa-onnx + SpeakerEngine + speaker-lab 实验 |
| `928ad29` | P2 | SQLite 人物库 + 既有字段投影 |
| `9bbff7e` | P3 | 先分人后转写流水线 + 双层来源筛选 + 回收站级联 |
| `b948aa1` | P4 | 「人物」双栏 UI + 样本导入 + 单句纠错与两卡合并撤销 |
| `05e0efa` | P5 | 带 `segment_indices` 的人物背景与往来事项抽取 |
| `964d255` | 返工一 | 打通跨录音声纹匹配主链路 + 修死代码/交互 Bug + 补单测 |
| `b366fe1` | 返工二 | 人物库层：名单合并/时间对齐/分窗重连纯函数，SQL 全参数化，样本按内容去重 |
| `12e6278` | 返工二 | 修人物投影时机与名单合并、P5 摘要改串行；补路径 B 对齐、人工归属重对齐、单条排除、匹配建议 |
| `b00544c` | 返工二 | 人物页试听/语境/疑似确认/我的声音/洞察编辑/样本刷新；跨页跳文字稿；单段文字稿提示；英文文案 |
| `3ae1364` | 返工二 | 新增 12 项单测；CLI 支持 `BEANPOD_DATA_DIR` |
| `ede3db1` | 返工二 | 启动时对齐录音里的说话人标签与人物名单 |
| `45a4b8c` | 返工二 | 人物库在 iOS 上不直接引用声纹引擎（修复 iOS 构建） |

## 2. 构建与测试（本机实测，交付前最后一轮原始结果）

```sh
swift test                                         # Test run with 22 tests passed
xcodebuild -project BeanPod.xcodeproj -scheme PeopleDBTests \
  -destination 'platform=macOS' -derivedDataPath build/people-tests \
  CODE_SIGNING_ALLOWED=NO test                     # Executed 30 tests, with 0 failures（PeopleDB 12 + SpeakerMatcher 6 + PeoplePipeline 12）
xcodebuild -project BeanPod.xcodeproj -scheme BeanPod \
  -destination 'platform=macOS' -derivedDataPath build/friends-qa \
  CODE_SIGNING_ALLOWED=NO build                    # BUILD SUCCEEDED
xcodebuild -project BeanPod.xcodeproj -scheme BeanPodMobile \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/friends-ios \
  CODE_SIGNING_ALLOWED=NO build                    # BUILD SUCCEEDED
xcodebuild -project BeanPod.xcodeproj -scheme speaker-lab \
  -derivedDataPath build/speaker-lab CODE_SIGNING_ALLOWED=NO build   # BUILD SUCCEEDED
```

PeoplePipeline 新增 12 项单测覆盖：名单合并不丢模型提及人名、路径 B 交集对齐、单段 `start=0` 不整篇归人、分窗跨窗重连、人工归属重对齐、样本内容去重、单条排除、洞察编辑/软删、匹配三档与驳回。

## 3. 功能开关与关闭方式

- 人物模块为常驻一级入口（侧栏「人物」）；无声纹模型时自动回退原整段转写，不影响原有功能。
- 声纹链路：`Settings → 模型` 的「说话人识别（声纹）」下载卡（`SpeakerModels.defaults` = 分割 + CAM++），下载后自动启用路径 A；不下载则仅手动维护人物。
- 隔离库：`--args -data-dir <绝对路径>` 或环境变量 `BEANPOD_DATA_DIR`，优先于默认路径；CLI 同样读该环境变量。

## 4. 模型来源与存放

- 分割：`csukuangfj/sherpa-onnx-pyannote-segmentation-3-0` rev `9403a69…` → `model.onnx`（5,992,913 B）
- 声纹：`csukuangfj/speaker-embedding-models` rev `a8055d6…` → CAM++（28,281,165 B，192 维）与 ERes2Net（39,593,762 B，512 维）
- 存放：`~/Library/Application Support/BeanPod/Models/speaker/`（均 SHA-256 校验通过，不入库）

## 5. 声纹实测（公开去标识样本，非用户录音）

- 分割 `0-four-speakers-zh.wav`（56.86s，4 人）→ 10 段 / 4 人；分割 RTF=0.045，声纹 RTF=0.005，峰值 RSS≈238 MB
- CAM++ 同人余弦≈0.81、异人≤0.28；ERes2Net 同人 0.80 / 异人 0.13
- 四人对话切片（102s / 186s）：同人 0.82 / 0.85，异人 0.23；1 分钟量级分人 RTF 0.038–0.07，峰值 RSS 250–270 MB
- **≥1 小时分窗**：四人文件循环 64 遍 = 3639s / 116 MB WAV，走 `diarizeWindowed` + `WindowLinker.merge`

  ```
  diarize: 640 segments in 356.14s  RTF=0.098
  embeddings: 632 in 11.18s  RTF=0.003
  peak_rss_mb=705.3
  ```

  640 段的说话人序列在 64 个循环里完全一致（`0112033320`），全程只有 4 个簇，跨窗没有断人或串人；内存全程平稳（采样 706→699 MB，无增长）。代价：分窗后分人 RTF 由 0.038 升到 0.098，1 小时录音光分人约 6 分钟。
- 详见 `docs/speaker-experiment.md`

## 6. App 端到端实跑（公开音频，隔离库）

环境：QA 构建（Bundle ID `com.andyhu.beanpod.qa`，UserDefaults 独立）+ `-data-dir /tmp/beanpod-qa-e2e -demo`；正式版 App、`beanpod serve`、`~/.local/bin/beanpod` 未被触碰。

| 步骤 | 输入 | 结果（取自 `library.json` 与 `people.sqlite`） |
|---|---|---|
| 导入第 1 条 | `e2e-a-part1.wav` 102s，三人对话 | `scene=other`；说话人 0（31.8s）→ 建「未记名 A」待认识卡 + 代表片段样本 + 5 条归属；另两人 29.7s / 16.4s 未到 30s 门槛，不建卡 |
| 命名 | 「记下名字」→ 测试甲 | 人物 `status=confirmed`，样本 `confirmed=1`；重启后第 1 条 `people=['测试甲']`、`voicePeople=['测试甲']`、`speakers=['测试甲','说话人 2','说话人 3']` |
| 导入第 2 条 | `e2e-b-part2.wav` 186s，同一报幕声 + 另两人 | **自动认出**：说话人 0 的 10 段 / 23.7s 全部归到「测试甲」，`people=['测试甲']` |
| 导入第 3 条 | `e2e-c-mixed.wav` 53s，测试甲片段 + 新声音 | 「测试甲」3 段 / 9.5s 再次自动认出；`speakers=['测试甲','说话人 2']` |
| CLI | `beanpod topics / search / show` | `人物：测试甲（3）`；`search 测试甲` 命中 3 条；`show` 显示 `人物：测试甲` |

如实标注：

- **命名不是经界面完成的**。实跑时系统锁屏，GUI 自动化不可用，改为停掉 QA 版后直接改人物库（`display_name` / `status` / 样本 `confirmed`），与界面「记下名字」写入的字段一致。
- **建新卡只在第 1 条上演示到一次**。后 3 条里的新声音（38.2s / 33.3s / 34.1s）都没建卡，原因是场景拦截：含「演讲」被判大会，短于 90 秒且判不出场景的被兜底成备忘（`Analyzer.swift:167` 的既有规则）。拦截本身符合设计，但暴露出第 8 节第 2 条的问题。
- 分人模型把「我们下面播放一条雷军的测试音频」和「这个就是所有的测试音频」聚成同一簇（余弦 0.78）；speaker-lab 单跑结果与 App 内归属逐段一致，不是对齐环节的问题。

## 7. A01–A13 逐项结论

图例：✅ 已验证 · ◐ 部分验证/代码就绪未实测界面 · ✖ 未验证

| 编号 | 结论 | 说明 |
|---|---|---|
| A01 | ◐ | 同名共存/样本入库/重启稳定由 PeopleDBTests 覆盖；隔离库连续导入 4 条并重启验证通过。界面鼠标操作未实测。 |
| A02 | ◐ | 跨录音自动认人已在 App 内实跑通过（3 条录音、两个不同拼接）；陌生人建卡实跑 1 次。真实多天、外放、近场效果仍待真实录音。 |
| A03 | ◐ | 命名后回写 `Recording.people/speakers/voicePeople` 已实跑验证；CLI `topics/search/show` 读到人物。 |
| A04 | ◐ | 路径 A 按说话人边界切块送 ASR 已实跑；快接话样本未实测。 |
| A05 | ◐ | `testMergeAndUndoMerge` 覆盖；界面未实测。 |
| A06 | ✅ | 路径 B 交集对齐 + 单段 `start=0` 不整篇归人已实现并有单测；元数据/场景两阶段拦截实跑生效（见第 6 节）。 |
| A07 | ◐ | 元数据拦截 `eligibleForAutoSpeaker` 已实现；未接飞书补下载。 |
| A08 | ◐ | 坏文件 reject、无模型回退已实现；取消/断点重试未实测。 |
| A09 | ◐ | 重转写后 `manual` 区间按时间交集映射回新句子已有单测；回收站级联有测试。界面重转写未实测。 |
| A10 | ✅ | `-data-dir` / `BEANPOD_DATA_DIR` 实跑通过，CLI 同步读到隔离库；老库向后兼容有测试。 |
| A11 | ◐ | `Navigator` 跳转、`tab=1` 高亮滚动、返回条已实现并编译通过；屏幕锁定，未在界面上点过。 |
| A12 | ◐ | ≥1 小时分窗已接入并实测（RTF 0.098、峰值 705 MB、跨窗标签一致）。RTF 偏高，见第 8 节。 |
| A13 | ◐ | 删样本同时删磁盘文件、内容哈希去重、洞察编辑/软删、单条排除均已实现并有单测；界面未实测。 |

## 8. 剩余问题（如实标注）

1. **界面交互全部未实测**：待认识卡试听、出现语境、疑似确认（合并/驳回）、「我的声音」、样本抽屉单行播放、洞察编辑、单条排除开关、跨页高亮与返回条——只做到编译通过，屏幕锁定没法点。下一轮需先人工过一遍人物页。
2. **短录音建卡被场景兜底误拦**：`Analyzer.swift:167`「判不出场景且 <90 秒 → 备忘」会把多人短对话判成备忘而不建卡。建议改为「分人结果里有两个及以上说话人各 ≥30s 时不走备忘兜底」。本轮未改（不在清单内）。
3. **分窗后分人 RTF 0.098**，是不分窗（0.038）的 2.6 倍，1 小时录音要等约 6 分钟。可排查每窗重复初始化分割器的开销。
4. **分人聚类在短句上会并簇**（见第 6 节），会让「一个人」的声纹混进另一个人的向量。真实录音上的影响待校准。
5. **P5 人物摘要未实跑**：本机 Qwen3-4B 未下载；串行化改动只有编译与代码路径保证。
6. **路径 B（云端/系统/已有文字稿）只有单测**，没有真实云端转写样本可跑。
7. **疑似确认（`speaker_suggestion`）实跑未触发**：4 条录音里没有落进 suggest 档的匹配，合并/驳回流程只有单测覆盖。
