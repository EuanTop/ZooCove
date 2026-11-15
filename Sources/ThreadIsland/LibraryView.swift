import SwiftUI
import ThreadIslandCore

private let text = Color(white: 0.94)
private let muted = Color(white: 0.69)
private let doneGreen = Color(red: 0.29, green: 0.84, blue: 0.45)

struct LibraryView: View {
    @Bindable var model: LibraryModel
    var close: () -> Void
    var height: CGFloat
    var fusedToNotch = false
    @FocusState private var searchFocused: Bool
    @State private var editingAvatar = false
    @State private var showingShortcuts = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.06))
            if model.settings {
                settings
            } else if let session = model.detail {
                detail(session)
            } else {
                library
            }
            if !model.settings || model.notice != nil {
                Divider().overlay(Color.white.opacity(0.06))
                footer
            }
        }
        .frame(width: ExpandedIslandLayout.bodyWidth, height: height)
        .background(.black)
        .clipShape(.rect(cornerRadius: fusedToNotch ? 0 : 20))
        .overlay {
            if !fusedToNotch {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .preferredColorScheme(.dark)
        .tint(.white)
        .onAppear { focusSearch() }
        .onChange(of: model.settings) { _, isOpen in
            if !isOpen {
                showingShortcuts = false
                focusSearch()
            }
        }
        .onChange(of: model.detail?.id) { _, detail in
            editingAvatar = false
            if detail == nil { focusSearch() }
        }
        .onExitCommand {
            if model.settings { model.settings = false }
            else if model.detail != nil { model.back() }
            else { close() }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(model.settings ? "设置" : "ZooCove")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(text)
                .accessibilityAddTraits(.isHeader)
            if !model.settings && model.detail == nil {
                search
                Divider().frame(height: 16)
                sources
            } else {
                Spacer()
            }
            Button {
                model.settings.toggle()
                model.notice = nil
            } label: {
                Image(systemName: model.settings ? "chevron.left" : "gearshape")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(muted)
            .help(model.settings ? "返回" : "设置")
            .accessibilityLabel(model.settings ? "返回" : "设置")
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(muted)
            .help("收起")
            .accessibilityLabel("收起")
        }
        .padding(.horizontal, 17)
        .frame(height: 46)
    }

    private var search: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(muted)
            ZStack(alignment: .leading) {
                if model.query.isEmpty {
                    Text("搜索会话、项目或 ID")
                        .foregroundStyle(muted)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                TextField("搜索会话、项目或 ID", text: $model.query, prompt: Text(""))
                    .textFieldStyle(.plain)
                    .foregroundStyle(text)
                    .accessibilityLabel("搜索会话、项目或 ID")
                    .focused($searchFocused)
                    .onSubmit(openSelection)
                    .onKeyPress(.downArrow) { model.moveSelection(by: 1); return .handled }
                    .onKeyPress(.upArrow) { model.moveSelection(by: -1); return .handled }
            }
            .font(.system(size: 13))
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(.white.opacity(0.075), in: .rect(cornerRadius: 6))
    }

    private var library: some View {
        VStack(spacing: 0) {
            if model.loading && model.displayedSessions.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.displayedSessions.isEmpty {
                Text(model.query.isEmpty ? "没有可显示的会话" : "没有匹配的会话")
                    .font(.system(size: 13))
                    .foregroundStyle(muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                sessionList
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var sources: some View {
        Menu {
            Button {
                model.selectSource(nil)
            } label: {
                if model.source == nil { Label("全部实例", systemImage: "checkmark") }
                else { Text("全部实例") }
            }
            ForEach(model.activeInstances) { instance in
                Button {
                    model.selectSource(instance.id)
                } label: {
                    if model.source == instance.id { Label(instance.name, systemImage: "checkmark") }
                    else { Text(instance.name) }
                }
            }
        } label: {
            Text(model.activeInstances.first(where: { $0.id == model.source })?.name ?? "全部实例")
                .lineLimit(1)
                .frame(maxWidth: 125)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.system(size: 12))
        .foregroundStyle(muted)
        .accessibilityLabel("筛选实例")
        .accessibilityValue(model.activeInstances.first(where: { $0.id == model.source })?.name ?? "全部实例")
    }

    private var sessionList: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.displayedSessions) { session in
                        Button { model.show(session) } label: { row(session) }
                            .buttonStyle(.plain)
                            .id(session.id)
                        Divider().opacity(0.35).padding(.leading, 45)
                    }
                    if model.canLoadMore {
                        Button("显示更多") { model.loadMore() }
                            .buttonStyle(.plain)
                            .foregroundStyle(text)
                            .padding(10)
                    }
                }
                .padding(.horizontal, 11)
                .padding(.bottom, 9)
            }
            .onChange(of: model.selected) { _, id in
                if let id { reader.scrollTo(id) }
            }
        }
    }

    private func row(_ session: Session) -> some View {
        let selected = model.selected == session.id
        let status = model.islandSessions.first { $0.id == session.id }
        return HStack(spacing: 10) {
            CompanionArt(avatar: model.avatar(for: session))
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                    .font(.system(size: 13, weight: status?.ready == true ? .semibold : .medium))
                    .lineLimit(1).foregroundStyle(text)
                HStack(spacing: 6) {
                    Text(session.instance.name).lineLimit(1)
                    if let directory = session.directory {
                        Text("·").accessibilityHidden(true)
                        Text((directory as NSString).lastPathComponent).lineLimit(1)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if status?.ready == true {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark").foregroundStyle(doneGreen).accessibilityHidden(true)
                    Text("待查看").foregroundStyle(text)
                }
                .font(.system(size: 11, weight: .medium))
            } else if status?.running == true {
                Text("运行中").font(.system(size: 11)).foregroundStyle(muted)
            } else if session.updated != .distantPast {
                Text(session.updated, format: .dateTime.month().day().hour().minute())
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(muted)
            }
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                .foregroundStyle(muted).accessibilityHidden(true)
        }
        .padding(.horizontal, 7)
        .frame(height: 48)
        .background(.white.opacity(selected ? 0.11 : 0), in: .rect(cornerRadius: 7))
        .contentShape(.rect)
    }

    private func detail(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button { model.back() } label: { Label("会话列表", systemImage: "chevron.left") }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(text)
                    Spacer()
                    sessionCompanionPicker(session)
                }
                Text(session.title).font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(text).lineLimit(2).accessibilityAddTraits(.isHeader)
                Text(session.instance.name).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(muted)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 17)
            Divider()
            if model.loadingDetail {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let transcript = model.transcript, !transcript.messages.isEmpty {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if transcript.truncated {
                                Text("显示最近的消息").foregroundStyle(muted).font(.caption)
                            }
                            ForEach(transcript.messages) { message in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(message.role == .user ? "你" : session.instance.agent.name)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(message.role == .user ? text : muted)
                                    Text(message.text)
                                        .font(.system(size: 13)).foregroundStyle(text)
                                        .textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(11)
                                .background(.white.opacity(0.045), in: .rect(cornerRadius: 9))
                                .id(message.id)
                            }
                        }
                        .padding(15)
                    }
                    .onAppear {
                        if let last = transcript.messages.last { reader.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            } else {
                ContentUnavailableView("暂无可预览的消息", systemImage: "bubble.left",
                                       description: Text(model.detailError ?? "这段会话的最近记录里没有文本消息。"))
                    .frame(maxHeight: .infinity)
            }
            HStack(spacing: 12) {
                Button { model.copyCommand(session) } label: {
                    Label("复制恢复命令", systemImage: "doc.on.doc")
                }
                .help("复制适用于当前实例和会话的终端命令")
                Spacer()
                if session.instance.agent.isCodex {
                    Button("在 Codex 中打开") { model.openDesktop(session) }
                        .tint(.white)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help(model.desktopAvailable ? "跳转到此实例的具体会话" : "需要目标实例正在运行。点击可检查当前绑定。")
                }
            }
            .font(.system(size: 12))
            .padding(13)
        }
    }

    private func sessionCompanionPicker(_ session: Session) -> some View {
        let current = model.avatar(for: session)
        return Button {
            editingAvatar = true
        } label: {
            HStack(spacing: 5) {
                CompanionArt(avatar: current)
                    .frame(width: 24, height: 24)
                Text("换头像")
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 7)
            .frame(height: 30)
            .background(.white.opacity(0.075), in: .rect(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .foregroundStyle(text)
        .help("为这条会话选择头像")
        .accessibilityLabel("更换会话头像，当前为\(current.name)")
        .popover(isPresented: $editingAvatar, arrowEdge: .bottom) {
            avatarPicker(for: session)
        }
    }

    private func avatarPicker(for session: Session) -> some View {
        let current = model.avatar(for: session)
        return VStack(alignment: .leading, spacing: 12) {
            Text("会话头像").font(.system(size: 14, weight: .semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(51), spacing: 5), count: 8), spacing: 5) {
                ForEach(CompanionKind.allCases) { kind in
                    let picked = current == .animal(kind)
                    Button {
                        model.chooseAvatar(.animal(kind), for: session)
                        editingAvatar = false
                    } label: {
                        CompanionArt(kind: kind, size: .panel)
                            .frame(width: 33, height: 33)
                            .frame(width: 48, height: 48)
                            .contentShape(.rect)
                            .overlay { Circle().strokeBorder(.white.opacity(picked ? 0.85 : 0), lineWidth: 1) }
                    }
                    .buttonStyle(.plain)
                    .help(kind.name)
                    .accessibilityLabel(kind.name)
                    .accessibilityAddTraits(picked ? .isSelected : [])
                }
            }
            HStack {
                Button("恢复自动") {
                    model.chooseAvatar(nil, for: session)
                    editingAvatar = false
                }
                .buttonStyle(.plain)
                .foregroundStyle(muted)
                Spacer()
                Button {
                    editingAvatar = false
                    Task { @MainActor in model.importAvatar(for: session) }
                } label: {
                    Label("导入项目图标", systemImage: "photo")
                }
                .buttonStyle(.bordered)
            }
            .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(text)
        .padding(16)
        .background(.black)
        .preferredColorScheme(.dark)
    }

    private var settings: some View {
        VStack(spacing: 0) {
            ScrollView {
                instanceSettings
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            settingsActions
        }
        .frame(maxHeight: .infinity)
    }

    private var instanceSettings: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Agent 实例")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(text)
                Text("\(model.activeInstances.count)/\(model.instances.count) 已启用")
                    .font(.system(size: 11))
                    .foregroundStyle(muted)
                Spacer()
                Button("重新检测") { model.detectInstances() }
                Menu {
                    ForEach(Instance.Agent.allCases, id: \.self) { agent in
                        Button(agent.name) { model.addInstance(agent) }
                    }
                } label: {
                    Label("添加目录", systemImage: "plus")
                }
            }
            .controlSize(.small)

            HStack {
                Text("实例与目录")
                Spacer()
                Text("监听").frame(width: 40)
            }
            .font(.system(size: 11))
            .foregroundStyle(muted)
            .padding(.horizontal, 8)
            .padding(.top, 4)

            VStack(spacing: 0) {
                ForEach(model.instances) { instance in
                    HStack(spacing: 10) {
                        Image(systemName: instance.origin == .standard ? "terminal" :
                                instance.origin == .cockpit ? "square.stack" : "folder")
                            .font(.system(size: 14))
                            .foregroundStyle(muted)
                            .frame(width: 19)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(instance.name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(text)
                            Text(instance.root.path.abbreviatingWithTildeInPath)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(muted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(instance.root.path)
                            if let issue = model.issues[instance.id] {
                                Text(issue).font(.caption).foregroundStyle(muted)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if model.canForget(instance) {
                            Button { model.forget(instance) } label: {
                                Image(systemName: "minus.circle").foregroundStyle(muted)
                            }
                            .buttonStyle(.plain)
                            .help("移除此实例")
                        }
                        Toggle("监听 \(instance.name)", isOn: Binding(
                            get: { model.enabled.contains(instance.id) },
                            set: { _ in model.toggleInstance(instance) }
                        ))
                        .toggleStyle(NeutralSwitch())
                        .frame(width: 40)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    Divider().opacity(0.55)
                }
            }
        }
    }

    private var settingsActions: some View {
        HStack(spacing: 16) {
            Button("安装 Codex 头像技能") { model.installAvatarSkill() }
                .help("让本地 Codex 能为当前会话设置 ZooCove 头像")
            Button { showingShortcuts.toggle() } label: {
                Label("快捷键", systemImage: "keyboard")
            }
            .popover(isPresented: $showingShortcuts, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("⌃⌘1–9  从左到右直达")
                    Text("⌃⌘Tab  下一个会话")
                    Text("⌃⌥J  展开或收起")
                    if !model.shortcutConflicts.isEmpty {
                        Text("不可用 · \(model.shortcutConflicts.joined(separator: "、"))")
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(text)
                .padding(13)
                .background(.black)
                .preferredColorScheme(.dark)
            }
            Spacer()
            Button("退出 ZooCove") { NSApplication.shared.terminate(nil) }
        }
        .font(.system(size: 11, weight: .medium))
        .buttonStyle(.plain)
        .foregroundStyle(muted)
        .padding(.horizontal, 16)
        .frame(height: 36)
    }

    private var footer: some View {
        HStack {
            if let notice = model.notice {
                Text(notice).foregroundStyle(text).lineLimit(2)
            } else if model.detail != nil {
                Text("Esc 返回").foregroundStyle(muted)
            } else {
                let unreadable = model.issues.count
                if unreadable > 0 {
                    Text("\(unreadable) 个实例暂时无法读取").foregroundStyle(muted)
                } else if !model.displayedSessions.isEmpty {
                    Text("显示 \(model.displayedSessions.count) 条会话").foregroundStyle(muted)
                }
                Spacer()
                Text("⌃⌘1–9 直达   ⌃⌘Tab 切换   Esc 收起").foregroundStyle(muted)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 16)
        .frame(height: 28)
    }

    private func focusSearch() {
        if !model.settings && model.detail == nil { searchFocused = true }
    }

    private func openSelection() {
        if let session = model.chosenSession { model.show(session) }
    }

}

private struct NeutralSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(Color(white: configuration.isOn ? 0.62 : 0.21))
                Circle().fill(Color(white: 0.96)).frame(width: 13, height: 13).padding(2)
            }
            .frame(width: 31, height: 17)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
        }
    }
}

private extension String {
    var abbreviatingWithTildeInPath: String { (self as NSString).abbreviatingWithTildeInPath }
}
