# 说话人识别实验报告（P1）

提交：见 `git log`（P1 阶段）。实测日期：2026-11-27。
本机：macOS 27.0 `arm64`，Xcode 27.2（`27B52`），Swift 6.4.2，24 GB 内存，625 GB 可用磁盘；无 `brew`/`ffmpeg`，Python 3.9.6。

## 1. 技术栈与模型

推理引擎：`sherpa-onnx` SwiftPM `v2.0.3`（静态 XCFramework，`onnxruntime-libs 1.28.2`），仅链接 Mac 目标 `BeanPod`。音频读取走系统原生 `AVAudioFile`/`AVAudioConverter`（`App/SpeakerEngine.swift::loadMono16k`），零 `ffmpeg` 依赖。

模型统一存放 `~/Library/Application Support/BeanPod/Models/speaker/`，已从 HuggingFace 直连下载并校验 SHA‑256：

| 文件 | 大小（字节） | SHA‑256 | 校验 |
|---|---|---|---|
| `model.onnx`（Pyannote 3.0 分割） | 5,992,913 | `220ad67c…e1079` | ✅ |
| `3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx`（CAM++，192 维） | 28,281,165 | `53cab20b…4574b` | ✅ |
| `3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx`（ERes2Net 对照，512 维） | 39,593,762 | `f1ee61be…a1498` | ✅ |

下载器已加 `ModelFile.fallbackURLs`（挂 GitHub Releases 直链；声纹模型 GitHub 直链与 HuggingFace 字节一致，checksum 相符），沿用断点续传、超时切源与 SHA‑256 校验。

## 2. 算法落地

- `actor SpeakerEngine`（`App/SpeakerEngine.swift`）在后台串行跑 C 推理，只把 `Sendable` 纯值（`DiarizedSegment`、`Embedding`）交回界面。
- 分割：`SherpaOnnxOfflineSpeakerDiarizationWrapper` → `(start, end, speaker)`，再两两求不同说话人时间交集，标记 `overlap`。
- 声纹：剔除非重叠、`≥1.2s`、能量 `>0.0015` 的段，`SherpaOnnxSpeakerEmbeddingExtractorWrapper` 提取归一化向量；`cosine` 判同人。
- 实验入口：`speaker-lab` 命令行工具（`tools/speaker-lab/`），独立于 SwiftUI，输出 RTF 与峰值内存。

## 3. 实测结果（公开去标识样本，非真实用户录音）

### 3.1 分割（官方 `0-four-speakers-zh.wav`，56.86 s，4 人）

- 切出 10 段、4 个说话人，边界清晰、无错误合并。
- 分割 RTF = **0.045**；声纹提取 RTF = **0.005**；峰值 RSS ≈ **238 MB**。

### 3.2 跨录音同人/异人余弦

| 模型 | 同人余弦 | 异人余弦 |
|---|---|---|
| CAM++（192 维） | 0.81（fangjun 1↔2）、0.81（leijun 1↔2） | 0.23、0.28 |
| ERes2Net（512 维，对照） | 0.80（fangjun 1↔2） | 0.13 |

结论：两套模型在公开中英样本上都能稳定区分同人（≈0.8）与异人（≤0.28），CAM++ 首选成立；ERes2Net 作中文对照可用。

## 4. 尚未验证（需真实多天录音，如实标注）

以下项因**无获参与者同意的去标识多天录音样本**，标记为「真实效果未验证」，不调低门槛凑数：

- 三档阈值（自动认作某人 / 建议确认 / 证据不足）与第一/第二候选 Margin 的正式校准；
- **近场直录 vs 系统/外放二次拾音**两条信道的余弦分数分布差异（第 4 节要求的跨天分信道分子/分母）；
- 跨天「我」与两位熟人重逢、未登记新人拒识、快速轮流接话、多人抢话重叠、`<30s` 偶发路人、电脑外放二次拾音、无原音旧文稿、播客/视频素材、损坏音频、`>1h` 拼接长音频等样本集；
- 长录音（`≥1h`）分窗后的 RTF / 峰值内存（含与 `QwenASR`/`LocalLLM` 切换时）——分窗实现在 P3。

## 5. 失败样例与已知限制

- 官方样本上未出现切分失败或声纹提取失败；重叠区间当前全部剔除不参与声纹，符合方案要求。
- 当前 `SpeakerEngine` 为离线整段加载，长音频分窗（P3）前内存随音频时长线性增长；P3 落地 `AudioTools` 分窗后缓解。
