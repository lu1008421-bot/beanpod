import Foundation

/// 说话人识别（声纹）所需的 ONNX 模型清单。固定仓库、固定 Revision 与 SHA‑256，
/// 下载走 `ModelDownloader`；模型统一放在 `BeanPod/Models/speaker/`（见 `App/SpeakerEngine.swift`）。
/// 本文件放 `Shared/`，Mac 与 iOS 目标都会编译，因此**不引用** Mac 专用的 `SpeakerEngine`。
nonisolated enum SpeakerModels {
    /// 说话人分割模型文件名。
    static let segmentationName = "model.onnx"
    /// 中英声纹向量（首选，192 维 CAM++）文件名。
    static let embeddingCAMPPName = "3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx"
    /// 中文声纹向量（P1 对照组，ERes2Net）文件名。
    static let embeddingERes2NetName = "3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx"

    /// 说话人分割（首选，Pyannote 3.0）。
    static let segmentation = ModelFile(
        name: segmentationName,
        repo: "csukuangfj/sherpa-onnx-pyannote-segmentation-3-0",
        revision: "9403a6902bb58e3d5ae8c7e77c3422de279db2e0",
        size: 5_992_913,
        sha256: "220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079")

    /// 说话人分割（轻量备选，int8）。
    static let segmentationInt8 = ModelFile(
        name: "model.int8.onnx",
        repo: "csukuangfj/sherpa-onnx-pyannote-segmentation-3-0",
        revision: "9403a6902bb58e3d5ae8c7e77c3422de279db2e0",
        size: 1_540_506,
        sha256: "d582f4b4c6b48205de7e0643c57df0df5615a3c176189be3fc461e9d18827b5d")

    /// 中英声纹向量（首选，192 维 CAM++）。
    static let embeddingCAMPP = ModelFile(
        name: embeddingCAMPPName,
        repo: "csukuangfj/speaker-embedding-models",
        revision: "a8055d6daef723a6a4ecf4de233708575bf4994f",
        size: 28_281_165,
        sha256: "53cab20ba8f2eb2f6e2d89ecc18e88ef3222169b61b4419cbc13666744a4574b",
        fallbackURLs: [
            URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx")!,
        ])

    /// 中文声纹向量（P1 对照组，ERes2Net）。
    static let embeddingERes2Net = ModelFile(
        name: embeddingERes2NetName,
        repo: "csukuangfj/speaker-embedding-models",
        revision: "a8055d6daef723a6a4ecf4de233708575bf4994f",
        size: 39_593_762,
        sha256: "f1ee61be04000b50392a63442e5dd9feaea7e81dddd494d3647cf1c3d88a1498",
        fallbackURLs: [
            URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx")!,
        ])

    /// 首选模型集合：分割 + CAM++。用户点「下载」时一次性装这两份。
    static let defaults: [ModelFile] = [segmentation, embeddingCAMPP]
}
