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
    /// `Recording.people` 是两份名单合并的结果：纪要整理时模型提到的人物保留，声纹认出的人名排在最前；
    /// 上次由声纹写入、这次已不成立的名字才会被拿掉。
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
        var changed = false
        for i in targets {
            let rec = recordings[i]
            // 被用户排除出「人物」的录音：只清掉以前声纹写入的名字，不写入新的
            let utterances = rec.peopleExcluded ? [] : ((try? db.listUtterances(recordingID: rec.id)) ?? [])
            guard !utterances.isEmpty else {
                if !rec.voicePeople.isEmpty {
                    recordings[i].people = PeopleProjection.removingVoice(rec.people, voicePeople: rec.voicePeople)
                    recordings[i].voicePeople = []
                    changed = true
                }
                continue
            }

            // localSpeaker → personID；人工指定优先于自动
            var speakerPerson: [Int: UUID] = [:]
            var firstAppear: [Int: Int] = [:]
            for u in utterances {
                guard let pid = u.personID else { continue }
                if speakerPerson[u.localSpeaker] == nil || u.source == "manual" { speakerPerson[u.localSpeaker] = pid }
                firstAppear[u.localSpeaker] = min(firstAppear[u.localSpeaker] ?? Int.max, u.startMs)
            }

            // 声纹认出的已确认人物名：去重，按第一次开口的先后
            var seen = Set<String>()
            var names: [String] = []
            for idx in speakerPerson.keys.sorted(by: { (firstAppear[$0] ?? 0) < (firstAppear[$1] ?? 0) }) {
                guard let pid = speakerPerson[idx], let p = personsByID[pid],
                      p.status == .confirmed, !p.displayName.isEmpty else { continue }
                if seen.insert(p.displayName).inserted { names.append(p.displayName) }
            }
            let projection = PeopleProjection.merge(llmPeople: rec.people, oldVoicePeople: rec.voicePeople, newVoicePeople: names)
            if projection.people != rec.people || projection.voicePeople != rec.voicePeople {
                recordings[i].people = projection.people
                recordings[i].voicePeople = projection.voicePeople
                changed = true
            }

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
            if speakers != rec.speakers { recordings[i].speakers = speakers; changed = true }
        }
        if changed || ids == nil { saveLibrary() }
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
            peopleRevision += 1
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
            syncPeopleToLibrary()
            peopleRevision += 1
        } catch {
            addLog("设置「我」失败：\(error.localizedDescription)")
        }
    }

    /// 从库里重新读人物（改名/合并/纠错后刷新内存）。
    func reloadPeople() {
        guard let db = peopleDB else { return }
        people = (try? db.listPersons()) ?? []
    }

    /// 「我」这张卡（全局至多一张）。
    var mePerson: Person? { people.first(where: { $0.isMe && $0.status != .ignored }) }

    /// 人物显示名：已确认用名字，待认识用内部编号，其它用录音里原来的说话人标签。
    func personName(_ pid: UUID?, fallback: String?) -> String? {
        guard let pid, let p = people.first(where: { $0.id == pid }) else { return fallback }
        if p.status == .confirmed, !p.displayName.isEmpty { return p.displayName }
        if p.status == .pending { return String(localized: "未记名 \(p.strangerLabel)") }
        return fallback
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
            // 确认了这张卡，卡上已经核实过的声音样本一起算作已确认
            try db.confirmSamples(personID: id)
            reloadPeople()
            syncPeopleToLibrary()
            peopleRevision += 1
        } catch { peopleError = error.localizedDescription }
    }

    /// 以后不提示（忽略）。
    func ignorePerson(id: UUID) {
        guard let db = peopleDB else { return }
        do { try db.setPersonStatus(id: id, .ignored); reloadPeople(); syncPeopleToLibrary(); peopleRevision += 1 }
        catch { peopleError = error.localizedDescription }
    }

    /// 删除一张人物卡（连同其样本、发言归属与资料）。
    func deletePerson(id: UUID) {
        guard let db = peopleDB else { return }
        do {
            try db.deletePersonCascade(id: id)
            reloadPeople()
            syncPeopleToLibrary()
            peopleRevision += 1
        } catch { peopleError = error.localizedDescription }
    }

    /// 这条录音参不参与「人物」。排除后不再分人、不进任何人的时间线与资料；重新处理也不会把它算进去。
    func setPeopleExcluded(recordingID: UInt32, _ excluded: Bool) {
        guard let i = recordings.firstIndex(where: { $0.id == recordingID }) else { return }
        recordings[i].peopleExcluded = excluded
        if excluded {
            recordings[i].people = PeopleProjection.removingVoice(recordings[i].people, voicePeople: recordings[i].voicePeople)
            recordings[i].voicePeople = []
        }
        saveLibrary()
        peopleRevision += 1
    }

    /// 某条录音的声学说话人时间线（按说话人切出来的区间，不含身份）：逐句没有时间戳时用它回听是谁在说。
    func acousticTimeline(recordingID: UInt32) -> [(start: TimeInterval, end: TimeInterval, speaker: Int)] {
        guard let db = peopleDB, let i = recordings.firstIndex(where: { $0.id == recordingID }),
              !recordings[i].peopleExcluded else { return [] }
        let utts = ((try? db.listUtterances(recordingID: recordingID)) ?? [])
            .sorted { $0.startMs < $1.startMs }
        return utts.filter { $0.endMs > $0.startMs }.map { (Double($0.startMs) / 1000, Double($0.endMs) / 1000, $0.localSpeaker) }
    }

    /// 某人在哪条录音里第一次出现（日期 + 标题），待认识卡用来说明「这个声音是在哪听到的」。
    func firstContext(personID: UUID) -> PersonTimelineRow? {
        timeline(personID: personID).min(by: { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) })
    }

    /// 「疑似某人」的匹配建议：分人时像某位已有人物、但分数不够自动署名，留给用户定。
    func suggestions() -> [SpeakerSuggestion] {
        guard let db = peopleDB else { return [] }
        return (try? db.listSuggestions()) ?? []
    }

    /// 采纳「疑似某人」：这个人在这条录音里的发言全部归到 TA，并记下样本供以后自动认出。
    func acceptSuggestion(_ s: SpeakerSuggestion) {
        guard let db = peopleDB, let i = recordings.firstIndex(where: { $0.id == s.recordingID }) else { return }
        do {
            // 发言全部归到 TA；这个声音自己的待认识卡并掉（只删这一张，别人的不动）
            try db.acceptSuggestion(recordingID: s.recordingID, localSpeaker: s.localSpeaker, candidateID: s.candidateID)
            // 用户认下了这段声音：它的中心声纹存成这个人的已确认样本
            if !s.vector.isEmpty {
                let sample = VoiceSample(id: UUID(), personID: s.candidateID, sourceKind: .recordingSpan, recordingID: s.recordingID,
                                         startMs: s.startMs, endMs: s.endMs, managedFile: nil, channel: recordings[i].speakerChannel,
                                         confirmed: true, modelVersion: Self.embeddingModelName,
                                         contentHash: "recording-\(s.recordingID)-\(s.localSpeaker)-\(s.startMs)")
                try db.addSample(sample, embedding: s.vector)
            }
            try db.setLastMet(id: s.candidateID, recordings[i].date)
            try db.deleteJob(id: s.id)
            reloadPeople()
            syncPeopleToLibrary([s.recordingID])
            peopleRevision += 1
        } catch { peopleError = error.localizedDescription }
    }

    /// 驳回「疑似某人」：这个人 × 这条录音里的这个声音不再推荐。
    func rejectSuggestion(_ s: SpeakerSuggestion) {
        guard let db = peopleDB else { return }
        do {
            try db.addRejectedPair("\(s.candidateID.uuidString)|\(s.recordingID)-\(s.localSpeaker)")
            try db.deleteJob(id: s.id)
            peopleRevision += 1
        } catch { peopleError = error.localizedDescription }
    }

    /// 声纹向量模型的标识（人物库在 iOS 上也能读，但那边没有声纹引擎）。
    nonisolated static var embeddingModelName: String {
        #if os(macOS)
        SpeakerEngine.embeddingCAMPPName
        #else
        "3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx"
        #endif
    }

    /// 编辑 / 移除一条人物资料（移除是软删，数据库里还留着）。
    func editInsight(_ insight: PersonInsight, text: String) {
        guard let db = peopleDB, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do { try db.editInsight(id: insight.id, text: text); peopleRevision += 1 }
        catch { peopleError = error.localizedDescription }
    }

    func hideInsight(_ insight: PersonInsight) {
        guard let db = peopleDB else { return }
        do { try db.hideInsight(id: insight.id); peopleRevision += 1 }
        catch { peopleError = error.localizedDescription }
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
        recordings[i].speakers.append(String(localized: "说话人 \(newLocal + 1)"))
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
            peopleRevision += 1
        } catch { peopleError = error.localizedDescription }
    }

    /// 把两张卡合并成一张（次要并入主要），记录 merge_log 供撤销。
    func mergePeople(primary: UUID, secondary: UUID) {
        guard let db = peopleDB else { return }
        do {
            _ = try db.mergePersons(primary: primary, secondary: secondary)
            reloadPeople()
            syncPeopleToLibrary()
            peopleRevision += 1
        } catch { peopleError = error.localizedDescription }
    }

    /// 撤销最近一次合并（不伤合并后新增/编辑的其它内容）。
    func undoLastMerge() {
        guard let db = peopleDB, let last = (try? db.pendingMergeLogs())?.first else { return }
        do {
            try db.undoMerge(logID: last.id)
            reloadPeople()
            syncPeopleToLibrary()
            peopleRevision += 1
        } catch { peopleError = error.localizedDescription }
    }

    /// 某个人物的资料与往来事项（排除已移入回收站/已删除录音派生出的条目）。
    func insights(personID: UUID) -> [PersonInsight] {
        guard let db = peopleDB else { return [] }
        let all = (try? db.listInsights(personID: personID)) ?? []
        let live = Set(recordings.filter { !$0.peopleExcluded }.map(\.id))
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
        let recByID = Dictionary(uniqueKeysWithValues: recordings.filter { !$0.peopleExcluded }.map { ($0.id, $0) })
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
            let wavData = QwenASR.wav(samples)
            let contentHash = SHA256.hash(data: wavData).map { String(format: "%02x", $0) }.joined()
            // 同一段音频不重复入库
            if try db.sampleExists(personID: personID, contentHash: contentHash) { return true }
            let samplesDir = dataRoot.appendingPathComponent("People/Samples", isDirectory: true)
            try FileManager.default.createDirectory(at: samplesDir, withIntermediateDirectories: true)
            let managed = samplesDir.appendingPathComponent("\(UUID().uuidString).wav")
            try wavData.write(to: managed, options: .atomic)
            let embedding = await SpeakerEngine.shared.embedWhole(samples)
            let sample = VoiceSample(id: UUID(), personID: personID, sourceKind: .importedFile, recordingID: nil,
                                     startMs: 0, endMs: samples.count * 1000 / 16000, managedFile: managed.lastPathComponent,
                                     channel: .nearField, confirmed: true, modelVersion: SpeakerEngine.embeddingCAMPPName,
                                     contentHash: contentHash)
            if try db.addSample(sample, embedding: embedding) {
                peopleRevision += 1
                reloadPeople()
            } else {
                try? FileManager.default.removeItem(at: managed)
            }
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
        do {
            // 受管复制到 People/Samples 的那份一起删掉，不留孤儿文件
            if let file = try db.sampleFile(id: sampleID) {
                try? FileManager.default.removeItem(at: dataRoot.appendingPathComponent("People/Samples").appendingPathComponent(file))
            }
            try db.deleteSample(id: sampleID)
            peopleRevision += 1
            reloadPeople()
        } catch { peopleError = error.localizedDescription }
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
