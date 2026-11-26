import AVFoundation
import AppKit
import SwiftUI

/// 刘海动画（分镜 design/ui/ui_notch_anim.png）：
/// - 探头：开始录音时，刘海往下长出一个黑色小兜，小豆从刘海后面弹出来探个头，两边的计时和声波亮起来，两秒多后缩回去，只留耳朵。
/// - 打印：录完时刘海像热敏打印机的出纸口，「滋——」一格一格吐出一截胶片（这次录音的声波、时长、时间），
///   一把小剪刀「咔嚓」剪断，胶片转着飘下去，旁边冒一句「已存进豆仓」。
/// 整段动画按「开始后过了几秒」逐帧算出来，不靠一串 withAnimation：时间可以定住（调试时定格中间帧），也不会被别的状态打断成半截。
extension NotchPanel {
    enum Show: Equatable {
        case peek
        case printing(Ticket)

        var duration: Double {
            switch self {
            case .peek: 2.7
            case .printing: 3.7
            }
        }
    }

    /// 打印出来的那截胶片上印的东西
    struct Ticket: Equatable {
        var title: String
        var date: Date
        var wave: [Float]
    }

    /// 调试用：`defaults write com.andyhu.beanpod NotchShowFreezeAt 0.6` 把动画定在第 0.6 秒，删掉这个值恢复
    static var freezeAt: Double? {
        let v = UserDefaults.standard.double(forKey: "NotchShowFreezeAt")
        return v > 0 ? v : nil
    }

    /// 把整段录音的音量压成 n 根柱子，最高的一根顶满。没有音量（录音豆录的）就给一段像说话的起伏。
    static func squeeze(_ wave: [Float], to n: Int) -> [Float] {
        guard wave.count >= 4, let top = wave.max(), top > 0.0001 else {
            return (0..<n).map { i -> Float in
                let x = Double(i)
                let wobble: Double = abs(sin(x * 1.7) * cos(x * 0.6))
                return Float(0.35 + 0.55 * wobble)
            }
        }
        return (0..<n).map { i in
            let a = i * wave.count / n, b = max(a + 1, (i + 1) * wave.count / n)
            let peak = wave[a..<min(b, wave.count)].max() ?? 0
            return max(0.12, min(1, peak / top))
        }
    }
}

// MARK: - 画面

struct NotchShowView: View {
    let show: NotchPanel.Show
    let start: Date
    let notch: CGSize
    let size: CGSize
    /// 探头时上面那一条（计时和声波），和录音中的耳朵一模一样
    let ears: AnyView

    private let rose = Theme.rec

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = NotchPanel.freezeAt ?? ctx.date.timeIntervalSince(start)
            switch show {
            case .peek: peek(t)
            case .printing(let ticket): printing(t, ticket)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
    }

    // MARK: 探头

    private func peek(_ t: Double) -> some View {
        let earsW = notch.width + 2 * 92
        let pocketW = max(notch.width + 28, 150)
        let pocketFull: CGFloat = 72
        // 小兜：0.35 秒长出来（带一点回弹），2.25 秒开始收
        let grow = Ease.backOut(Ease.clamp(t / 0.35))
        let shrink = Ease.inOut(Ease.clamp((t - 2.25) / 0.4))
        let pocketH = pocketFull * CGFloat(grow * (1 - shrink))
        // 上面那一条从刘海宽变到耳朵宽
        let stripW = notch.width + (earsW - notch.width) * CGFloat(Ease.out(Ease.clamp(t / 0.3)))
        // 小豆：藏在小兜下沿后面 → 往上探出头（耳朵、眼睛先露出来）→ 停住 → 2.2 秒缩回去。
        // 刘海那一截被屏幕上的摄像头挡着看不见，所以只能从下沿往上探，不能从上往下掉
        let hamster: CGFloat = 120
        let hidden = notch.height + pocketFull
        let rest = notch.height + pocketFull - 78
        let down = Ease.spring(t - 0.12)
        let up = Ease.inOut(Ease.clamp((t - 2.2) / 0.35))
        let y = hidden + (rest - hidden) * CGFloat(down) * CGFloat(1 - up)
        let earsIn = Ease.clamp((t - 0.35) / 0.25)

        return ZStack(alignment: .top) {
            UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10)
                .fill(.black).frame(width: stripW, height: notch.height)
            ZStack(alignment: .top) {
                Color.black
                MascotArtImage.listening
                    .resizable().interpolation(.high)
                    .frame(width: hamster, height: hamster)
                    .offset(y: y)
            }
            .frame(width: pocketW, height: notch.height + pocketH, alignment: .top)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 22 * min(1, pocketH / 30), bottomTrailingRadius: 22 * min(1, pocketH / 30)))
            ears.frame(width: earsW, height: notch.height).opacity(earsIn)
            // 落定那一下的三道小动势线
            motionLines(t, below: notch.height + pocketH)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func motionLines(_ t: Double, below y: CGFloat) -> some View {
        let p = Ease.clamp((t - 0.42) / 0.3)
        return HStack(spacing: 7) {
            ForEach(0..<3, id: \.self) { i in
                Capsule().fill(.white).frame(width: 1.6, height: i == 1 ? 9 : 7).rotationEffect(.degrees(Double(i - 1) * 18))
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 1)
        .opacity(p > 0 && p < 1 ? 0.85 * sin(p * .pi) : 0)
        .offset(y: y + 4 + 4 * CGFloat(p))
    }

    // MARK: 打印胶片

    private func printing(_ t: Double, _ ticket: NotchPanel.Ticket) -> some View {
        let mouthW = max(notch.width, 150)
        let lip = 12 * CGFloat(Ease.out(Ease.clamp(t / 0.25)) * (1 - Ease.inOut(Ease.clamp((t - 3.35) / 0.3))))
        let mouth = notch.height + lip
        let paper = CGSize(width: 118, height: 126)
        // 热敏打印：16 格，每一格先快推一下再停一下
        let p = Ease.clamp((t - 0.3) / 1.6) * 16
        let fed = (floor(p) + Ease.out(min(1, (p - floor(p)) / 0.4))) / 16
        let shown = paper.height * CGFloat(min(1, fed))
        let printing = t > 0.3 && t < 1.9
        let jitter: CGFloat = printing ? 0.5 * CGFloat(sin(t * 90)) : 0
        // 2.15 秒剪断，之后往下转着飘走
        let cut = 2.15
        let fall = Ease.inQuad(Ease.clamp((t - cut) / 1.15))
        let fade = 1 - Ease.clamp((t - 2.95) / 0.35)

        return ZStack(alignment: .top) {
            // 胶片放在和窗口一样大的底板上再遮罩，遮罩的坐标才是窗口坐标
            ZStack(alignment: .top) {
                Paper(ticket: ticket, size: paper, rose: rose)
                    .rotationEffect(.degrees(13 * fall))
                    .offset(x: jitter + 22 * CGFloat(fall), y: mouth - paper.height + shown + 150 * CGFloat(fall))
                    .opacity(fade)
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .mask(alignment: .top) {
                // 剪断之前只露出出纸口下面的部分
                Rectangle().padding(.top, t < cut ? mouth : 0)
            }
            UnevenRoundedRectangle(bottomLeadingRadius: lip > 2 ? 14 : 10, bottomTrailingRadius: lip > 2 ? 14 : 10)
                .fill(.black).frame(width: mouthW, height: mouth)
            scissors(t, cut: cut, y: mouth)
            zi(t).offset(x: paper.width / 2 + 34, y: mouth + 30)
            saved(t, cut: cut).offset(x: paper.width / 2 + 58, y: mouth + 46)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// 出纸口里的小剪刀：整把待在黑色里（白剪刀压在米白纸上看不见），从右往左横着剪过去，
    /// 剪到正中那一刻「咔嚓」缩一下、冒三道小火花，然后淡掉
    private func scissors(_ t: Double, cut: Double, y: CGFloat) -> some View {
        let appear = Ease.clamp((t - 1.85) / 0.12) * (1 - Ease.clamp((t - 2.4) / 0.2))
        let across = Ease.inOut(Ease.clamp((t - 1.9) / 0.5))
        let snip = 1 - 0.2 * sin(.pi * Ease.clamp((t - cut) / 0.12))
        let spark = Ease.clamp((t - cut) / 0.25)
        return ZStack {
            Image(systemName: "scissors").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .scaleEffect(snip)
                .offset(x: 52 - 104 * CGFloat(across))
                .opacity(appear)
            ForEach(0..<3, id: \.self) { i in
                Capsule().fill(.white).frame(width: 1.5, height: 5)
                    .offset(y: -11)
                    .rotationEffect(.degrees(Double(i - 1) * 50))
                    .scaleEffect(0.8 + 0.6 * spark)
                    .opacity(spark > 0 && spark < 1 ? 1 - spark : 0)
            }
            .offset(y: 4)
        }
        .offset(y: y - 13)
    }

    /// 「滋——」：打印的那一段在纸边上抖着
    private func zi(_ t: Double) -> some View {
        let on = Ease.clamp((t - 0.45) / 0.15) * (1 - Ease.clamp((t - 1.85) / 0.2))
        return Text("滋——").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.black.opacity(0.55), in: .capsule)
            .offset(x: on > 0 ? CGFloat(sin(t * 70)) * 0.8 : 0)
            .opacity(on)
    }

    private func saved(_ t: Double, cut: Double) -> some View {
        let pop = Ease.backOut(Ease.clamp((t - cut - 0.15) / 0.3))
        let out = Ease.clamp((t - 3.2) / 0.3)
        return HStack(spacing: 5) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(rose)
            Text("已存进豆仓").foregroundStyle(.black.opacity(0.82))
        }
        .font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.white, in: .capsule)
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .scaleEffect(0.7 + 0.3 * pop, anchor: .leading)
        .opacity(pop * (1 - out))
    }
}

/// 胶片：米白热敏纸，两边齿孔，下沿锯齿，印着声波、标题和时间
private struct Paper: View {
    let ticket: NotchPanel.Ticket
    let size: CGSize
    let rose: Color

    var body: some View {
        VStack(spacing: 7) {
            Spacer(minLength: 10)
            HStack(alignment: .center, spacing: 2.2) {
                ForEach(Array(NotchPanel.squeeze(ticket.wave, to: 18).enumerated()), id: \.offset) { _, v in
                    Capsule().fill(rose).frame(width: 2.6, height: max(3, 26 * CGFloat(v)))
                }
            }
            .frame(height: 28)
            Text(ticket.title).font(.system(size: 12, weight: .bold)).foregroundStyle(.black.opacity(0.85))
            Text(ticket.date.formatted(.dateTime.month().day().hour().minute()))
                .font(.system(size: 9.5, weight: .medium)).foregroundStyle(.black.opacity(0.45))
            Spacer(minLength: 14)
        }
        .padding(.horizontal, 14)
        .frame(width: size.width, height: size.height)
        .background(Color(red: 0.985, green: 0.968, blue: 0.94))
        .overlay(alignment: .leading) { holes.padding(.leading, 4) }
        .overlay(alignment: .trailing) { holes.padding(.trailing, 4) }
        .clipShape(TornBottom())
        .shadow(color: .black.opacity(0.22), radius: 3, y: 1.5)
    }

    private var holes: some View {
        VStack(spacing: 6) {
            ForEach(0..<11, id: \.self) { _ in Circle().fill(.black.opacity(0.12)).frame(width: 3.2, height: 3.2) }
        }
    }
}

/// 下沿锯齿：像从纸卷上撕下来的
private nonisolated struct TornBottom: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: .zero)
        p.addLine(to: CGPoint(x: r.maxX, y: 0))
        let teeth = 12, depth: CGFloat = 4
        let w = r.width / CGFloat(teeth)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - depth))
        for i in stride(from: teeth, to: 0, by: -1) {
            p.addLine(to: CGPoint(x: CGFloat(i) * w - w / 2, y: r.maxY))
            p.addLine(to: CGPoint(x: CGFloat(i - 1) * w, y: r.maxY - depth))
        }
        p.closeSubpath()
        return p
    }
}

/// 小豆「在听」那张图
private enum MascotArtImage {
    static let listening: Image = {
        let url = Bundle.main.url(forResource: "xiaodou_listening", withExtension: "png")
        return Image(nsImage: url.flatMap { NSImage(contentsOf: $0) } ?? NSImage())
    }()
}

/// 动画用的几条缓动曲线。输入都是 0…1（spring 除外，它吃的是秒）。
enum Ease {
    static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    static func out(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    static func inQuad(_ x: Double) -> Double { x * x }
    static func inOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
    static func backOut(_ x: Double) -> Double {
        let c1 = 1.4, c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }
    /// 欠阻尼弹簧（阻尼比约 0.55，0.45 秒左右落定）：t 秒时走到了终点的几成，会稍微冲过头再弹回来
    static func spring(_ t: Double) -> Double {
        guard t > 0 else { return 0 }
        let zeta = 0.55, omega = 2 * Double.pi / 0.42
        let wd = omega * sqrt(1 - zeta * zeta)
        return 1 - exp(-zeta * omega * t) * (cos(wd * t) + zeta * omega / wd * sin(wd * t))
    }
}

// MARK: - 声音

/// 打印的「滋——」和剪断的「咔嚓」：现场合成一小段声音，不带音频文件。和画面同一时刻开始，节拍对得上。
@MainActor
final class PrintSound {
    static let shared = PrintSound()
    private var player: AVAudioPlayer?
    private lazy var data: Data = Self.render()

    func play() {
        player = try? AVAudioPlayer(data: data)
        player?.volume = 0.32
        player?.play()
    }

    /// 和 NotchShowView.printing 的时间线一致：0.3 秒起 16 格「滋」，2.15 秒「咔嚓」两下
    private static func render() -> Data {
        let rate = 44_100, total = Int(2.5 * Double(rate))
        var samples = [Float](repeating: 0, count: total)
        var seed: UInt32 = 0x9E3779B9
        func noise() -> Float {
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            return Float(seed) / Float(UInt32.max) * 2 - 1
        }
        // 热敏头：每格前 45 毫秒是一阵带音调的沙沙声
        for step in 0..<16 {
            let begin = Int((0.3 + Double(step) * 0.1) * Double(rate)), length = Int(0.045 * Double(rate))
            var low: Float = 0
            for i in 0..<length where begin + i < total {
                let env = sin(Float.pi * Float(i) / Float(length))
                low += 0.35 * (noise() - low)        // 去掉最刺耳的高频
                let tone = sin(2 * Float.pi * 1900 * Float(i) / Float(rate))
                samples[begin + i] += env * (0.55 * low + 0.25 * tone * low)
            }
        }
        // 剪刀：两下很短的脆响
        for (at, gain) in [(2.15, Float(0.9)), (2.2, Float(0.6))] {
            let begin = Int(at * Double(rate)), length = Int(0.025 * Double(rate))
            for i in 0..<length where begin + i < total {
                samples[begin + i] += gain * noise() * exp(-Float(i) / Float(length) * 6)
            }
        }
        // 写成 16 位单声道 WAV
        var pcm = Data(capacity: total * 2)
        for s in samples {
            var v = Int16(max(-1, min(1, s)) * 32_000).littleEndian
            withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
        }
        var wav = Data()
        func put<T: FixedWidthInteger>(_ x: T) { var v = x.littleEndian; withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + pcm.count))
        wav.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
        wav.append(contentsOf: Array("data".utf8)); put(UInt32(pcm.count))
        wav.append(pcm)
        return wav
    }
}
