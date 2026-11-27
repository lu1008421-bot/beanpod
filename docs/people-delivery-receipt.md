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

改动文件（相对起点共 21 个，`git diff --stat 2dce45e..HEAD`）：
`.gitignore`、`App/{NotchShow,PeopleView,SpeakerEngine,Views}.swift`、`Shared/{AudioTools,BeanStore,Domain,ModelDownloader,People,PeopleDB,PeopleInsights,PeopleStore,Pipeline,SpeakerModels,SpeakerPipeline,Trash}.swift`、`Tests/PeopleDBTests/PeopleDBTests.swift`、`docs/speaker-experiment.md`、`project.yml`、`tools/speaker-lab/SpeakerLab.swift`。

## 2. 构建与测试（本机实测，原始结果）

```sh
xcodegen generate                                  # 通过
swift test                                         # BeanKit 22 项全部通过
xcodebuild -project BeanPod.xcodeproj -scheme PeopleDBTests \
  -destination 'platform=macOS' -derivedDataPath build/people-tests \
  CODE_SIGNING_ALLOWED=NO test                     # 9 项全部通过
xcodebuild -project BeanPod.xcodeproj -scheme BeanPod \
  -destination 'platform=macOS' -derivedDataPath build/friends-qa \
  CODE_SIGNING_ALLOWED=NO build                    # BUILD SUCCEEDED
xcodebuild -project BeanPod.xcodeproj -scheme BeanPodMobile \
  -destination 'generic/platform=iOS' -derivedDataPath build/friends-ios \
  CODE_SIGNING_ALLOWED=NO build                    # BUILD SUCCEEDED
```

隔离库冒烟：`open -n build/friends-qa/.../BeanPod.app --args -data-dir /tmp/beanpod-p4-qa` 后，仅在 `/tmp/beanpod-p4-qa/` 生成 `Recordings/`、`Inbox/`、`People/people.sqlite(+wal/shm)`，正式库 `~/Library/Application Support/BeanPod/` 未被动。

## 3. 功能开关与关闭方式

- 人物模块为常驻一级入口（侧栏「人物」）；无声纹模型时自动回退原整段转写，不影响原有功能。
- 声纹链路：`Settings` 下载「说话人识别（声纹）」模型后自动启用路径 A；不下载则仅手动维护人物。
- 隔离库：`--args -data-dir <绝对路径>` 或环境变量 `BEANPOD_DATA_DIR`，优先于默认路径。

## 4. 模型来源与存放

- 分割：`csukuangfj/sherpa-onnx-pyannote-segmentation-3-0` rev `9403a69…` → `model.onnx`（5,992,913 B）
- 声纹：`csukuangfj/speaker-embedding-models` rev `a8055d6…` → CAM++（28,281,165 B，192 维）与 ERes2Net（39,593,762 B，512 维）
- 存放：`~/Library/Application Support/BeanPod/Models/speaker/`（均 SHA-256 校验通过，不入库）

## 5. 声纹实验实测（P1，公开去标识样本，非用户录音）

- 分割 `0-four-speakers-zh.wav`（56.86s，4 人）→ 10 段 / 4 人
- 分割 RTF=0.045，声纹 RTF=0.005，峰值 RSS≈238 MB
- CAM++ 同人余弦≈0.81、异人≤0.28；ERes2Net 同人 0.80 / 异人 0.13
- 详见 `docs/speaker-experiment.md`

## 6. A01–A13 逐项结论

图例：✅ 已验证 · ◐ 部分验证/代码就绪未实测界面 · ✖ 未验证

| 编号 | 结论 | 说明 |
|---|---|---|
| A01 | ◐ | 同名共存/样本入库/重启稳定已由 PeopleDBTests 覆盖；`-data-dir` 隔离冒烟通过。双栏「建两人+导入音频」的鼠标操作未实测。 |
| A02 | ✖ | 无授权多天去标识样本，跨天自动认人、路人门槛、待认识折叠「真实效果未验证」。 |
| A03 | ◐ | `namePendingPerson→syncPeopleToLibrary` 回写 `Recording.people/speakers` 已实现（KnowledgeView 复用 allPeople）；无样本实测。 |
| A04 | ◐ | 路径 A「按说话人边界切块送 ASR」与 `reassignSegment`（manual 优先）已实现；无授权快接话样本实测。 |
| A05 | ◐ | 数据层合并/撤销已由 `testMergeAndUndoMerge` 验证（编号不回收、派生数据还原）；重启后撤销与界面未实测。 |
| A06 | ◐ | 重叠标记 `markOverlaps`、外放 `speaker_loopback` 不写标准声纹库、第一层筛选均已实现；路径 B「单段 start=0 不整篇归人」尚未实现。 |
| A07 | ◐ | 元数据拦截 `eligibleForAutoSpeaker` 已实现；未接飞书补下载。无样本实测。 |
| A08 | ◐ | 坏文件 `decodeAnyAudio→reject`、无模型回退普通转写已实现；取消/断点重试未实测。 |
| A09 | ◐ | 回收站彻底删除级联 `purgePeopleForRecording` 已实现并测试；「重转写保留人工区间归属」「隐藏/恢复时间线」尚未实现。 |
| A10 | ◐ | `-data-dir` 隔离已验证；老 `library.json`（无 `Segment.end`）`decodeIfPresent` 向后兼容已实现；CLI/MCP 未实测。 |
| A11 | ◐ | 就地试听 `play(id, at:)` 与「去文字稿」`nav.open(id)` 已接；`tab=1` 定位高亮与返回条未实现。 |
| A12 | ✖ | 模型已本地化（零外网可跑），分割/声纹 RTF 与内存见第 5 节；≥1 小时长音频分窗 RTF/内存「真实效果未验证」（无样本，且分窗仅 `windowedRanges` 辅助、未接入 SpeakerEngine 流式）。 |
| A13 | ◐ | 删样本 `deleteSample` 已实现；`edited_by_user` 标记已落库，但「重跑不覆盖已删项」「排除出人物」未实现。 |

## 7. 第 4 节跨天分信道识别统计

无授权多天去标识样本，近场/外放两信道「分子 / 分母 / 样本量」均无法产出，标「真实效果未验证」，未调低门槛凑数。

## 8. 剩余未验证/未实现项（如实标注）

1. A02/A12/A13 依赖的跨天、外放、长音频、多人重叠真实样本缺失 → 识别指标未验证。
2. 路径 B（云端/系统/已有文稿）按声学区间与 Segment 交集绑定人物、单段 `start=0` 防整篇误归：未实现。
3. 重转写保留人工区间归属并重对齐：未实现（当前 `replaceUtterances` 会重建 auto 归属）。
4. 长音频分窗流式推理：仅 `windowedRanges` 辅助，未接入 SpeakerEngine（仍整段加载）。
5. 双栏界面、样本导入、单句纠错、合并撤销、就地试听、跨页返回等交互项：**界面未实测**（未做 GUI 自动化；数据层均已建并有单测覆盖）。
6. P5 人物摘要推理：**真实效果未验证**（本机 Qwen3-4B 模型未下载，代码与 `segment_indices` 协议已就绪）。
