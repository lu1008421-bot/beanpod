import Darwin
import Foundation

/// 说话人分割 / 声纹实验的命令行入口。跑在 BeanPod 之外、独立于 SwiftUI，
/// 用来测 RTF、峰值内存与声纹比对，不碰正式录音库。
///
/// 用法：
///   speaker-lab <wav> [numClusters] [threshold]      —— 分割 + 逐段声纹 + 两两余弦
///   speaker-lab compare <wav1> <wav2>                —— 两段整段声纹的余弦（跨录音比对）
/// 模型默认读 `BeanPod/Models/speaker/`（与 App 共用）。
@main
struct SpeakerLab {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            fputs("usage: speaker-lab <wav> [numClusters] [threshold]\n", stderr)
            fputs("       speaker-lab compare <wav1> <wav2>\n", stderr)
            exit(1)
        }

        if args[1] == "compare" {
            guard args.count >= 4 else { fputs("usage: speaker-lab compare <wav1> <wav2> [model]\n", stderr); exit(1) }
            let model = args.count > 4 ? args[4] : SpeakerEngine.embeddingCAMPPName
            await compare(args[2], args[3], model: model)
            return
        }

        let wavPath = args[1]
        let numClusters = args.count > 2 ? (Int(args[2]) ?? -1) : -1
        let threshold = args.count > 3 ? (Float(args[3]) ?? 0.5) : 0.5

        guard let samples = try? SpeakerEngine.loadMono16k(URL(fileURLWithPath: wavPath)), !samples.isEmpty else {
            fputs("bad audio: \(wavPath)\n", stderr)
            exit(1)
        }
        let duration = Double(samples.count) / 16000.0
        print("audio: \(wavPath)")
        print(String(format: "duration=%.2fs samples=%d numClusters=%d threshold=%.2f", duration, samples.count, numClusters, threshold))

        let engine = SpeakerEngine.shared

        let t0 = Date()
        let segments = await engine.diarize(samples: samples, numClusters: numClusters, threshold: threshold)
        let diarizeTime = Date().timeIntervalSince(t0)

        let t1 = Date()
        let embeddings = await engine.embeddings(for: samples, segments: segments)
        let embedTime = Date().timeIntervalSince(t1)

        let rtf = duration > 0 ? diarizeTime / duration : 0
        let rtfEmb = duration > 0 ? embedTime / duration : 0
        print(String(format: "diarize: %d segments in %.2fs  RTF=%.3f", segments.count, diarizeTime, rtf))
        for s in segments {
            print(String(format: "  [%7.2f - %7.2f] speaker_%d overlap=%@", s.start, s.end, s.speaker, s.overlap ? "true" : "false"))
        }
        print(String(format: "embeddings: %d in %.2fs  RTF=%.3f", embeddings.count, embedTime, rtfEmb))
        for e in embeddings {
            print(String(format: "  emb speaker_%d [%7.2f-%7.2f] dim=%d", e.speaker, e.start, e.end, e.vector.count))
        }
        if embeddings.count >= 2 {
            print("pairwise cosine:")
            for i in 0..<embeddings.count {
                for j in (i + 1)..<embeddings.count {
                    let c = SpeakerEngine.cosine(embeddings[i].vector, embeddings[j].vector)
                    print(String(format: "  speaker_%d vs speaker_%d = %.4f", embeddings[i].speaker, embeddings[j].speaker, c))
                }
            }
        }
        print(String(format: "peak RSS = %.1f MB", Self.peakRSSMB()))
    }

    static func compare(_ aPath: String, _ bPath: String, model: String) async {
        guard let a = try? SpeakerEngine.loadMono16k(URL(fileURLWithPath: aPath)), !a.isEmpty,
              let b = try? SpeakerEngine.loadMono16k(URL(fileURLWithPath: bPath)), !b.isEmpty else {
            fputs("bad audio\n", stderr)
            exit(1)
        }
        let engine = SpeakerEngine.shared
        let ea = await engine.embedWhole(a, embeddingModel: model)
        let eb = await engine.embedWhole(b, embeddingModel: model)
        guard let ea, let eb else { fputs("embedding failed\n", stderr); exit(1) }
        let c = SpeakerEngine.cosine(ea, eb)
        print("\(aPath)  vs  \(bPath)   model=\(model)")
        print(String(format: "cosine = %.4f   (dim=%d)", c, ea.count))
        print(String(format: "peak RSS = %.1f MB", Self.peakRSSMB()))
    }

    static func peakRSSMB() -> Double {
        var r = rusage()
        getrusage(RUSAGE_SELF, &r)
        return Double(r.ru_maxrss) / (1024.0 * 1024.0)
    }
}
