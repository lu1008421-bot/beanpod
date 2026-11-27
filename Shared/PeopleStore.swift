import CryptoKit
import Foundation

/// 人物库与录音库的桥接：把跨录音的人物身份投影回 `Recording.people` / `Recording.speakers`，
/// 让纪要页底栏人物芯片、知识库人物筛选、Markdown 导出与 CLI/MCP 无需兼容层即可生效。
extension BeanStore {
    /// 打开人物库并把人物读进内存。打开失败降级为 nil（记录错误、不阻断原有转写/播放）。
    func loadPeople() {
        do {
            let db = try PeopleDB(folder: dataRoot.appendingPathComponent("People", isDirectory: true))
            peopleDB = db
            people = (try? db.listPersons()) ?? []
            peopleError = nil
        } catch {
            peopleDB = nil
            people = []
            peopleError = error.localizedDescription
            addLog("人物库不可用：\(error.localizedDescription)")
        }
    }

    /// 把人物身份投影回录音库：更新 `Recording.people`（去重后的已确认人名）与
    /// `Recording.speakers`（说话人显示名投影），并写回 `library.json`。
    /// - Parameter ids: 只同步这些录音；nil 表示全部。
    func syncPeopleToLibrary(_ ids: [UInt32]? = nil) {
        guard let db = peopleDB else { return }
        let personsByID = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })
        let targets: [Int]
        if let ids {
            targets = recordings.indices.filter { ids.contains(recordings[$0].id) }
        } else {
            targets = Array(recordings.indices)
        }
        for i in targets {
            let rec = recordings[i]
            let utterances = (try? db.listUtterances(recordingID: rec.id)) ?? []
            guard !utterances.isEmpty else { continue }

            // localSpeaker → personID；人工指定优先于自动
            var speakerPerson: [Int: UUID] = [:]
            for u in utterances {
                guard let pid = u.personID else { continue }
                if speakerPerson[u.localSpeaker] == nil || u.source == "manual" { speakerPerson[u.localSpeaker] = pid }
            }

            // Recording.people：去重后的已确认人物名，按出现顺序
            var seen = Set<String>()
            var names: [String] = []
            for idx in speakerPerson.keys.sorted() {
                guard let pid = speakerPerson[idx], let p = personsByID[pid],
                      p.status == .confirmed, !p.displayName.isEmpty else { continue }
                if seen.insert(p.displayName).inserted { names.append(p.displayName) }
            }
            recordings[i].people = names

            // Recording.speakers：显示名投影（已确认用名字，待认识用内部编号，其余保留）
            let speakerCount = max(rec.speakers.count, (speakerPerson.keys.max() ?? -1) + 1)
            var speakers = rec.speakers
            while speakers.count < speakerCount { speakers.append(String(localized: "说话人 \(speakers.count + 1)")) }
            for idx in 0..<speakerCount {
                guard let pid = speakerPerson[idx], let p = personsByID[pid] else { continue }
                if p.status == .confirmed, !p.displayName.isEmpty {
                    speakers[idx] = p.displayName
                } else if p.status == .pending {
                    speakers[idx] = String(localized: "未记名 \(p.strangerLabel)")
                }
            }
            recordings[i].speakers = speakers
        }
        saveLibrary()
    }

    /// 新建人物（写库 + 更新内存）。返回新人物 id。
    @discardableResult
    func createPerson(name: String, status: PersonStatus = .pending, isMe: Bool = false) -> UUID? {
        guard let db = peopleDB else { return nil }
        do {
            let person = try db.createPerson(displayName: name, status: status, isMe: isMe)
            people.append(person)
            if isMe { people = people.map { Person(id: $0.id, displayName: $0.displayName, strangerIndex: $0.strangerIndex, colorIndex: $0.colorIndex, status: $0.status, isMe: $0.id == person.id, note: $0.note, createdAt: $0.createdAt, lastMetAt: $0.lastMetAt) } }
            return person.id
        } catch {
            addLog("新建人物失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 改名（写库 + 更新内存 + 回写投影）。
    func renamePerson(id: UUID, to name: String) {
        guard let db = peopleDB else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try db.renamePerson(id: id, to: trimmed)
            if let k = people.firstIndex(where: { $0.id == id }) { people[k].displayName = trimmed }
            syncPeopleToLibrary()
        } catch {
            addLog("人物改名失败：\(error.localizedDescription)")
        }
    }

    /// 设为「我」（全局至多一人）。
    func setMe(personID: UUID?) {
        guard let db = peopleDB else { return }
        do {
            try db.setMe(id: personID)
            people = people.map { Person(id: $0.id, displayName: $0.displayName, strangerIndex: $0.strangerIndex, colorIndex: $0.colorIndex, status: $0.status, isMe: $0.id == personID, note: $0.note, createdAt: $0.createdAt, lastMetAt: $0.lastMetAt) }
        } catch {
            addLog("设置「我」失败：\(error.localizedDescription)")
        }
    }

    /// 从库里重新读人物（改名/合并/纠错后刷新内存）。
    func reloadPeople() {
        guard let db = peopleDB else { return }
        people = (try? db.listPersons()) ?? []
    }

    /// 已命名人物（按最近交流倒序），供首页主列表。
    var confirmedPeople: [Person] {
        people.filter { $0.status == .confirmed && !$0.isMe }.sorted { ($0.lastMetAt ?? .distantPast) > ($1.lastMetAt ?? .distantPast) }
    }

    /// 待认识声音（未命名、未忽略）。
    var pendingPeople: [Person] {
        people.filter { $0.status == .pending }.sorted { ($0.lastMetAt ?? .distantPast) > ($1.lastMetAt ?? .distantPast) }
    }

    /// 待认识声音的数量（首页折叠提示条用）。
    var pendingPeopleCount: Int { pendingPeople.count }

    /// 把待认识声音命名并升格为已确认人物。
    func namePendingPerson(id: UUID, name: String) {
        guard let db = peopleDB else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try db.renamePerson(id: id, to: trimmed)
            try db.setPersonStatus(id: id, .confirmed)
            reloadPeople()
            syncPeopleToLibrary()
        } catch { peopleError = error.localizedDescription }
    }

    /// 以后不提示（忽略）。
    func ignorePerson(id: UUID) {
        guard let db = peopleDB else { return }
        do { try db.setPersonStatus(id: id, .ignored); reloadPeople() }
        catch { peopleError = error.localizedDescription }
    }

    /// 删除一张人物卡（连同其样本、发言归属与资料）。
    func deletePerson(id: UUID) {
        guard let db = peopleDB else { return }
        do {
            try db.deletePersonCascade(id: id)
            reloadPeople()
            syncPeopleToLibrary()
        } catch { peopleError = error.localizedDescription }
    }

    /// 单句改归属：只改目标句对应区间，不串改同一 `localSpeaker` 的其它句子。
    /// 实现：为该句单独开一个本地说话人槽位并落一条 manual 归属，人工优先级高于重跑模型。
    func reassignSegment(recordingID: UInt32, start: TimeInterval, localSpeaker: Int?, to personID: UUID?) {
        guard let db = peopleDB,
              let i = recordings.firstIndex(where: { $0.id == recordingID }),
              let segIdx = recordings[i].segments.firstIndex(where: { abs($0.start - start) < 0.001 }) else { return }
        var seg = recordings[i].segments[segIdx]
        let startMs = Int(seg.start * 1000)
        let endMs = max(startMs + 1, Int((seg.end ?? (seg.start + 1)) * 1000))
        let newLocal = recordings[i].speakers.count
        recordings[i].speakers.append("")
        seg.speaker = newLocal
        recordings[i].segments[segIdx] = seg
        saveLibrary()

        let u = Utterance(id: UUID(), recordingID: recordingID, audioFingerprint: "manual-\(recordingID)",
                          startMs: startMs, endMs: endMs, localSpeaker: newLocal, overlap: false,
                          personID: personID, source: "manual", score: 1, modelVersion: "")
        do {
            try db.insertUtterance(u)
            // 记一条驳回对：原自动归属（如有）不再反复推荐
            if let oldLocal = localSpeaker {
                let old = (try? db.listUtterances(recordingID: recordingID)) ?? []
                if let oldAuto = old.first(where: { $0.localSpeaker == oldLocal && $0.source != "manual" && $0.personID != nil && startMs >= $0.startMs && startMs < $0.endMs }),
                   let oldPID = oldAuto.personID, oldPID != personID {
                    try? db.addRejectedPair("\(oldPID.uuidString)|\(recordingID)-\(oldLocal)")
                }
            }
            syncPeopleToLibrary([recordingID])
            reloadPeople()
        } catch { peopleError = error.localizedDescription }
    }

    /// 把两张卡合并成一张（次要并入主要），记录 merge_log 供撤销。
    func mergePeople(primary: UUID, secondary: UUID) {
        guard let db = peopleDB else { return }
        do {
            _ = try db.mergePersons(primary: primary, secondary: secondary)
            reloadPeople()
            syncPeopleToLibrary()
        } catch { peopleError = error.localizedDescription }
    }

    /// 撤销最近一次合并（不伤合并后新增/编辑的其它内容）。
    func undoLastMerge() {
        guard let db = peopleDB, let last = (try? db.pendingMergeLogs())?.first else { return }
        do {
            try db.undoMerge(logID: last.id)
            reloadPeople()
            syncPeopleToLibrary()
        } catch { peopleError = error.localizedDescription }
    }

    /// 某个人物的资料与往来事项（排除已移入回收站/已删除录音派生出的条目）。
    func insights(personID: UUID) -> [PersonInsight] {
        guard let db = peopleDB else { return [] }
        let all = (try? db.listInsights(personID: personID)) ?? []
        let live = Set(recordings.map(\.id))
        return all.filter { $0.recordingID == nil || live.contains($0.recordingID!) }
    }

    /// 某个人物的声音样本。
    func samples(personID: UUID) -> [VoiceSample] {
        guard let db = peopleDB else { return [] }
        return (try? db.listSamples(personID: personID)) ?? []
    }

    /// 某个人物的对话时间线（发言归属 + 录音标题/日期 + 原句）。
    func timeline(personID: UUID) -> [PersonTimelineRow] {
        guard let db = peopleDB else { return [] }
        let utts = (try? db.listUtterancesForPerson(personID: personID)) ?? []
        let recByID = Dictionary(uniqueKeysWithValues: recordings.map { ($0.id, $0) })
        return utts.compactMap { u in
            guard let rec = recByID[u.recordingID] else { return nil }
            let segs = rec.segments.filter { seg in
                let t = seg.start * 1000
                return t >= Double(u.startMs) - 50 && t < Double(u.endMs)
            }
            let snippet = segs.map { $0.clean ?? $0.text }.joined(separator: " ")
            return PersonTimelineRow(id: u.id, recordingID: u.recordingID, title: rec.displayTitle,
                                     date: rec.date, snippet: snippet, start: Double(u.startMs) / 1000,
                                     end: Double(u.endMs) / 1000)
        }
    }

    #if os(macOS)
    /// 导入一段外部音频作为某人的声音样本：系统原生解码 → 提取声纹 → 受管复制，不写 library.json。
    func importVoiceSample(personID: UUID, url: URL) async -> Bool {
        guard let db = peopleDB else { return false }
        do {
            let samples = try SpeakerEngine.loadMono16k(url)
            guard !samples.isEmpty else { return false }
            let samplesDir = dataRoot.appendingPathComponent("People/Samples", isDirectory: true)
            try FileManager.default.createDirectory(at: samplesDir, withIntermediateDirectories: true)
            let managed = samplesDir.appendingPathComponent("\(UUID().uuidString).wav")
            let wavData = QwenASR.wav(samples)
            try wavData.write(to: managed, options: .atomic)
            let embedding = await SpeakerEngine.shared.embedWhole(samples)
            let contentHash = SHA256.hash(data: wavData).map { String(format: "%02x", $0) }.joined()
            let sample = VoiceSample(id: UUID(), personID: personID, sourceKind: .importedFile, recordingID: nil,
                                     startMs: 0, endMs: samples.count * 1000 / 16000, managedFile: managed.lastPathComponent,
                                     channel: .nearField, confirmed: true, modelVersion: SpeakerEngine.embeddingCAMPPName,
                                     contentHash: contentHash)
            try db.addSample(sample, embedding: embedding)
            return true
        } catch {
            peopleError = error.localizedDescription
            return false
        }
    }
    #endif

    /// 删除某人的一段声音样本（被删样本不再参与匹配）。
    func deleteSample(personID: UUID, sampleID: UUID) {
        guard let db = peopleDB else { return }
        do { try db.deleteSample(id: sampleID) }
        catch { peopleError = error.localizedDescription }
    }
}

/// 人物时间线的一行：一次发言 + 所在录音 + 原句。
nonisolated struct PersonTimelineRow: Identifiable, Equatable {
    let id: UUID
    let recordingID: UInt32
    let title: String
    let date: Date?
    let snippet: String
    let start: TimeInterval
    let end: TimeInterval
}
