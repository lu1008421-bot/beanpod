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
    // 新建联系人
    @State private var addingPerson = false
    @State private var addName = ""
    // 样本管理抽屉
    @State private var managingSamples: Person?
    // 洞察条目编辑
    @State private var editingInsight: PersonInsight?
    @State private var insightText = ""

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
        .onAppear {
            if let p = nav.selectedPersonID ?? nav.returnPersonID,
               let person = store.people.first(where: { $0.id == p }), store.personVisible(p) {
                selected = p
                if person.status == .pending { showPending = true }
            } else if selected == nil, let first = (confirmed.first ?? pending.first) {
                selected = first.id
                if first.status == .pending { showPending = true }
            }
        }
        .onChange(of: selected) { _, v in nav.selectedPersonID = v }
        .sheet(item: $naming) { person in
            nameSheet(person)
        }
        .sheet(item: $linking) { person in
            linkSheet(person)
        }
        .sheet(isPresented: $addingPerson) { addPersonSheet }
        .sheet(item: $managingSamples) { person in sampleSheet(person) }
        .sheet(item: $mergingInto) { person in mergeSheet(person) }
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
                // 一个人都没有时「我的声音」也要在：只有「我」这张卡时列表同样会走到这里
                VStack(spacing: 0) {
                    emptyHint
                    Spacer(minLength: 0)
                    Divider().overlay(Theme.warm200.opacity(0.6))
                    meRow.padding(.horizontal, 12).padding(.vertical, 8)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if showPending {
                            ForEach(pending) { p in row(p) }
                            }
                            ForEach(confirmed) { p in row(p) }
                            meRow
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
                    if p.status == .pending, let c = store.firstContext(personID: p.id) {
                    Text("\(c.date?.formatted(.dateTime.month().day()) ?? "") · \(c.title)").font(.system(size: 11)).foregroundStyle(Theme.warm400).lineLimit(1)
                    } else if let last = p.lastMetAt { Text(last.formatted(.relative(presentation: .named))).font(.system(size: 11)).foregroundStyle(Theme.warm400) }
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

    /// 「我的声音」：单独一行，不混在联系人里。还没有这张卡时点一下就建。
    @ViewBuilder private var meRow: some View {
        if let me = store.mePerson {
            row(me)
        } else if store.peopleDB != nil {
            Button {
                if let id = store.createPerson(name: String(localized: "我"), status: .confirmed, isMe: true) { selected = id }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.dashed").font(.system(size: 15)).foregroundStyle(Theme.warm400).frame(width: 32, height: 32)
                    Text("我的声音").font(.system(size: 13)).foregroundStyle(Theme.warm500)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("管理「我」的声音样本。在文字稿里把某句标成「我」时会用到")
        }
    }
    
    private func avatar(_ p: Person, size: CGFloat) -> some View {
        let pending = p.status == .pending
        let color = pending ? Theme.warm500 : Theme.speakers[abs(p.colorIndex) % Theme.speakers.count]
        let fill = pending ? Theme.warm200.opacity(0.8) : color.opacity(0.14)
        let stroke = pending ? Theme.warm400.opacity(0.6) : color.opacity(0.35)
        let dash: [CGFloat] = pending ? [3, 2] : []
        let initial = p.isMe ? "我" : String((p.displayName.isEmpty ? "?" : p.displayName).prefix(1))
        return Text(initial)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(color.opacity(0.9))
            .frame(width: size, height: size)
            .background(fill, in: .circle)
            .overlay(Circle().strokeBorder(stroke, style: StrokeStyle(lineWidth: 1, dash: dash)))
    }

    // MARK: 右栏

    @ViewBuilder private var detailPane: some View {
        if let selected, store.personVisible(selected), let person = store.people.first(where: { $0.id == selected }) {
            personDetail(person)
        } else if let first = (confirmed.first ?? pending.first) {
            personDetail(first)
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
            // 样本、时间线、资料都是从人物库现读的：靠这个计数让增删改之后界面马上重画
            let _ = store.peopleRevision
            header(p)
            if p.status == .pending {
            pendingActions(p)
            } else {
            if !suggestions(for: p).isEmpty { suggestionCard(p) }
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
                    RenameField(initial: p.displayName, id: p.id) { name in store.renamePerson(id: p.id, to: name) }
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                } else {
                    Text(p.isMe ? "我" : (p.displayName.isEmpty ? String(localized: "未记名 \(p.strangerLabel)") : p.displayName))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                }
                HStack(spacing: 8) {
                    if p.status == .confirmed {
                        let n = store.samples(personID: p.id).count
                        Button { managingSamples = p } label: {
                            Text("\(n) 段声音样本").font(.caption.weight(.medium)).foregroundStyle(Theme.warm500)
                                .padding(.horizontal, 8).padding(.vertical, 3).background(Theme.warm200.opacity(0.6), in: .capsule)
                        }
                        .buttonStyle(.plain).help("管理声音样本")
                    }
                    if let last = p.lastMetAt { Text("最近 \(last.formatted(.dateTime.month().day()))").font(.caption).foregroundStyle(.tertiary) }
                }
            }
            Spacer()
            if p.status == .confirmed {
            Menu {
            Button { importingFor = p } label: { Label("导入声音样本", systemImage: "waveform.badge.plus") }
            if !p.isMe {
            Button { mergingInto = p } label: { Label("合并到这张卡…", systemImage: "arrow.triangle.merge") }
            Button { store.undoLastMerge() } label: { Label("撤销上次合并", systemImage: "arrow.uturn.backward") }
            Divider()
            Button(role: .destructive) { store.deletePerson(id: p.id) } label: { Label("删除人物", systemImage: "trash") }
            } else {
            Divider()
            Button(role: .destructive) { store.setMe(personID: nil); store.deletePerson(id: p.id) } label: { Label("删除「我的声音」", systemImage: "trash") }
            }
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
        // 代表原声：挑最长的一段，按时间排；每段最多听 8 秒
        let clips = Array(store.samples(personID: p.id)
            .filter { $0.sourceKind == .recordingSpan && $0.recordingID != nil }
            .sorted { ($0.endMs - $0.startMs) > ($1.endMs - $1.startMs) }
            .prefix(3)).sorted { $0.startMs < $1.startMs }
        let context = store.firstContext(personID: p.id)
        return VStack(alignment: .leading, spacing: 14) {
            Text("这个声音还没记名字。可以先听几段代表原声再决定。").font(.callout).foregroundStyle(.secondary)
            if !clips.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("代表原声").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.warm500)
                    ForEach(clips) { s in clipRow(s) }
                }
            }
            if let context {
                HStack(spacing: 8) {
                    Image(systemName: "mappin.and.ellipse").font(.caption).foregroundStyle(Theme.warm400)
                    Text("出现在 \(context.date?.formatted(.dateTime.month().day()) ?? "") · \(context.title)")
                        .font(.callout).foregroundStyle(Theme.warm700).lineLimit(1)
                    Button("去文字稿") { nav.openTranscript(recording: context.recordingID, start: context.start, fromPerson: p.id) }
                        .buttonStyle(.link).font(.callout)
                }
                .help(context.snippet)
            }
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

    /// 一段代表原声：点一下就地听 8 秒，再点停。
    private func clipRow(_ s: VoiceSample) -> some View {
        guard let rid = s.recordingID else { return AnyView(EmptyView()) }
        let start = Double(s.startMs) / 1000
        let end = min(Double(s.endMs) / 1000, start + 8)
        let on = store.isPlaying && store.playingID == rid && (store.activeSpan.map { abs($0.lowerBound - start) < 0.01 } ?? false)
        let title = store.recordings.first(where: { $0.id == rid })?.displayTitle ?? ""
        return AnyView(
            HStack(spacing: 10) {
                Button { if on { store.stop() } else { store.playSpan(rid, start...max(start + 0.3, end), loop: false) } } label: {
                    Label(on ? "停" : "听", systemImage: on ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Theme.accent.opacity(0.1), in: .capsule)
                }
                .buttonStyle(.plain)
                Text("\(title) · \(clock(start)) – \(clock(Double(s.endMs) / 1000)) · \(String(format: "%.0f", Double(s.endMs - s.startMs) / 1000)) 秒")
                    .font(.callout).foregroundStyle(Theme.warm700).lineLimit(1)
                Spacer(minLength: 0)
            }
        )
    }
    
    /// 「疑似 TA」：分人时像这个人、但分数不够自动署名的声音，由用户点「就是 TA / 不是」。
    private func suggestions(for p: Person) -> [SpeakerSuggestion] {
        store.suggestions().filter { $0.candidateID == p.id }
    }
    
    private func suggestionCard(_ p: Person) -> some View {
        section("请确认是不是 TA") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(suggestions(for: p)) { s in
                    let title = store.recordings.first(where: { $0.id == s.recordingID })?.displayTitle ?? ""
                    let start = Double(s.startMs) / 1000
                    let playingThis = store.isPlaying && store.playingID == s.recordingID && (store.activeSpan.map { abs($0.lowerBound - start) < 0.01 } ?? false)
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("有一段声音疑似 TA（相似度 \(Int((s.score * 100).rounded()))%）").font(.callout)
                            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Button { if playingThis { store.stop() } else { store.playSpan(s.recordingID, start...max(start + 0.3, min(Double(s.endMs) / 1000, start + 8)), loop: false) } } label: {
                            Image(systemName: playingThis ? "stop.circle.fill" : "play.circle").font(.system(size: 15))
                        }
                        .buttonStyle(.bordered).help(playingThis ? "停" : "听一听")
                        Button("就是 TA") { store.acceptSuggestion(s) }.buttonStyle(.glassProminent).tint(Theme.accent)
                        Button("不是") { store.rejectSuggestion(s) }.buttonStyle(.bordered)
                    }
                }
            }
        }
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
                            timelineRow(row, person: p)
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
    ForEach(items) { it in insightRow(it) }
    }
    }
    
    /// 一条人物资料：能就地试听、改写、移除（移除是软删）。
    private func insightRow(_ it: PersonInsight) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
    Image(systemName: "quote.opening").font(.caption).foregroundStyle(Theme.warm400)
    if editingInsight?.id == it.id {
    TextField("改成", text: $insightText, axis: .vertical).textFieldStyle(.roundedBorder).font(.callout)
    .onSubmit { commitInsightEdit(it) }
    Button("保存") { commitInsightEdit(it) }.buttonStyle(.glassProminent).tint(Theme.accent)
    .disabled(insightText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    Button("取消") { editingInsight = nil }.buttonStyle(.bordered)
    } else {
    Text(it.text).font(.callout)
    Spacer(minLength: 0)
    if let rid = it.recordingID, let s = it.startMs, let e = it.endMs {
    Button { store.playSpan(rid, Double(s) / 1000...Double(max(s, e)) / 1000, loop: false) } label: {
    Image(systemName: "play.circle.fill").font(.system(size: 15)).foregroundStyle(Theme.accent)
    }
    .buttonStyle(.plain).help("就地试听")
    }
    Button { insightText = it.text; editingInsight = it } label: {
    Image(systemName: "pencil").font(.system(size: 12)).foregroundStyle(.secondary)
    }
    .buttonStyle(.plain).help("修改这条")
    Button(role: .destructive) { store.hideInsight(it) } label: {
    Image(systemName: "xmark").font(.system(size: 11)).foregroundStyle(.secondary)
    }
    .buttonStyle(.plain).help("移除这条")
    }
    }
    }
    
    private func commitInsightEdit(_ it: PersonInsight) {
    store.editInsight(it, text: insightText)
    editingInsight = nil
    }

    private func timelineRow(_ row: PersonTimelineRow, person: Person) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button { store.playSpan(row.recordingID, row.start...max(row.start, row.end), loop: false) } label: {
                Image(systemName: "play.circle.fill").font(.system(size: 16)).foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain).help("从这里听")
            VStack(alignment: .leading, spacing: 2) {
                Button { nav.openTranscript(recording: row.recordingID, start: row.start, fromPerson: person.id) } label: {
                Text(row.title).font(.callout.weight(.medium)).foregroundStyle(Theme.warm900).lineLimit(1)
                }
                .buttonStyle(.plain).help("去文字稿看这句")
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
        addName = ""
        addingPerson = true
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

    private var addPersonSheet: some View {
        VStack(spacing: 12) {
            Text("添加联系人").font(.headline)
            TextField("姓名", text: $addName).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                .onSubmit(commitAdd)
            HStack {
                Button("取消") { addingPerson = false }.buttonStyle(.bordered)
                Button("添加") { commitAdd() }
                    .buttonStyle(.glassProminent).tint(Theme.accent)
                    .disabled(addName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(minWidth: 300)
    }

    private func commitAdd() {
        let name = addName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if let id = store.createPerson(name: name, status: .confirmed) {
            selected = id
        }
        addName = ""
        addingPerson = false
    }

    private func sampleSheet(_ p: Person) -> some View {
    // 增删样本后靠 peopleRevision 让这张表重画
    let _ = store.peopleRevision
    let samples = store.samples(personID: p.id)
    return VStack(alignment: .leading, spacing: 12) {
    Text("声音样本").font(.headline)
    if samples.isEmpty {
    Text("还没有样本。从录音里认出来的会自动留一段；也可以导入一段只含 TA 说话的音频。").font(.callout).foregroundStyle(.secondary)
    } else {
    ForEach(samples) { s in sampleSheetRow(s, person: p) }
    }
    HStack {
    Spacer()
    Button { managingSamples = nil; importingFor = p } label: { Label("导入声音样本", systemImage: "waveform.badge.plus") }
    .buttonStyle(.bordered)
    Button("完成") { managingSamples = nil }.buttonStyle(.glassProminent).tint(Theme.accent)
    }
    }
    .padding(20).frame(minWidth: 380)
    }
    
    /// 样本一行：导入的文件和从录音里截的代表段都能就地试听；正在播的只有这一行变成暂停。
    private func sampleSheetRow(_ s: VoiceSample, person p: Person) -> some View {
    let (on, play): (Bool, () -> Void) = {
    if let name = s.managedFile {
    return (store.isPlaying && store.playingSampleFile == name, { store.playSampleFile(name) })
    }
    guard let rid = s.recordingID else { return (false, {}) }
    let start = Double(s.startMs) / 1000
    let end = Double(max(s.startMs + 300, s.endMs)) / 1000
    let playing = store.isPlaying && store.playingID == rid && (store.activeSpan.map { abs($0.lowerBound - start) < 0.01 } ?? false)
    return (playing, { playing ? store.stop() : store.playSpan(rid, start...end, loop: false) })
    }()
    return HStack(spacing: 10) {
    Button(action: play) {
    Image(systemName: on ? "pause.circle.fill" : "play.circle.fill")
    .font(.system(size: 16)).foregroundStyle(Theme.accent)
    }
    .buttonStyle(.plain).help(on ? "停" : "试听这段")
    VStack(alignment: .leading, spacing: 2) {
    Text("\(s.channel == .speakerLoopback ? "外放" : "近场") · \(msLabel(s))\(s.confirmed ? "" : " · 未确认")").font(.callout)
    if s.sourceKind == .importedFile {
    Text("导入").font(.caption).foregroundStyle(.secondary)
    } else if let rid = s.recordingID {
    let title = store.recordings.first(where: { $0.id == rid })?.displayTitle ?? ""
    Text("来自录音「\(title)」\(clock(Double(s.startMs) / 1000))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }
    }
    Spacer()
    Button(role: .destructive) { store.deleteSample(personID: p.id, sampleID: s.id) } label: {
    Image(systemName: "trash").font(.system(size: 13)).foregroundStyle(.secondary)
    }
    .buttonStyle(.plain).help("删除样本")
    }
    }

    private func msLabel(_ s: VoiceSample) -> String {
        String(format: "%.1f 秒", Double(max(0, s.endMs - s.startMs)) / 1000)
    }

    private func mergeSheet(_ p: Person) -> some View {
        VStack(spacing: 12) {
            Text("合并到「\(p.displayName)」").font(.headline)
            Text("把另一张卡并进来：样本、发言与资料都归到这张卡，原卡删除，可撤销。").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.confirmedPeople.filter { $0.id != p.id }) { c in
                        Button { store.mergePeople(primary: p.id, secondary: c.id); mergingInto = nil } label: {
                            HStack { Text(c.displayName); Spacer() }
                                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if store.confirmedPeople.filter({ $0.id != p.id }).isEmpty {
                        Text("没有其它可合并的联系人。").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minHeight: 120)
            HStack { Spacer(); Button("取消") { mergingInto = nil }.buttonStyle(.bordered) }
        }
        .padding(20).frame(minWidth: 320)
    }
}

/// 只在回车或失焦时提交的姓名输入，避免每敲一个字就写一次库。
private struct RenameField: View {
    let initial: String
    let id: UUID
    let onCommit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("姓名", text: $text)
            .textFieldStyle(.plain)
            .focused($focused)
            .onSubmit { onCommit(text) }
            .onChange(of: focused) { _, f in if !f { onCommit(text) } }
            .onChange(of: initial) { _, v in if !focused { text = v } }
            .onAppear { text = initial }
    }
}

/// 人物时间线按日期分组的显示用结构。
private struct PersonTimelineGroup: Identifiable {
    let date: String
    var rows: [PersonTimelineRow]
    var id: String { date }
}
