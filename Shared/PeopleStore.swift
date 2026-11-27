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
}
