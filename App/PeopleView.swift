import SwiftUI

/// 「人物」：从录音里分出的人建成的通讯录。左边是人物列表，右边是选中人物的详情。
struct PeopleView: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav
    @State private var query = ""
    @State private var selected: UUID?
    @State private var showPending = false
    @State private var listWidth: CGFloat = 330

    // 命名 / 关联 / 忽略
    @State private var naming: Person?
    @State private var namingText = ""
    @State private var linking: Person?
    // 样本导入
    @State private var importingFor: Person?
    // 合并
    @State private var mergingInto: Person?

    private var confirmed: [Person] {
        let base = store.confirmedPeople
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter { $0.displayName.lowercased().contains(q) || $0.note.lowercased().contains(q) }
    }

    private var pending: [Person] { store.pendingPeople }

    var body: some View {
        HStack(spacing: 0) {
            listPane
            Divider().overlay(Theme.warm200.opacity(0.6))
            detailPane
        }
        .navigationTitle("人物")
        .navigationSubtitle(store.confirmedPeople.isEmpty ? "" : "\(store.confirmedPeople.count) 位联系人")
        .sheet(item: $naming) { person in
            nameSheet(person)
        }
        .sheet(item: $linking) { person in
            linkSheet(person)
        }
        #if os(macOS)
        .fileImporter(isPresented: Binding(get: { importingFor != nil }, set: { if !$0 { importingFor = nil } }),
                      allowedContentTypes: [.audio, .movie], allowsMultipleSelection: true) { result in
            if let person = importingFor {
                switch result {
                case .success(let urls):
                    Task {
                        var ok = 0
                        for url in urls where await store.importVoiceSample(personID: person.id, url: url) { ok += 1 }
                        if ok > 0 { store.toast("waveform.badge.plus", String(localized: "已导入 \(ok) 段样本")) }
                    }
                case .failure(let error):
                    store.notice = error.localizedDescription
                }
            }
            importingFor = nil
        }
        #endif
    }

    // MARK: 左栏

    private var listPane: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("人物").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.warm900)
                    Spacer()
                    Button { addPerson() } label: { Image(systemName: "person.badge.plus") }
                        .buttonStyle(.plain).foregroundStyle(Theme.accent).font(.system(size: 14, weight: .semibold))
                        .help("添加联系人").accessibilityLabel("添加联系人")
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Theme.warm400)
                    TextField("搜姓名或备注", text: $query).textFieldStyle(.plain).font(.system(size: 13))
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.warm400) }
                            .buttonStyle(.plain).help("清空")
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Theme.warm100.opacity(0.7), in: .rect(cornerRadius: Theme.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.warm200.opacity(0.8), lineWidth: 1))

                if !pending.isEmpty {
                    pendingStrip
                }
            }
            .padding(16)
            Divider().overlay(Theme.warm200.opacity(0.6))

            if confirmed.isEmpty, pending.isEmpty {
                emptyHint
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if showPending {
                            ForEach(pending) { p in row(p) }
                        }
                        ForEach(confirmed) { p in row(p) }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(width: listWidth)
    }

    private var emptyHint: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.2").font(.system(size: 34)).foregroundStyle(Theme.warm300)
            Text("还没有联系人").font(.headline)
            Text("从录音里认出的人会出现在这里，也可以先手动添加。").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("添加联系人") { addPerson() }.buttonStyle(.glassProminent).tint(Theme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private var pendingStrip: some View {
        Button { showPending.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: "waveform").font(.system(size: 12)).foregroundStyle(Theme.warm500)
                Text("待认识的声音（\(pending.count)）").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.warm700)
                Spacer()
                Image(systemName: showPending ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.warm400)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.warm200.opacity(0.6), in: .rect(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.warm300.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("点开核对还没记名字的声音")
    }

    private func row(_ p: Person) -> some View {
        let on = selected == p.id
        return Button { selected = p.id } label: {
            HStack(spacing: 10) {
                avatar(p, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(p.isMe ? "我" : (p.displayName.isEmpty ? String(localized: "未记名 \(p.strangerLabel)") : p.displayName))
                            .font(.system(size: 14, weight: on ? .semibold : .regular)).foregroundStyle(on ? Theme.warm900 : Theme.warm700).lineLimit(1)
                        if p.isMe { Text("我").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent).padding(.horizontal, 5).padding(.vertical, 1).background(Theme.accent.opacity(0.12), in: .capsule) }
                    }
                    if let last = p.lastMetAt { Text(last.formatted(.relative(presentation: .named))).font(.system(size: 11)).foregroundStyle(Theme.warm400) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(on ? Theme.warm300.opacity(0.4) : .clear, in: .rect(cornerRadius: Theme.Radius.card))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func avatar(_ p: Person, size: CGFloat) -> some View {
        let color = Theme.speakers[abs(p.colorIndex) % Theme.speakers.count]
        let initial = p.isMe ? "我" : String((p.displayName.isEmpty ? "?" : p.displayName).prefix(1))
        return Text(initial)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(color.opacity(0.9))
            .frame(width: size, height: size)
            .background(color.opacity(0.14), in: .circle)
            .overlay(Circle().strokeBorder(color.opacity(0.35), lineWidth: 1))
    }

    // MARK: 右栏

    @ViewBuilder private var detailPane: some View {
        if let selected, let person = store.people.first(where: { $0.id == selected }) {
            personDetail(person)
        } else if let first = (confirmed.first ?? pending.first) {
            personDetail(first).onAppear { selected = first.id }
        } else {
            VStack(spacing: 14) {
                Image(systemName: "person.crop.circle.badge.questionmark").font(.system(size: 40)).foregroundStyle(Theme.warm300)
                Text("从左边选一位，或去录音里认人").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func personDetail(_ p: Person) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(p)
                if p.status == .pending {
                    pendingActions(p)
                } else {
                    content(p)
                }
            }
            .padding(20)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func header(_ p: Person) -> some View {
        HStack(alignment: .center, spacing: 14) {
            avatar(p, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                if p.status == .confirmed, !p.isMe {
                    TextField("姓名", text: Binding(
                        get: { p.displayName },
                        set: { store.renamePerson(id: p.id, to: $0) }))
                        .textFieldStyle(.plain).font(.system(size: 22, weight: .bold, design: .rounded))
                } else {
                    Text(p.isMe ? "我" : (p.displayName.isEmpty ? String(localized: "未记名 \(p.strangerLabel)") : p.displayName))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                }
                HStack(spacing: 8) {
                    if p.status == .confirmed {
                        let n = store.samples(personID: p.id).count
                        Text("\(n) 段声音样本").font(.caption.weight(.medium)).foregroundStyle(Theme.warm500)
                            .padding(.horizontal, 8).padding(.vertical, 3).background(Theme.warm200.opacity(0.6), in: .capsule)
                    }
                    if let last = p.lastMetAt { Text("最近 \(last.formatted(.dateTime.month().day()))").font(.caption).foregroundStyle(.tertiary) }
                }
            }
            Spacer()
            if p.status == .confirmed, !p.isMe {
                Menu {
                    Button { importingFor = p } label: { Label("导入声音样本", systemImage: "waveform.badge.plus") }
                    Button { mergingInto = p } label: { Label("合并到这张卡…", systemImage: "arrow.triangle.merge") }
                    Button { store.undoLastMerge() } label: { Label("撤销上次合并", systemImage: "arrow.uturn.backward") }
                    Divider()
                    Button(role: .destructive) { store.deletePerson(id: p.id) } label: { Label("删除人物", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.warm500)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain)
            }
        }
        .padding(16)
        .panel(radius: Theme.Radius.panel)
    }

    private func pendingActions(_ p: Person) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("这个声音还没记名字。可以先听几段代表原声再决定。").font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                TextField("记下名字", text: $namingText).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                    .onSubmit { store.namePendingPerson(id: p.id, name: namingText); namingText = "" }
                Button("记下名字") { store.namePendingPerson(id: p.id, name: namingText); namingText = "" }
                    .buttonStyle(.glassProminent).tint(Theme.accent).disabled(namingText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack(spacing: 10) {
                Button { linking = p } label: { Label("关联已有联系人", systemImage: "person.crop.circle.badge.checkmark") }
                    .buttonStyle(.bordered)
                Button { store.ignorePerson(id: p.id) } label: { Label("以后不提示", systemImage: "eye.slash") }
                    .buttonStyle(.bordered)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).panel(radius: Theme.Radius.panel)
    }

    @ViewBuilder private func content(_ p: Person) -> some View {
        if !p.note.isEmpty {
            section("备注") { Text(p.note).font(.callout).foregroundStyle(.secondary) }
        }

        let items = store.insights(personID: p.id)
        let bios = items.filter { $0.kind == .bio && !$0.stale }
        let topics = items.filter { $0.kind == .topic && !$0.stale }
        let commitments = items.filter { $0.kind == .commitment && !$0.stale }
        if !bios.isEmpty { section("简要背景") { insightList(bios) } }
        if !commitments.isEmpty { section("说定的事") { insightList(commitments) } }
        if !topics.isEmpty { section("提到的事") { insightList(topics) } }

        let rows = store.timeline(personID: p.id)
        if !rows.isEmpty {
            section("对话时间线") {
                VStack(spacing: 8) {
                    ForEach(groupTimeline(rows)) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.date).font(.caption.weight(.semibold)).foregroundStyle(Theme.warm500)
                            ForEach(group.rows) { row in
                                timelineRow(row)
                            }
                        }
                    }
                }
            }
        } else {
            Text("还没有归属于 TA 的对话。去录音的文字稿里，把某句标给 TA。").font(.callout).foregroundStyle(.tertiary)
                .padding(.top, 6)
        }
    }

    private func insightList(_ items: [PersonInsight]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { it in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "quote.opening").font(.caption).foregroundStyle(Theme.warm400)
                    Text(it.text).font(.callout)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func timelineRow(_ row: PersonTimelineRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button { store.play(row.recordingID, at: row.start) } label: {
                Image(systemName: "play.circle.fill").font(.system(size: 16)).foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain).help("从这里听")
            VStack(alignment: .leading, spacing: 2) {
                Button { nav.open(row.recordingID) } label: {
                    Text(row.title).font(.callout.weight(.medium)).foregroundStyle(Theme.warm900).lineLimit(1)
                }
                .buttonStyle(.plain).help("去文字稿查看")
                if !row.snippet.isEmpty { Text(row.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private func section(_ title: String, @ViewBuilder body: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.warm900)
            body()
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).panel(radius: Theme.Radius.panel)
    }

    private func groupTimeline(_ rows: [PersonTimelineRow]) -> [PersonTimelineGroup] {
        let cal = Calendar.current
        var out: [PersonTimelineGroup] = []
        for r in rows {
            let label: String
            if let d = r.date {
                if cal.isDateInToday(d) { label = String(localized: "今天") }
                else if cal.isDateInYesterday(d) { label = String(localized: "昨天") }
                else { label = d.formatted(.dateTime.month().day().weekday(.abbreviated)) }
            } else { label = String(localized: "没有日期") }
            if out.last?.date == label { out[out.count - 1].rows.append(r) } else { out.append(PersonTimelineGroup(date: label, rows: [r])) }
        }
        return out
    }

    // MARK: 弹层

    private func addPerson() {
        store.createPerson(name: "", status: .confirmed)
    }

    private func nameSheet(_ p: Person) -> some View {
        VStack(spacing: 12) {
            Text("记下名字").font(.headline)
            TextField("姓名", text: $namingText).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
            HStack {
                Button("取消") { naming = nil }.buttonStyle(.bordered)
                Button("保存") { store.namePendingPerson(id: p.id, name: namingText); namingText = ""; naming = nil }
                    .buttonStyle(.glassProminent).tint(Theme.accent)
                    .disabled(namingText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(minWidth: 300)
    }

    private func linkSheet(_ p: Person) -> some View {
        VStack(spacing: 12) {
            Text("关联已有联系人").font(.headline)
            Picker("联系人", selection: Binding(get: { UUID?.none }, set: { target in
                if let target { store.mergePeople(primary: target, secondary: p.id) }
                linking = nil
            })) {
                Text("选择一位").tag(UUID?.none)
                ForEach(store.confirmedPeople) { c in Text(c.displayName).tag(UUID?.some(c.id)) }
            }
            Button("取消") { linking = nil }.buttonStyle(.bordered)
        }
        .padding(20).frame(minWidth: 300)
    }
}

/// 人物时间线按日期分组的显示用结构。
private struct PersonTimelineGroup: Identifiable {
    let date: String
    var rows: [PersonTimelineRow]
    var id: String { date }
}
