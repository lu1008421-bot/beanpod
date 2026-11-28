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
| `f732f88` | 返工三 | 长录音先按长度选分窗；WAV 分块读取；窗尾重叠半句去重；路径 B 缺句尾补区间 |
| `42aab83` | 返工三 | 代表原声按段入库；采纳建议只并自己的待认识卡；存量录音补分人；多人短对话不判灵感 |
| `f734dee` | 返工三 | 人物页试听可切回停止态；空库显示「我的声音」；返回条快捷键改 ⌘←；补 7 项回归单测 |
| `d7bcf03` | 返工三补充 | 试听状态首尾 0.25s 容差、只在真正播放这条这段时显示「停」、暂停即清试听状态；空库「我的声音」贴底；返回条快捷键改 ⌘⌥[；补容差单测 |
| `977c356` | 最终验收收口 | 修复人工 UI 实测 4 处问题：待认识→文字稿→返回选错人、单句改归属后旧卡仍播同句、排除录音后待认识卡仍显示、QA 启动命令加 `-demo`；新增 2 项 `carveManualRange` 单测 |
| `56a1a3d` | 合并前收口 | 修复取消排除录音后不恢复人物名：`setPeopleExcluded(false)` 重新投影发言归属；补 `testUnexcludeRestoresVoicePeople` 单测 |
| `38ed582` | 合并前收口 | 回执更新：记录 `56a1a3d` 收口结果与第 4 节合并判断 |
| `3932ff3` | 合并前收口 | 默认「建议确认」模式：`SpeakerMatcher.autoAssignEnabled=false` + `match(allowAuto:)`，高分也降级 `.suggest` 不自动落库署名；补 `testDefaultDisablesAutoAssign` |
| `0eb5566` | 合并 main | `git merge main`（`2dd2db4`，非 rebase），解决 BeanStore/Domain/Pipeline 三处冲突，保留 PR#1/3/4/5 |
| （本次提交） | 合并前收口 | 修复 `transcribeWithSpeakers` 段尾越界崩溃（`min(run.end, samples.count)`）；更新回执 |

## 2. 构建与测试（本机实测，交付前最后一轮原始结果）

```sh
swift test                                         # Test run with 22 tests passed
xcodebuild -project BeanPod.xcodeproj -scheme PeopleDBTests \
  -destination 'platform=macOS' -derivedDataPath build/people-tests \
  CODE_SIGNING_ALLOWED=NO test                     # Executed 39 tests, with 0 failures（PeopleDB 12 + SpeakerMatcher 6 + PeoplePipeline 21）
xcodebuild -project BeanPod.xcodeproj -scheme BeanPod \
  -destination 'platform=macOS' -derivedDataPath build/friends-qa \
  CODE_SIGNING_ALLOWED=NO build                    # BUILD SUCCEEDED
xcodebuild -project BeanPod.xcodeproj -scheme BeanPodMobile \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/friends-ios \
  CODE_SIGNING_ALLOWED=NO build                    # BUILD SUCCEEDED
xcodebuild -project BeanPod.xcodeproj -scheme speaker-lab \
  -derivedDataPath build/speaker-lab CODE_SIGNING_ALLOWED=NO build   # BUILD SUCCEEDED
```

PeoplePipeline 的 19 项单测覆盖：名单合并不丢模型提及人名、路径 B 交集对齐、单段 `start=0` 不整篇归人、分窗跨窗重连、人工归属重对齐、样本内容去重、单条排除、洞察编辑/软删、匹配三档与驳回；第四轮新增 7 项：采纳建议不误删另一张待认识卡且发言转给被认下的人、无待认识卡时的采纳、代表原声为独立单段、
「听一段」的状态记账、路径 B 缺句尾对齐、多人短录音不判灵感、窗尾重叠半句去重。

返工三补充（`d7bcf03`）后重跑，结果不变：`swift test` 22/22、PeopleDBTests 37/37（0 failures）、BeanPod Mac 与 BeanPodMobile iOS 模拟器均 BUILD SUCCEEDED。试听状态新增首尾容差断言（9.99/20.1 不清、8.0 清）。

最终验收收口（`977c356`）后重跑，`swift test` 22/22、PeopleDBTests 39/39（0 failures；新增 2 项 `carveManualRange`：单句改归属后旧卡只剩另一句且代表原声删空、部分重叠一分为二）、BeanPod Mac 与 BeanPodMobile iOS 模拟器均 BUILD SUCCEEDED。

合并前收口（`56a1a3d`）后重跑，`swift test` 22/22、PeopleDBTests 40/40（0 failures；新增 `testUnexcludeRestoresVoicePeople`）、BeanPod Mac / BeanPodMobile iOS 模拟器 / speaker-lab 均 BUILD SUCCEEDED。

合入 main（`0eb5566`）并修复段尾越界后重跑：`swift test` 40/40（新增 main 带来的 BeanKitTests 18 项）、PeopleDBTests 41/41（0 failures；新增 `testDefaultDisablesAutoAssign`）、BeanPod Mac / BeanPodMobile iOS 模拟器 / speaker-lab 均 BUILD SUCCEEDED。

## 3. 功能开关与关闭方式

- 人物模块为常驻一级入口（侧栏「人物」）；无声纹模型时自动回退原整段转写，不影响原有功能。
- 声纹链路：`Settings → 模型` 的「说话人识别（声纹）」下载卡（`SpeakerModels.defaults` = 分割 + CAM++），下载后自动启用路径 A；不下载则仅手动维护人物。
- 隔离库：`--args -demo -data-dir <绝对路径>`（`-demo` 关蓝牙/MCP/飞书，`-data-dir` 指临时库，二者缺一不可；只传 `-data-dir` 仍会连录音豆）或环境变量 `BEANPOD_DATA_DIR`；CLI 同样读该环境变量。

## 4. 模型来源与存放

- 分割：`csukuangfj/sherpa-onnx-pyannote-segmentation-3-0` rev `9403a69…` → `model.onnx`（5,992,913 B）
- 声纹：`csukuangfj/speaker-embedding-models` rev `a8055d6…` → CAM++（28,281,165 B，192 维）与 ERes2Net（39,593,762 B，512 维）
- 存放：`~/Library/Application Support/BeanPod/Models/speaker/`（均 SHA-256 校验通过，不入库）

## 5. 声纹实测（公开去标识样本，非用户录音）

- 分割 `0-four-speakers-zh.wav`（56.86s，4 人）→ 10 段 / 4 人；分割 RTF=0.045，声纹 RTF=0.005，峰值 RSS≈238 MB
- CAM++ 同人余弦≈0.81、异人≤0.28；ERes2Net 同人 0.80 / 异人 0.13
- 四人对话切片（102s / 186s）：同人 0.82 / 0.85，异人 0.23；1 分钟量级分人 RTF 0.038–0.07，峰值 RSS 250–270 MB
- **≥1 小时分窗**：四人文件循环 64 遍 = 3639s / 116 MB WAV，走 `diarizeWindowed` + `WindowLinker.merge`

  | | 分人耗时 | RTF | 峰值 RSS | 段数 |
  |---|---|---|---|---|
  | 返工二（先整遍跑完再分窗） | 356.14s | 0.098 | 705.3 MB | 640 |
  | 返工三（先按长度选路线 + WAV 分块读 + 窗尾去重） | 188.81s | 0.052 | 536.0 MB | 638 |

  ```
  diarize: 638 segments in 188.81s  RTF=0.052
  embeddings: 632 in 11.59s  RTF=0.003
  peak_rss_mb=536.0
  ```

  全程 4 个簇，最短一段 1.29s，跨窗没有断人或串人。64 个循环里 62 个的说话人序列一致，另 2 个只是个别相邻句的切分点不同，每句归属的人不变。
  少掉的 2 段是窗尾重叠区被截出来的 0.4 秒半句（原来和下一窗的整句重复）。整条采样仍以一个数组常驻（1 小时约 233 MB），**没有做成按窗口从文件流式读**；RTF 仍是不分窗（0.038）的 1.4 倍。
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
- **建新卡只在第 1 条上演示到一次**。后 3 条里的新声音（38.2s / 33.3s / 34.1s）都没建卡，原因是场景拦截：含「演讲」被判大会，短于 90 秒且判不出场景的被兜底成备忘。后者已在返工三改掉（两个以上说话人时不兜底成备忘），**但改后没有重跑 App 端到端**，只有单测覆盖。
- 第 6 节的实跑是返工二的数据。返工三改了代表样本的存法（一张卡最多 3 段）、采纳建议、试听状态和存量录音补分人，这些都**没有在 App 里实跑**。
- 分人模型把「我们下面播放一条雷军的测试音频」和「这个就是所有的测试音频」聚成同一簇（余弦 0.78）；speaker-lab 单跑结果与 App 内归属逐段一致，不是对齐环节的问题。

## 7. 最终验收收口（人工 UI 实测 4 处修复 + P5 真实模型实跑）

### 7.1 人工 UI 实测 4 处修复（`977c356`）

1. 待认识→文字稿→返回选错人：删除 detailPane 兜底 `.onAppear` 与 body 恢复逻辑的竞态，body `.onAppear` 统一「恢复选中 + 待认识人展开 + 无选中默认第一个」，新增 `BeanStore.personVisible(_:)`。
2. 单句改归属后旧卡仍播同句：`reassignSegment` 新增 `PeopleDB.carveManualRange`（完全落在区间删整条、部分重叠裁剪或一分为二、删旧人物该录音重叠代表样本），即时剔除旧自动归属与旧代表原声。
3. 排除录音后待认识卡仍显示可播：`pendingPeople`/`samples`/`suggestions` 过滤 `peopleExcluded`，卡片唯一来源被排除后退出待认识列表。
4. QA 启动命令：`-data-dir` 单独使用时仍连设备；统一改为 `--args -demo -data-dir <独立测试目录>`（仅注释/文档，无代码逻辑改动）。

### 7.2 P5 人物摘要真实模型实跑（隔离库，未碰正式录音库）

- 模型：`Qwen3-4B-Q4_K_M.gguf`（2,497,280,256 B），SHA-256 `7485fe6f…`（与 `Pipeline.swift` 声明一致），经 hf-mirror 下载并校验通过。
- 直连 llama-server 实测：`/health` ok；`/chat/completions`（`temperature 0.2` + `response_format=json_object` + `enable_thinking:false` + `model=local`）返回合法 `{"updates":[{person,kind,text,segment_indices}]}`。
- App 全链路（`--args -demo -data-dir /tmp/beanpod-qa-p5`，`llamaServerPath` 指向 `~/.local/bin/llama-server`）：第 1 条 `conv1.wav` 89.5s（公开四人样本拼接两人）Qwen3-ASR 转写 12 句 → 分人 2 人 → 建 2 张待认识卡 → Qwen3-4B 出纪要 → Qwen3-4B 抽人物摘要 2 条（topic，`start_ms/end_ms` 由 `segment_indices` 反查，与所属说话人句号/时间精确对应）；第 2 条 `conv2.wav` 70.7s 同一报幕声**跨录音自动认出**归入同卡（`last_met_at` 更新），另一声音归入第二张卡。全程 LocalLLM 与 SpeakerEngine/QwenASR 串行运行无 OOM、无崩溃（模型用后即停），`person_insights` 落库 2 条且 `segment_indices` 有效，界面定位依赖的起止时间已正确反查（点击未实跑）。
- 备注：`conv2` 内容为同一测试句重复，Qwen3-4B 未产出新人物摘要（非错误；`replaceAutoInsights` 按录音隔离，第 1 条摘要保留）。

### 7.3 真实样本阈值校准（阻塞）

第 3 项要求用 3–5 条真实近场/外放/多天录音跑 speaker-lab 的 CAM++/ERes2Net 同异人余弦、auto/suggest/newPerson 命中率、误归率与建议阈值，但原文「测试音频路径」是未填占位符，且约束严禁扫描正式录音库。**未获授权路径，此项未执行**；需用户提供授权录音路径后再补 `docs/speaker-experiment.md` 与第 4 节放行统计。

### 7.4 合并前最后一轮收口（UI 回归 + 取消排除修复 + 合并判断，`56a1a3d`）

**② 取消排除录音立即恢复人物名**（本轮新修复）：`setPeopleExcluded(recordingID:false)` 原先只置 `peopleExcluded=false`，不再把声纹名投回录音；现 else 分支调用 `syncPeopleToLibrary([recordingID])`（排除只挡投影、不删 utterances，发言归属仍在库，可立即投回）。补 `testUnexcludeRestoresVoicePeople`，PeopleDBTests 39→40。

**③ UI 回归复测**（GCU 实测 QA App，`-demo -data-dir /tmp/beanpod-ui-verify`，双说话人 75.7s 音频建 2 张待认识卡，全程不碰正式库与正式版 App）——8 项全部通过：

| 项 | 操作 | 结果 |
|---|---|---|
| `977c356` 修复① | 待认识卡→文字稿→返回 | 返回后仍选中原「未记名 A」✅ |
| 新交互① | 待认识卡输入姓名保存 | 「未记名 A」→「测试甲」，待认识 2→1，P5 摘要正常 ✅ |
| 新交互② | 空格暂停/切回「听」 | 播放↔暂停正确切换（无文字框聚焦前提）✅ |
| 新交互③ | 编辑标题后按 ⌘← | 不误返回，仍停在文字稿 ✅ |
| 新交互④ | 按 ⌘⌥[ 返回人物页 | 回到人物页且原卡仍选中 ✅ |
| `977c356` 修复② | 单句改归属 | DB 实测旧卡 auto utterance 9→8、代表原声样本 267–6510 被剔除，目标卡新增 1 条 manual，library.json 新增 speaker 槽位且 seg0.speaker→2 ✅ |
| `977c356` 修复③ | 排除录音→唯一来源待认识卡退出列表 | 「待认识的声音」整块消失、未记名 B 退出；测试甲样本显示「0 段」✅ |
| 本轮修复② | 取消排除录音 | 「待认识的声音（1）」恢复、未记名 B 回列，测试甲样本恢复「3 段」、时间线与摘要回显 ✅ |

**④ 最终回归与清理**：`swift test` 22/22、PeopleDBTests 40/40、BeanPod Mac / BeanPodMobile iOS 模拟器 / speaker-lab 均 BUILD SUCCEEDED；退出 QA 进程并清理 `/tmp/beanpod-ui-qa`、`/tmp/beanpod-ui-verify`、`/tmp/beanpod-r4b-verify.log`、`/tmp/beanpod-r5b.log`（保留公开样本与运行中的 `beanpod-lark.log`）。

**第 4 节逐项达标结论与合并判断**（详见第 10 节）。

## 8. A01–A13 逐项结论

图例：✅ 已验证 · ◐ 部分验证/代码就绪未实测界面 · ✖ 未验证

| 编号 | 结论 | 说明 |
|---|---|---|
| A01 | ◐ | 同名共存/样本入库/重启稳定由 PeopleDBTests 覆盖；隔离库连续导入 4 条并重启验证通过。界面鼠标操作未实测。 |
| A02 | ◐ | 跨录音自动认人已在 App 内实跑通过（3 条录音、两个不同拼接）；陌生人建卡实跑 1 次。真实多天、外放、近场效果仍待真实录音。 |
| A03 | ◐ | 命名后回写 `Recording.people/speakers/voicePeople` 已实跑验证；CLI `topics/search/show` 读到人物。 |
| A04 | ◐ | 路径 A 按说话人边界切块送 ASR 已实跑；快接话样本未实测。 |
| A05 | ◐ | `testMergeAndUndoMerge` 覆盖；界面未实测。 |
| A06 | ✅ | 路径 B 交集对齐（缺句尾先补区间）+ 单段 `start=0` 不整篇归人已实现并有单测；元数据/场景两阶段拦截实跑生效（见第 6 节）。 |
| A07 | ◐ | 元数据拦截 `eligibleForAutoSpeaker` 已实现；未接飞书补下载。 |
| A08 | ◐ | 坏文件 reject、无模型回退已实现；取消/断点重试未实测。 |
| A09 | ◐ | 重转写后 `manual` 区间按时间交集映射回新句子已有单测；回收站级联有测试。界面重转写未实测。 |
| A10 | ✅ | `-data-dir` / `BEANPOD_DATA_DIR` 实跑通过，CLI 同步读到隔离库；老库向后兼容有测试。 |
| A11 | ✅ | 跨页跳转与返回条本轮 UI 实测通过：待认识卡→文字稿→返回选回原人（`977c356`）、⌘⌥[ 返回同一人物页且选中不变、编辑标题按 ⌘← 不误返回；就地试听此前已验。 |
| A12 | ◐ | ≥1 小时分窗实测 RTF 0.052、峰值 536 MB、跨窗标签一致。仍是整条常驻内存，未做文件流式，见第 9 节。 |
| A13 | ✅ | 排除/取消排除本轮 UI 实测通过：排除录音后唯一来源待认识卡退出列表、样本显示「0 段」；取消排除后人物名立即恢复、样本回到「3 段」、时间线与摘要回显。删样本/洞察编辑/软删/试听状态已有单测；重启后重分析未再界面复测。 |

## 9. 剩余问题（如实标注）

1. **4 处 UI 修复已最终回归通过**（本轮 GCU 实测 8/8，见第 7.4 节）：待认识→文字稿→返回选回原人、单句改归属即时剔除旧样本、排除录音不再露出待认识卡、取消排除立即恢复人物名均已点验。仍未逐项点验的界面项：待认识卡就地试听、疑似确认（合并/驳回）、「我的声音」、样本抽屉播放、洞察编辑——这些仅有单测覆盖。
2. **返工三的改动只部分在 App 里实跑**：4 处 UI Bug 经人工实测发现并修复；代表样本按段入库、采纳建议只并自己的卡、存量录音补分人、多人短对话不判灵感仍只有单测 + 构建。
3. **存量录音补分人要手动触发**：对升级前转写好的录音点「重新整理纪要」时，才会补一次分人（本地有 WAV 且人物库里没有它的发言记录）。1 小时录音约 3 分钟。分不出人（全是静音等）的录音每次整理都会重试。
4. **1 小时录音的采样仍整条常驻内存**（约 233 MB），没有做成按窗口从文件流式读；分窗分人 RTF 0.052，是不分窗的 1.4 倍。
5. **分人聚类在短句上会并簇**（见第 6 节），会让「一个人」的声纹混进另一个人的向量。真实录音上的影响待按第 7.3 节校准（本轮公开样本 P5 实跑也见跨录音自动认人把两个不同测试句归入同卡，提示 auto 阈值 0.60 对干净短句可能偏宽松，需真实样本校准）。
6. **P5 人物摘要已实跑**（见第 7.2 节）：Qwen3-4B 本机跑通，`segment_indices` 反查落库正确。
7. **路径 B（云端/系统/已有文字稿）只有单测**，没有真实云端转写样本可跑。
8. **疑似确认（`speaker_suggestion`）实跑未触发**：现有样本里没有落进 suggest 档的匹配，合并/驳回流程只有单测覆盖。
9. **返工三补充的三处界面/播放小 Bug 已人工实测并修复**（试听「听/停」首帧抖动、空库侧栏 50/50 竖分、返回条 ⌘← 劫持文本行首），见第 7.1 节。
10. **真实样本阈值校准未执行**：用户未提供真实近场/外放/多天录音路径（原文为未填占位符），且严禁扫描正式录音库；第 4 节放行统计待路径。

## 10. 第 4 节逐项达标结论与合并判断

第 4 节「自动署名与全天处理的放行条件」逐项：

| 检验维度 | 达标 | 现状 |
|---|---|---|
| 名字标对（精准率） | ✖ 未验证 | 需真实跨天样本 ≥50 发言、覆盖 ≥2 天、误认 0；用户未提供路径，未执行 |
| 系统有用（召回与拒识） | ✖ 未验证 | 召回 ≥70%、陌生人误标 0；同上未执行 |
| 陌生人聚散稳定 | ◐ 部分 | 公开样本已验证：跨录音自动认人、单人循环不建卡、排除/取消排除退出与回列、单句改归属拆分；真实跨天重逢与多陌生人隔离未验证 |
| 可否日常跑全天（性能） | ✅ | ≥1 小时分窗 RTF 0.052、峰值 536 MB（公开样本拼接实测）；真实全天批次与休眠恢复未跑 |

**合并判断：可以合并主分支。**

- 代码与质量全绿：`swift test` 22/22、PeopleDBTests 40/40、BeanPod Mac / BeanPodMobile iOS 模拟器 / speaker-lab 均 BUILD SUCCEEDED；UI 回归 8/8 实测通过。
- 但第 4 节「自动署名」放行门槛未达：精准率/召回/误认三项因缺真实样本无法验证。按计划「若识别指标未过自动署名门槛，仍可先交付手动认人 + 推荐候选（关闭自动落库署名）」，**合并后应维持「建议确认」模式（不自动落库署名）**，待真实样本校准后再评估开启自动署名。
- 本轮边界：不 push 远端；未触碰正式录音库与正式版 App；已清理 /tmp 过程文件与 QA 进程。

## 11. 合并 main 前最后一轮收口（`3932ff3` + `0eb5566` + 本次提交）

### 11.1 默认「建议确认」模式（关闭自动落库署名）

- `Shared/SpeakerMatching.swift`：`SpeakerMatcher` 新增 `static let autoAssignEnabled = false`（注释注明「第 4 节真实多天样本阈值校准通过前保持关闭」）；`match(...)` 新增带默认值参数 `allowAuto: Bool = autoAssignEnabled`，auto 判定改为 `if allowAuto, best.1 >= autoThreshold, ...`。
- 关闭时（默认），即使分数 ≥ `autoThreshold`(0.60) 且满足 margin，也降级返回 `.suggest`：保留 `topCandidateID` 与 `score`，`personID = nil`，绝不自动落库署名；用户点「就是 TA」后才归属并入库确认样本。
- `Tests/PeopleDBTests/SpeakerMatcherTests.swift`：原三档用例显式传 `allowAuto: true` 保持覆盖；新增 `testDefaultDisablesAutoAssign`（高分 1.0 默认落 `.suggest`、`personID=nil`、`topCandidateID` 命中）。

### 11.2 合入 main `2dd2db4`（merge，非 rebase）

`git merge main` 带入 PR#1 飞书重试、PR#3 HTTP/MCP 安全（`MCPHTTPPolicy`/`MCPHTTPDecision`）、PR#4 流式音频导入（`AudioStream`）、PR#5 LLM 润色/分层模型路由/Token 账本。三处冲突解决：

- `Shared/BeanStore.swift` `init()`：保留 feat 的 `loadPeople()+syncPeopleToLibrary()` 并加上 main 的 `loadUsageLedger()`。
- `Shared/Domain.swift` `CodingKeys`：合并为同时含 feat 的 `voicePeople/peopleExcluded` 与 main 的 `llmTokens`（三字段均在，decode 已确认）。
- `Shared/Pipeline.swift` `runBody()`：main 把 `if/else if` 重构为 `switch decision`（`ASRRoutePolicy.resolve` 产出 `ASRPreferredEngine`）；feat 的「路径 A」`transcribeWithSpeakers` 移入 `case .qwen:` 内并用 `#if os(macOS)` 包裹（`eligibleForAutoSpeaker && speakerPipelineReady` 走声纹分人，否则 `QwenASR`；非 macOS 直接 `QwenASR`）。

自动合并文件复查（App/SettingsView.swift、App/Views.swift、Shared/Analyzer.swift、Shared/AudioTools.swift、Sources/beanpod/main.swift、project.yml）均同时含双方改动，PR#1/3/4/5 功能未丢。

### 11.3 合并后全量回归与隔离库冒烟

回归全绿（修复段尾越界后重跑）：`xcodegen generate`、`swift test` 40/40、PeopleDBTests 41/41、BeanPod Mac / BeanPodMobile iOS 模拟器 / speaker-lab 均 BUILD SUCCEEDED。

隔离库（`--args -demo -data-dir /tmp/beanpod-merge-smoke`，QA 构建）最小冒烟：

- 导入 `smoke-a`（公开四人样本拼接双说话人，加 0.5s 静音间隔，79.86s）→ 路径 A 转写 + 声纹分人成功（`Qwen3‑ASR 0.6B · 声纹分人`），建 2 张待认识卡。
- 直接改库确认其中一张为「测试甲」（`status=confirmed`、样本 `confirmed=1`）后重启，导入 `smoke-b`（同人声音，59.16s）。
- 结果：测试甲的声音在 smoke-b 里**未自动署名**（测试甲在该录音 0 条 auto 归属），而是落 `speaker_suggestion`（candidateID=测试甲、score 0.9399）等「就是 TA」确认；另一说话人同样落 suggestion（candidateID=未记名 A、score 0.9998）。即使 0.9998 也降级 `.suggest` 而非 `.auto`，验证默认关闭自动署名生效。

冒烟过程中发现并修复一处崩溃：`transcribeWithSpeakers` 中分人模型的段尾略超出音频时长（浮点/帧估算），`samples[run.start..<run.end]` 数组越界（SIGTRAP）。修复为 `let end = min(run.end, samples.count)` 并替换切片与 `Segment.end`（本提交）。修复后重建并重跑冒烟通过。

### 11.4 边界与清理

全程不 push 远端、未触碰正式录音库（51 条）与正式版 App（PID 41681 保持运行）；冒烟后退出 QA 进程并清理 `/tmp/beanpod-merge-smoke`、`/tmp/beanpod-smoke-src` 与崩溃报告；保留公开样本与运行中的 `beanpod-lark.log`。
