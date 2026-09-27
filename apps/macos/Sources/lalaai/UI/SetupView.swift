import SwiftUI
import UniformTypeIdentifiers

/// Main window: session hero on top, then cards for talk, languages, floating windows, AI and relay.
struct SetupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView { SetupContent() }
        .background(
            LinearGradient(colors: [Color.brandAqua.opacity(0.10), Color.clear, Color.brandWarm.opacity(0.05)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .frame(minWidth: 900, minHeight: 700)
        .onChange(of: model.config.targetLangs) { Task { await model.refreshMissingPairs() } }
        .onChange(of: model.config.presenterLocale) { Task { await model.refreshMissingPairs() } }
    }
}

/// The window's content (separate so snapshots can render it without the ScrollView).
struct SetupContent: View {
    var body: some View {
            VStack(spacing: 20) {
                HeaderBar()
                MenuBarHint()
                SessionHero()
                HStack(alignment: .top, spacing: 20) {
                    VStack(spacing: 20) {
                        TalkCard()
                        LanguagesCard()
                    }
                    VStack(spacing: 20) {
                        WindowsCard()
                        AICard()
                        RelayCard()
                    }
                }
            }
            .padding(28)
    }
}

// MARK: - Header

private struct HeaderBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 16) {
            LogoMark().frame(width: 72, height: 57)
            VStack(alignment: .leading, spacing: 2) {
                Wordmark(size: 30)
                Text("MELT THE LANGUAGE BARRIER. BREAK THE ICE.")
                    .font(.system(size: 10, weight: .bold)).kerning(1.6).foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill()
        }
    }
}

private struct StatusPill: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let live = model.isLive
        let connected = model.relayState == .connected
        HStack(spacing: 8) {
            Circle().fill(live ? (connected ? Color.brandWarm : .orange) : Color.secondary.opacity(0.5)).frame(width: 9, height: 9)
            Text(live ? (connected ? "Live" : "Reconnecting…") : "Offline")
                .font(.system(size: 13, weight: .bold, design: .rounded))
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }
}

// MARK: - Session hero

private struct SessionHero: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if model.isLive { liveContent } else { startContent }
            if let err = model.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.brandWarm)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.brandWarm.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(LinearGradient(colors: [Color.brandNavy, Color(red: 0.04, green: 0.20, blue: 0.47)], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(alignment: .topTrailing) {
            // soft aqua glow, echoing the logo drop
            Circle().fill(Color.brandAqua.opacity(0.25)).frame(width: 260).blur(radius: 70).offset(x: 60, y: -90).allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: Color.brandNavy.opacity(0.25), radius: 20, y: 10)
        .environment(\.colorScheme, .dark)
    }

    private var startContent: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ready when you are").font(.system(size: 28, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                Text("Name your meetup, then go live. The QR code floats over your slides.")
                    .font(.system(size: 14)).foregroundStyle(.white.opacity(0.7))
            }
            HStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "number").foregroundStyle(.white.opacity(0.5))
                    TextField("meetup-name", text: $model.config.slug)
                        .textFieldStyle(.plain)
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                    Button { Task { await model.randomizeSlug() } } label: {
                        Image(systemName: "dice.fill").font(.system(size: 16, weight: .bold))
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.plain).foregroundStyle(.white).help("Random name")
                }
                .padding(.leading, 18).padding(.trailing, 8).padding(.vertical, 8)
                .background(Color.white.opacity(0.08), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.15)))

                Button {
                    Task { await model.goLive() }
                } label: {
                    HStack(spacing: 10) {
                        if model.isStarting { ProgressView().controlSize(.small).tint(Color.brandNavy) }
                        else { Image(systemName: "dot.radiowaves.left.and.right") }
                        Text("Go live")
                    }
                    .frame(minWidth: 150)
                }
                .buttonStyle(.pill(.primary, large: true))
                .keyboardShortcut(.defaultAction)
                .disabled(model.isStarting || model.config.slug.count < 3)
            }
            HStack(spacing: 8) {
                infoTag("mic.fill", Lang.name(model.config.presenterLang).components(separatedBy: " · ").first ?? "")
                infoTag("globe", model.config.targetLangs.map(Lang.flag).joined(separator: " "))
                infoTag("sparkles", model.config.llmProvider == .none ? "AI off" : model.config.llmProvider.label)
                infoTag("server.rack", model.config.relayURL == hostedRelayURL ? "La Laai Cloud" : "Custom relay")
            }
        }
    }

    private func infoTag(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold))
            Text(text).font(.system(size: 12, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color.white.opacity(0.1), in: Capsule())
    }

    private var liveContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 22) {
                MicOrb(level: model.level, active: model.isTranscribing, size: 84)
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.room?.slug ?? "").font(.system(size: 28, weight: .heavy, design: .monospaced)).foregroundStyle(.white)
                    if let url = model.joinURL {
                        Button {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url, forType: .string)
                        } label: {
                            Label(url, systemImage: "link").font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        }
                        .buttonStyle(.plain).foregroundStyle(Color.brandAqua).help("Copy join link")
                    }
                }
                Spacer()
                Button { Task { await model.toggleTranscription() } } label: {
                    Label(model.isTranscribing ? "Pause" : "Resume", systemImage: model.isTranscribing ? "pause.fill" : "mic.fill")
                }
                .buttonStyle(.pill(.secondary, large: true))
                Button(role: .destructive) { Task { await model.endSession() } } label: {
                    Label("End", systemImage: "stop.fill")
                }
                .buttonStyle(.pill(.danger, large: true))
            }

            HStack(spacing: 12) {
                StatTile(value: "\(model.attendees)", label: "in the room", icon: "person.2.fill")
                StatTile(value: "\(model.sortedQuestions.count)", label: "questions", icon: "bubble.left.and.bubble.right.fill")
                StatTile(value: "\(model.matchCount)", label: "matches", icon: "hands.sparkles.fill")
                StatTile(value: model.byLang.isEmpty ? "—" : model.byLang.sorted { $0.value > $1.value }.prefix(3).map { Lang.flag($0.key) }.joined(separator: " "),
                         label: "top languages", icon: "globe")
            }

            HStack(spacing: 12) {
                PanelTile(key: "qr", title: "QR code", icon: "qrcode")
                PanelTile(key: "qa", title: "Q&A", icon: "bubble.left.and.text.bubble.right.fill")
                PanelTile(key: "captions", title: "Captions", icon: "captions.bubble.fill")
            }

            if let last = model.lines.last {
                Text(last.text)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(last.final ? 0.95 : 0.65))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .animation(.easeOut(duration: 0.2), value: last.text)
            }
        }
    }
}

struct MicOrb: View {
    var level: Float
    var active: Bool
    var size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(Color.brandWarm.opacity(active ? 0.25 : 0)).frame(width: size, height: size)
                .scaleEffect(1 + CGFloat(level) * 0.45)
            Circle()
                .fill(active ? AnyShapeStyle(LinearGradient(colors: [.brandWarmLight, .brandWarm], startPoint: .top, endPoint: .bottom))
                             : AnyShapeStyle(Color.white.opacity(0.15)))
                .frame(width: size * 0.72, height: size * 0.72)
            Image(systemName: active ? "mic.fill" : "mic.slash.fill").font(.system(size: size * 0.26, weight: .bold)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.12), value: level)
    }
}

private struct StatTile: View {
    var value: String
    var label: String
    var icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon).font(.system(size: 13, weight: .bold)).foregroundStyle(Color.brandAqua)
            Text(value).font(.system(size: 26, weight: .heavy, design: .rounded)).foregroundStyle(.white).contentTransition(.numericText())
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct PanelTile: View {
    @Environment(AppModel.self) private var model
    var key: String
    var title: String
    var icon: String
    var body: some View {
        let open = model.openPanels.contains(key)
        Button {
            model.panels.toggle(key)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 18, weight: .bold))
                    .frame(width: 40, height: 40)
                    .background(open ? Color.brandAqua : Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .foregroundStyle(open ? Color.brandNavy : .white)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    Text(open ? "On screen" : "Hidden").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                Image(systemName: open ? "eye.fill" : "eye.slash").foregroundStyle(.white.opacity(0.6))
            }
            .padding(12)
            .background(Color.white.opacity(open ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(open ? Color.brandAqua.opacity(0.7) : .clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Cards

private struct TalkCard: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false
    @State private var dropping = false

    var body: some View {
        @Bindable var model = model
        Card(title: "Your talk", icon: "person.wave.2.fill", subtitle: "Shown to attendees and used by the AI") {
            VStack(spacing: 12) {
                BigField(placeholder: "Talk title", text: $model.config.title, icon: "textformat")
                BigField(placeholder: "Your name", text: $model.config.presenterName, icon: "person.fill")
                Button { importing = true } label: {
                    HStack(spacing: 14) {
                        Image(systemName: model.presentation == nil ? "doc.badge.plus" : "doc.richtext.fill")
                            .font(.system(size: 24, weight: .semibold)).foregroundStyle(Color.brandPrimary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.presentation?.fileName ?? "Drop your deck here")
                                .font(.system(size: 14, weight: .bold, design: .rounded)).lineLimit(1)
                            Text(model.presentation.map { "\($0.slides.count) slides · \($0.keywords.count) keywords taught to the recognizer" }
                                 ?? "PDF, PPTX or Markdown · or click to choose")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .background(dropping ? Color.brandAqua.opacity(0.15) : Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(dropping ? Color.brandAqua : Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
                    .contentShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                    _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in load(url) }
                    }
                    return true
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .plainText, .text, UTType(filenameExtension: "md")!, UTType(filenameExtension: "pptx")!]) { result in
            guard case .success(let url) = result else { return }
            load(url)
        }
    }

    private func load(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { model.presentation = try PresentationLoader.load(url) } catch { model.lastError = error.localizedDescription }
    }
}

private struct LanguagesCard: View {
    @Environment(AppModel.self) private var model
    @State private var downloadMsg = ""

    var body: some View {
        @Bindable var model = model
        Card(title: "Languages", icon: "globe", subtitle: "Speech and translation run on this Mac") {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("I speak").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $model.config.presenterLocale) {
                        ForEach(model.speechLocales, id: \.identifier) { l in
                            Text("\(Lang.flag(Lang.fromSpeechLocale(l.identifier)))  \(Locale.current.localizedString(forIdentifier: l.identifier) ?? l.identifier)")
                                .tag(l.identifier)
                        }
                        if !model.speechLocales.contains(where: { $0.identifier == model.config.presenterLocale }) {
                            Text(model.config.presenterLocale).tag(model.config.presenterLocale)
                        }
                    }
                    .labelsHidden().frame(maxWidth: 240)
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Audience can read in").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(model.config.targetLangs.count) of \(model.translationLangs.count - 1)")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.tertiary)
                    }
                    FlowLayout(spacing: 6) {
                        ForEach(model.config.targetLangs, id: \.self) { code in
                            LangToken(code: code, extended: model.extendedLangs.contains(code)) { model.config.targetLangs.removeAll { $0 == code } }
                        }
                        AddLanguageButton()
                    }
                }
                ExtendedStatusRow()
                if !model.missingPairs.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.down.circle.fill").font(.system(size: 22)).foregroundStyle(Color.brandWarm)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(model.missingPairs.count) language packs to download").font(.system(size: 13, weight: .bold))
                            Text(model.downloadingPairs ? downloadMsg : "One-time download, then fully offline").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Download") { model.downloadingPairs = true }.buttonStyle(.pill(.primary)).disabled(model.downloadingPairs)
                    }
                    .padding(14)
                    .background(Color.brandWarm.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    if model.downloadingPairs {
                        TranslationDownloader(pairs: model.missingPairs, onProgress: { downloadMsg = $0 }, onDone: { model.pairsDownloaded() })
                    }
                } else {
                    Label("All language packs installed", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.brandAqua)
                }
                if model.isLive {
                    Button("Apply to live session") { model.pushRoomConfig() }.buttonStyle(.pill(.secondary))
                }
            }
        }
    }
}

private struct WindowsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Card(title: "Floating windows", icon: "macwindow.on.rectangle", subtitle: "Float above fullscreen slides") {
            VStack(alignment: .leading, spacing: 14) {
                row("Captions") {
                    PillPicker(options: CaptionMode.allCases, selection: $model.config.captionMode, label: \.label,
                               icon: { $0 == .live ? "text.line.last.and.arrowtriangle.forward" : "text.append" })
                }
                Text(model.config.captionMode.help).font(.system(size: 12)).foregroundStyle(.secondary)
                row("Style") {
                    PillPicker(options: PanelStyle.allCases, selection: $model.config.panelStyle, label: \.label, icon: \.icon)
                }
                if model.config.panelStyle == .clear {
                    Text("Clear windows have no background. Text gets an outline so it stays readable on any slide.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Toggle(isOn: $model.config.panelsAboveFullscreen) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Stay on top of presentations").font(.system(size: 13, weight: .semibold))
                        Text("Keeps QR, Q&A and captions visible over fullscreen Keynote, PowerPoint or Google Slides, without taking keyboard focus.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                row("Caption language") {
                    Picker("", selection: $model.config.captionLang) {
                        Text("\(Lang.flag(model.config.presenterLang))  Original").tag("")
                        ForEach(model.config.targetLangs, id: \.self) { l in
                            Text("\(Lang.flag(l))  \(Lang.displayName(l))").tag(l)
                        }
                    }
                    .labelsHidden()
                }
                row("Caption size") {
                    HStack {
                        Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
                        Slider(value: $model.config.captionFontSize, in: 20...72)
                        Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 14) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).frame(width: 118, alignment: .leading)
            c()
        }
    }
}

private struct AICard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Card(title: "AI icebreakers", icon: "sparkles", subtitle: "Optional · uses your own subscription over MCP") {
            VStack(alignment: .leading, spacing: 14) {
                FlowLayout(spacing: 8) {
                    ForEach(LLMProvider.allCases) { p in
                        Chip(label: p.label, systemImage: icon(p), selected: model.config.llmProvider == p) { model.config.llmProvider = p }
                    }
                }
                if model.config.llmProvider == .custom {
                    BigField(placeholder: "my-agent --mcp $LALAAI_MCP_URL \"$LALAAI_PROMPT\"", text: $model.config.customCommand, icon: "terminal", mono: true)
                } else if model.config.llmProvider != .none {
                    ModelPicker()
                }
                if model.config.llmProvider != .none {
                    HStack(spacing: 10) {
                        Button {
                            Task { await model.checkLLM() }
                        } label: {
                            HStack(spacing: 6) {
                                if model.llmTesting { ProgressView().controlSize(.small) }
                                Text(model.llmTesting ? "Testing…" : "Test connection")
                            }
                        }
                        .buttonStyle(.pill(.secondary)).disabled(model.llmTesting)
                        if let msg = model.llmCheck {
                            Label(msg, systemImage: model.llmCheckOK == true ? "checkmark.circle.fill" : model.llmCheckOK == false ? "xmark.octagon.fill" : "hourglass")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(model.llmCheckOK == true ? Color.brandAqua : model.llmCheckOK == false ? Color.brandWarm : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let last = model.lastAgentResult {
                        Label("Last icebreakers: \(last.text)", systemImage: last.ok ? "sparkles" : "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(last.ok ? Color.brandAqua : Color.brandWarm)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(.secondary)
                    Text(model.mcpURL).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.mcpURL, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Copy MCP URL")
                }
                .padding(12)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .onChange(of: model.config.llmProvider) { _, p in
            // Model ids don't carry across CLIs; start from the default, or a working model if the default is broken.
            model.config.llmModel = ModelCatalog.defaultIsBroken(for: p) ? (ModelCatalog.recommended(for: p) ?? "") : ""
            model.llmCheck = nil
            model.llmCheckOK = nil
        }
    }

    private func icon(_ p: LLMProvider) -> String {
        switch p {
        case .none: return "slash.circle"
        case .claude: return "asterisk"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .gemini: return "sparkle"
        case .custom: return "terminal"
        }
    }
}

private struct RelayCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Card(title: "Relay", icon: "antenna.radiowaves.left.and.right", subtitle: "Where phones connect") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Chip(label: "La Laai Cloud", systemImage: "cloud.fill", selected: model.config.relayURL == hostedRelayURL) {
                        model.config.relayURL = hostedRelayURL
                    }
                    if let ip = Lang.lanIP() {
                        let local = "http://\(ip):8787"
                        Chip(label: "This Mac (Wi-Fi)", systemImage: "laptopcomputer", selected: model.config.relayURL == local) {
                            model.config.relayURL = local
                        }
                    }
                }
                BigField(placeholder: "https://…", text: $model.config.relayURL, icon: "link", mono: true)
            }
        }
    }
}

/// Wrapping row layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: min(maxX, width), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + sz.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}

/// Model dropdown per provider, with an "Other…" escape hatch for ids we don't list.
private struct ModelPicker: View {
    @Environment(AppModel.self) private var model
    @State private var otherMode = false
    private static let other = "__other__"

    var body: some View {
        @Bindable var model = model
        let options = ModelCatalog.options(for: model.config.llmProvider)
        let known = options.contains { $0.id == model.config.llmModel }
        let selection = Binding<String>(
            get: { otherMode || !known ? Self.other : model.config.llmModel },
            set: { v in
                if v == Self.other { otherMode = true } else { otherMode = false; model.config.llmModel = v }
            })
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "cpu").foregroundStyle(.secondary)
                Text("Model").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                Picker("", selection: selection) {
                    ForEach(options) { o in
                        Text(o.detail.map { "\(o.label) — \($0)" } ?? o.label).tag(o.id)
                    }
                    Divider()
                    Text("Other…").tag(Self.other)
                }
                .labelsHidden()
            }
            if otherMode || !known {
                BigField(placeholder: "model id", text: $model.config.llmModel, icon: "character.cursor.ibeam", mono: true)
            }
            if ModelCatalog.defaultIsBroken(for: model.config.llmProvider) && model.config.llmModel.isEmpty {
                Label("Your Codex CLI can't run its configured default model. Pick one from the list, or update Codex.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.brandWarm)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Selected audience language: compact, removable.
private struct LangToken: View {
    var code: String
    var extended = false
    var remove: () -> Void
    @State private var hover = false
    var body: some View {
        HStack(spacing: 5) {
            Text(Lang.flag(code))
            Text(Lang.displayName(code)).lineLimit(1)
            if extended {
                Text("NLLB").font(.system(size: 9, weight: .heavy)).padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().fill(Color.brandWarm.opacity(0.2))).foregroundStyle(Color.brandWarm)
            }
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .heavy))
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.primary.opacity(hover ? 0.15 : 0.07)))
            }
            .buttonStyle(.plain).help("Remove")
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .padding(.leading, 10).padding(.trailing, 5).padding(.vertical, 5)
        .background(Color.brandAqua.opacity(0.18), in: Capsule())
        .onHover { hover = $0 }
    }
}

/// "+ Add language" with a searchable list of every language this Mac can translate to.
private struct AddLanguageButton: View {
    @Environment(AppModel.self) private var model
    @State private var open = false
    @State private var query = ""

    var body: some View {
        Button { open = true } label: {
            Label("Add language", systemImage: "plus").font(.system(size: 12, weight: .bold, design: .rounded))
                .padding(.horizontal, 11).padding(.vertical, 6)
                .foregroundStyle(Color.brandPrimary)
                .background(Capsule().strokeBorder(Color.brandAqua, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) { list }
    }

    private var candidates: [String] {
        let taken = Set(model.config.targetLangs + [model.config.presenterLang])
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return model.translationLangs.filter { !taken.contains($0) }.filter {
            q.isEmpty || Lang.name($0).lowercased().contains(q) || $0.lowercased().hasPrefix(q)
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search languages", text: $query).textFieldStyle(.plain)
            }
            .padding(10)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let apple = candidates.filter { !model.extendedLangs.contains($0) }
                    let ext = candidates.filter { model.extendedLangs.contains($0) }
                    if !apple.isEmpty { sectionHeader("Apple · on-device, Neural Engine") }
                    ForEach(apple, id: \.self) { code in row(code) }
                    if !ext.isEmpty { sectionHeader("Extended · NLLB on this Mac (one-time 600 MB download)") }
                    ForEach(ext, id: \.self) { code in row(code) }
                    if candidates.isEmpty {
                        Text("No more languages").font(.system(size: 12)).foregroundStyle(.secondary).padding(10)
                    }
                }
            }
            .frame(height: 300)
            Text("\(model.appleLangs.count) Apple languages + \(model.extendedLangs.count) extended via NLLB, all on-device.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 340)
    }

    private func sectionHeader(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 10, weight: .heavy)).kerning(0.6).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
    }

    private func row(_ code: String) -> some View {
        Button {
            model.config.targetLangs.append(code)
            query = ""
        } label: {
            HStack(spacing: 10) {
                Text(Lang.flag(code)).font(.system(size: 16))
                Text(Lang.name(code)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer()
                Image(systemName: "plus.circle.fill").foregroundStyle(Color.brandAqua)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Status of the NLLB helper, shown only when a chosen language needs it.
private struct ExtendedStatusRow: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let needed = (model.config.targetLangs + [model.config.presenterLang]).contains { model.extendedLangs.contains($0) }
        if needed {
            HStack(spacing: 10) {
                switch model.extended.status {
                case .ready:
                    Label("Extended languages ready (NLLB, on-device)", systemImage: "checkmark.seal.fill").foregroundStyle(Color.brandAqua)
                case .starting(let stage):
                    ProgressView().controlSize(.small)
                    Text("Extended languages: \(stage)…").foregroundStyle(.secondary)
                case .failed(let msg):
                    Label("Extended languages unavailable: \(msg)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.brandWarm)
                    Spacer()
                    Button("Retry") { model.extended.stop(); model.ensureExtended() }.buttonStyle(.pill(.secondary))
                case .off:
                    Label("Extended languages start when needed", systemImage: "moon.zzz").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Shown when macOS hides our menu-bar icon behind the notch.
private struct MenuBarHint: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if model.menuBarIconHidden {
            HStack(spacing: 12) {
                Image(systemName: "menubar.rectangle").font(.system(size: 20)).foregroundStyle(Color.brandPrimary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your menu bar is full, so macOS hid the La Laai icon behind the notch.")
                        .font(.system(size: 13, weight: .bold))
                    Text("Use the Presenter menu at the top, or these shortcuts from any app: ⌃⌥⌘M mic · ⌃⌥⌘Q QR · ⌃⌥⌘A Q&A · ⌃⌥⌘C captions. ⌘-drag other icons out of the menu bar to make room.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button { model.menuBarIconHidden = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Color.brandAqua.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}
