import Foundation

/// 「最近删除」里的一条：删掉时整条录音的记录（文字稿、纪要、标签、标记、改写、做的视频都在里面）
/// 和它的文件（音频、画面、成片、封面），文件挪到录音库旁边的 Trash/<folder>/ 里。
nonisolated struct TrashedRecording: Codable, Identifiable, Equatable {
    var id = UUID()
    var recording: Recording
    var deletedAt: Date
    /// Trash/ 下面放这一条文件的子文件夹。
    var folder: String
    /// 挪进去的文件名（原来的名字，恢复时原样挪回去）。
    var files: [String]

    static let keepDays = 7
    var expires: Date { deletedAt.addingTimeInterval(Double(Self.keepDays) * 86_400) }

    /// 还剩几天（按日历天算：今天到期是 0，明天到期是 1）。
    func daysLeft(now: Date = .now) -> Int {
        let cal = Calendar.current
        return max(0, cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: expires)).day ?? 0)
    }
}

/// 本机删除先进「最近删除」，放 7 天，期间可以原样恢复；到期自动彻底删除。
/// 从录音豆、录音卡上删除不走这里：设备上的文件删了就没了，那两处照旧先确认。
extension BeanStore {
    var trashFolder: URL { folder.appendingPathComponent("Trash", isDirectory: true) }
    private var trashURL: URL { folder.appendingPathComponent("trash.json") }

    func loadTrash() {
        guard let data = try? Data(contentsOf: trashURL),
              let list = try? JSONDecoder().decode([TrashedRecording].self, from: data) else { return }
        trash = list
    }

    func saveTrash() {
        if let data = try? JSONEncoder().encode(trash) { try? data.write(to: trashURL, options: .atomic) }
    }

    /// 这条录音在录音库文件夹里的所有文件：`<id>.ogg/.wav/.video.mp4/.video.jpg`、做的视频 `<id>-video-…`。
    private func files(of id: UInt32) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasPrefix("\(id).") || $0.hasPrefix("\(id)-video-") }
    }

    /// 把一条录音移到「最近删除」。返回这一条在最近删除里的编号（撤销用）。
    @discardableResult
    func moveToTrash(_ id: UInt32) -> UUID? {
        guard let i = recordings.firstIndex(where: { $0.id == id }), recordings[i].downloaded else { return nil }
        if playingID == id { stop() }
        let fm = FileManager.default
        let sub = "\(id)-\(Int(Date.now.timeIntervalSince1970))-\(UUID().uuidString.prefix(4))"
        let dest = trashFolder.appendingPathComponent(sub, isDirectory: true)
        do { try fm.createDirectory(at: dest, withIntermediateDirectories: true) } catch {
            addLog("最近删除的文件夹建不了：\(error.localizedDescription)")
            problem = Problem(title: String(localized: "没能删除"), detail: String(localized: "「最近删除」的文件夹建不了：\(error.localizedDescription)"))
            return nil
        }
        var moved: [String] = []
        for name in files(of: id) {
            do { try fm.moveItem(at: folder.appendingPathComponent(name), to: dest.appendingPathComponent(name)); moved.append(name) }
            catch { addLog("挪进最近删除失败 \(name)：\(error.localizedDescription)") }
        }
        var rec = recordings[i]
        rec.onDevice = false; rec.inProgress = false
        let entry = TrashedRecording(recording: rec, deletedAt: .now, folder: sub, files: moved)
        trash.insert(entry, at: 0)
        saveTrash()
        // 和以前一样：录音豆里还有原件的，列表里留一条「没下载」的；没有的就从列表拿掉
        if recordings[i].onDevice {
            recordings[i] = Recording(id: id, size: recordings[i].size, date: recordings[i].date, duration: recordings[i].duration, onDevice: true)
        } else {
            recordings.remove(at: i)
        }
        saveLibrary()
        addLog("移到最近删除：\(id)（\(moved.count) 个文件）")
        return entry.id
    }

    /// 移到最近删除，并在顶上提示一条带「撤销」的。
    func trashWithUndo(_ ids: [UInt32]) {
        let entries = ids.compactMap { moveToTrash($0) }
        guard !entries.isEmpty else { return }
        toast("trash", entries.count == 1 ? String(localized: "已移到最近删除") : String(localized: "已把 \(entries.count) 条移到最近删除"), undo: entries)
    }

    /// 原样恢复：文件挪回去，记录（文字稿、纪要、标签……）放回录音库。
    func restore(_ entryIDs: [UUID]) {
        var restored = 0
        for entryID in entryIDs {
            guard let k = trash.firstIndex(where: { $0.id == entryID }) else { continue }
            let entry = trash[k]
            let fm = FileManager.default
            let src = trashFolder.appendingPathComponent(entry.folder, isDirectory: true)
            for name in entry.files {
                let to = folder.appendingPathComponent(name)
                // 这期间又从录音豆下载过同一条：用回删掉前的那份（同一段录音），新下的那份让位
                if fm.fileExists(atPath: to.path) { try? fm.removeItem(at: to) }
                do { try fm.moveItem(at: src.appendingPathComponent(name), to: to) }
                catch { addLog("恢复文件失败 \(name)：\(error.localizedDescription)") }
            }
            try? fm.removeItem(at: src)
            var rec = entry.recording
            rec.downloaded = true
            if let i = recordings.firstIndex(where: { $0.id == rec.id }) {
                rec.onDevice = recordings[i].onDevice
                recordings[i] = rec
            } else {
                recordings.append(rec)
            }
            trash.remove(at: k)
            restored += 1
            addLog("从最近删除恢复：\(rec.id)")
        }
        guard restored > 0 else { return }
        recordings.sort { ($0.date ?? .distantPast, $0.id) > ($1.date ?? .distantPast, $1.id) }
        saveLibrary()
        saveTrash()
    }

    /// 彻底删除（不能恢复）。
    func deleteForever(_ entryIDs: [UUID]) {
        for entryID in entryIDs {
            guard let k = trash.firstIndex(where: { $0.id == entryID }) else { continue }
            let recID = trash[k].recording.id
            try? FileManager.default.removeItem(at: trashFolder.appendingPathComponent(trash[k].folder, isDirectory: true))
            purgePeopleForRecording(recID)   // 人物库里的发言归属、资料、声音样本跟着级联清理
            addLog("彻底删除：\(recID)")
            trash.remove(at: k)
        }
        saveTrash()
    }

    func emptyTrash() { deleteForever(trash.map(\.id)) }

    /// 到期的彻底删掉。启动时做一次，之后每隔几个小时做一次。
    func purgeTrash() {
        let expired = trash.filter { $0.expires <= .now }.map(\.id)
        if !expired.isEmpty { addLog("最近删除里有 \(expired.count) 条放满 7 天，彻底删除"); deleteForever(expired) }
    }
}
