import CoreImage.CIFilterBuiltins
import SwiftUI

@main
struct LaLaaiPhoneApp: App {
    @State private var model = PhoneModel()
    var body: some Scene {
        WindowGroup {
            Group {
                if model.isLive { LiveScreen() } else { SetupScreen() }
            }
            .environment(model)
            .tint(.brandPrimary)
        }
    }
}

// MARK: - Setup

struct SetupScreen: View {
    @Environment(PhoneModel.self) private var model
    @State private var addingLang = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 6) {
                        LogoMark().frame(width: 96, height: 76)
                        Wordmark(size: 34)
                        Text("MELT THE LANGUAGE BARRIER. BREAK THE ICE.")
                            .font(.system(size: 10, weight: .bold)).kerning(1.4).foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)

                    card {
                        Text("Meetup").font(.headline)
                        HStack {
                            Image(systemName: "number").foregroundStyle(.secondary)
                            TextField("meetup-name", text: $model.config.slug)
                                .font(.system(.title3, design: .monospaced).weight(.bold))
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button { Task { await model.randomizeSlug() } } label: { Image(systemName: "dice.fill") }
                        }
                        TextField("Talk title", text: $model.config.title)
                        TextField("Your name", text: $model.config.presenterName)
                    }

                    card {
                        Text("Languages").font(.headline)
                        Picker("I speak", selection: $model.config.presenterLocale) {
                            ForEach(model.speechLocales, id: \.identifier) { l in
                                Text("\(Lang.flag(Lang.fromSpeechLocale(l.identifier))) \(Locale.current.localizedString(forIdentifier: l.identifier) ?? l.identifier)")
                                    .tag(l.identifier)
                            }
                        }
                        Text("Audience can read in").font(.subheadline).foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(model.config.targetLangs, id: \.self) { code in
                                    Button { model.config.targetLangs.removeAll { $0 == code } } label: {
                                        Label("\(Lang.flag(code)) \(Lang.displayName(code))", systemImage: "xmark.circle.fill")
                                            .labelStyle(TrailingIcon())
                                            .font(.subheadline.weight(.semibold))
                                            .padding(.horizontal, 12).padding(.vertical, 7)
                                            .background(Color.brandAqua.opacity(0.18), in: Capsule())
                                    }.buttonStyle(.plain)
                                }
                                Button { addingLang = true } label: {
                                    Label("Add", systemImage: "plus").font(.subheadline.weight(.bold))
                                        .padding(.horizontal, 12).padding(.vertical, 7)
                                        .overlay(Capsule().strokeBorder(Color.brandAqua, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                                }.buttonStyle(.plain)
                            }
                        }
                    }

                    card {
                        Text("Relay").font(.headline)
                        Picker("Relay", selection: $model.config.relayURL) {
                            Text("La Laai Cloud").tag(hostedRelayURL)
                            if model.config.relayURL != hostedRelayURL { Text(model.config.relayURL).tag(model.config.relayURL) }
                        }
                        .pickerStyle(.segmented)
                        TextField("https://…", text: $model.config.relayURL)
                            .font(.system(.footnote, design: .monospaced))
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    }

                    if let err = model.lastError {
                        Label(err, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.brandWarm).font(.footnote)
                    }
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    Task { await model.goLive() }
                } label: {
                    HStack { if model.isStarting { ProgressView().tint(.white) }; Text("Go live").font(.title3.weight(.heavy)) }
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .foregroundStyle(.white)
                        .background(LinearGradient(colors: [.brandNavy, Color(red: 0.05, green: 0.25, blue: 0.55)], startPoint: .leading, endPoint: .trailing),
                                    in: Capsule())
                }
                .disabled(model.isStarting || model.config.slug.count < 3)
                .padding(.horizontal).padding(.bottom, 8)
                .background(.bar)
            }
            .background(LinearGradient(colors: [Color.brandAqua.opacity(0.10), .clear], startPoint: .top, endPoint: .bottom))
            .sheet(isPresented: $addingLang) { AddLanguageSheet() }
        }
    }

    private func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) { c() }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
    }
}

private struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { configuration.title; configuration.icon.foregroundStyle(.secondary) }
    }
}

struct AddLanguageSheet: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    var body: some View {
        NavigationStack {
            List(model.translationLangs.filter { code in
                !model.config.targetLangs.contains(code) && code != model.config.presenterLang
                    && (query.isEmpty || Lang.name(code).localizedCaseInsensitiveContains(query))
            }, id: \.self) { code in
                Button { model.config.targetLangs.append(code); dismiss() } label: {
                    Text("\(Lang.flag(code))  \(Lang.name(code))")
                }
            }
            .searchable(text: $query)
            .navigationTitle("Add language")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

// MARK: - Live

struct LiveScreen: View {
    @Environment(PhoneModel.self) private var model
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            TabView(selection: $tab) {
                QRTab().tag(0).tabItem { Label("Join", systemImage: "qrcode") }
                CaptionsTab().tag(1).tabItem { Label("Captions", systemImage: "captions.bubble.fill") }
                QATab().tag(2).tabItem { Label("Q&A", systemImage: "bubble.left.and.bubble.right.fill") }
                    .badge(model.sortedQuestions.filter { !$0.answered }.count)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { Task { await model.toggleMic() } } label: {
                ZStack {
                    Circle().fill(model.isTranscribing ? Color.brandWarm.opacity(0.25) : .clear)
                        .scaleEffect(1 + CGFloat(model.level) * 0.5)
                    Circle().fill(model.isTranscribing ? Color.brandWarm : Color.secondary.opacity(0.3)).frame(width: 40, height: 40)
                    Image(systemName: model.isTranscribing ? "mic.fill" : "mic.slash.fill").foregroundStyle(.white)
                }
                .frame(width: 52, height: 52)
                .animation(.easeOut(duration: 0.12), value: model.level)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.room?.slug ?? "").font(.system(.headline, design: .monospaced))
                Text("\(model.status) · \(model.attendees) here · \(model.relayState == .connected ? "online" : "connecting…")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("End", role: .destructive) { Task { await model.end() } }
                .buttonStyle(.borderedProminent).tint(Color.brandWarm)
        }
        .padding(.horizontal).padding(.vertical, 10)
        .background(.bar)
    }
}

private struct QRTab: View {
    @Environment(PhoneModel.self) private var model
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("Scan to join").font(.title2.weight(.heavy))
            if let url = model.joinURL, let img = QRImage.make(url) {
                Image(uiImage: img).interpolation(.none).resizable().scaledToFit()
                    .padding(16).background(.white, in: RoundedRectangle(cornerRadius: 24))
                    .shadow(color: .black.opacity(0.1), radius: 16, y: 6)
                    .padding(.horizontal, 32)
                Text(url).font(.footnote.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text(model.roomLangs.map(Lang.flag).joined(separator: " ")).font(.title2)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(LinearGradient(colors: [Color.brandAqua.opacity(0.12), .clear], startPoint: .top, endPoint: .bottom))
    }
}

private struct CaptionsTab: View {
    @Environment(PhoneModel.self) private var model
    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $model.config.additiveCaptions) {
                    Text("Live").tag(false)
                    Text("Additive").tag(true)
                }
                .pickerStyle(.segmented).frame(maxWidth: 200)
                Spacer()
                Menu {
                    Button("\(Lang.flag(model.config.presenterLang)) Original") { model.config.captionLang = "" }
                    ForEach(model.config.targetLangs, id: \.self) { l in
                        Button("\(Lang.flag(l)) \(Lang.displayName(l))") { model.config.captionLang = l }
                    }
                } label: {
                    Text(model.config.captionLang.isEmpty ? Lang.flag(model.config.presenterLang) : Lang.flag(model.config.captionLang)).font(.title2)
                }
            }
            .padding()
            if model.config.additiveCaptions {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(model.lines.suffix(40).map(model.captionText).joined(separator: " "))
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity, alignment: .leading).padding()
                        Color.clear.frame(height: 1).id("end")
                    }
                    .onChange(of: model.lines.last?.text) { proxy.scrollTo("end", anchor: .bottom) }
                }
            } else {
                Spacer()
                Text(model.lines.last.map(model.captionText) ?? "Start talking…")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(model.lines.last == nil ? .secondary : .primary)
                    .padding()
                    .animation(.easeOut(duration: 0.15), value: model.lines.last?.text)
                Spacer()
            }
        }
    }
}

private struct QATab: View {
    @Environment(PhoneModel.self) private var model
    var body: some View {
        List {
            if model.sortedQuestions.isEmpty {
                ContentUnavailableView("No questions yet", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Questions from the audience appear here, translated into your language."))
            }
            ForEach(model.sortedQuestions) { q in
                VStack(alignment: .leading, spacing: 6) {
                    if q.pinned { Label("On screen", systemImage: "sparkles").font(.caption.weight(.heavy)).foregroundStyle(Color.brandWarm) }
                    Text(q.text(in: model.config.presenterLang)).font(.body.weight(.semibold))
                        .strikethrough(q.answered).foregroundStyle(q.answered ? .secondary : .primary)
                    HStack {
                        Text("\(q.authorLabel) \(Lang.flag(q.originalLang))").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Label("\(q.likes)", systemImage: "heart.fill").font(.caption.weight(.bold)).foregroundStyle(Color.brandWarm)
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button { model.moderate(q, answered: !q.answered, pinned: false) } label: { Label("Answered", systemImage: "checkmark") }.tint(.green)
                    Button(role: .destructive) { model.moderate(q, hidden: true) } label: { Label("Hide", systemImage: "eye.slash") }
                }
                .swipeActions(edge: .leading) {
                    Button { model.moderate(q, pinned: !q.pinned) } label: { Label("Pin", systemImage: "pin.fill") }.tint(Color.brandAqua)
                }
            }
        }
    }
}

enum QRImage {
    static func make(_ text: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: .init(scaleX: 12, y: 12)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
