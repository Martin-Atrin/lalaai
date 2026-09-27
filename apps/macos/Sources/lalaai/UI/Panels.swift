import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Borderless always-on-top panels that float over a fullscreen Keynote/PowerPoint/Google Slides presentation.
@MainActor
final class PanelManager {
    weak var model: AppModel?
    private var panels: [String: NSPanel] = [:]

    func isOpen(_ key: String) -> Bool { panels[key]?.isVisible == true }

    /// Window level for all panels. Above the slideshow "shielding" window when the toggle is on,
    /// so Keynote/PowerPoint in play mode can't cover them.
    var level: NSWindow.Level {
        model?.config.panelsAboveFullscreen == false
            ? .floating
            : NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
    }

    func applyLevel() {
        for p in panels.values {
            p.level = level
            p.collectionBehavior = FloatingPanel.behavior(aboveFullscreen: model?.config.panelsAboveFullscreen != false)
            if p.isVisible { p.orderFrontRegardless() }
        }
    }

    func showQR() { show("qr", size: .init(width: 280, height: 360), min: .init(width: 200, height: 250), corner: .topRight) { QRPanelView() } }
    func showQA() { show("qa", size: .init(width: 480, height: 540), min: .init(width: 320, height: 260), corner: .bottomRight) { QAPanelView() } }
    func showCaptions() { show("captions", size: .init(width: 1000, height: 190), min: .init(width: 360, height: 100), corner: .bottomCenter) { CaptionPanelView() } }

    func toggle(_ key: String) {
        if isOpen(key) { close(key); return }
        switch key {
        case "qr": showQR()
        case "qa": showQA()
        default: showCaptions()
        }
    }

    func close(_ key: String) {
        panels[key]?.orderOut(nil)
        model?.openPanels.remove(key)
    }

    func closeAll() {
        panels.values.forEach { $0.orderOut(nil) }
        model?.openPanels.removeAll()
    }

    enum Corner { case topRight, bottomRight, bottomCenter }

    private func show<V: View>(_ key: String, size: NSSize, min: NSSize, corner: Corner, @ViewBuilder content: () -> V) {
        guard let model else { return }
        model.openPanels.insert(key)
        if let p = panels[key] { p.orderFrontRegardless(); return }
        let panel = FloatingPanel(contentRect: .init(origin: .zero, size: size))
        panel.minSize = min
        panel.level = level
        panel.collectionBehavior = FloatingPanel.behavior(aboveFullscreen: model.config.panelsAboveFullscreen)
        let root = content()
            .environment(model)
            .environment(\.closePanel) { [weak self] in self?.close(key) }
        panel.contentView = NSHostingView(rootView: root)
        if let screen = NSScreen.main?.visibleFrame {
            let m: CGFloat = 24
            let origin: NSPoint
            switch corner {
            case .topRight: origin = .init(x: screen.maxX - size.width - m, y: screen.maxY - size.height - m)
            case .bottomRight: origin = .init(x: screen.maxX - size.width - m, y: screen.minY + m)
            case .bottomCenter: origin = .init(x: screen.midX - size.width / 2, y: screen.minY + m)
            }
            panel.setFrameOrigin(origin)
        }
        panel.setFrameAutosaveName("lalaai.panel.\(key)")
        panels[key] = panel
        panel.orderFrontRegardless()
    }
}

final class FloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.nonactivatingPanel, .borderless, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = Self.behavior(aboveFullscreen: true)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true // clicks don't steal the slideshow's keyboard focus
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // shadows are drawn in SwiftUI so Clear style stays truly clear
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }
    override var canBecomeKey: Bool { true }

    /// On every Space, including a fullscreen app's own Space, and never in Cmd-Tab / Mission Control.
    static func behavior(aboveFullscreen: Bool) -> NSWindow.CollectionBehavior {
        aboveFullscreen
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            : [.canJoinAllSpaces, .ignoresCycle]
    }
}

private struct ClosePanelKey: EnvironmentKey { static let defaultValue: () -> Void = {} }
extension EnvironmentValues {
    var closePanel: () -> Void {
        get { self[ClosePanelKey.self] }
        set { self[ClosePanelKey.self] = newValue }
    }
}

enum QR {
    static func image(_ text: String, size: CGFloat) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage else { return nil }
        let scale = size / out.extent.width
        let scaled = out.transformed(by: .init(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

// MARK: - Style-aware text

/// Text that adapts to the panel style: plain on Glass, white on Solid, outlined on Clear.
struct PanelText: View {
    @Environment(AppModel.self) private var model
    var text: String
    var size: CGFloat
    var weight: Font.Weight = .semibold
    var secondary = false
    var alignment: TextAlignment = .leading

    var body: some View {
        let font = Font.system(size: size, weight: weight, design: .rounded)
        switch model.config.panelStyle {
        case .clear:
            OutlinedText(text: text, font: font, fill: secondary ? .white.opacity(0.8) : .white,
                         width: max(1.5, size / 16), alignment: alignment)
        case .solid:
            Text(text).font(font).multilineTextAlignment(alignment).foregroundStyle(.white.opacity(secondary ? 0.65 : 1))
        case .glass:
            Text(text).font(font).multilineTextAlignment(alignment).foregroundStyle(secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        }
    }
}

// MARK: - Chrome

/// Panel background per style + a hover toolbar. The whole panel stays draggable.
struct PanelChrome<Content: View, Tools: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.closePanel) private var closePanel
    var title: String
    @ViewBuilder var tools: Tools
    @ViewBuilder var content: Content
    @State private var hover = false

    var body: some View {
        let style = model.config.panelStyle
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { background(style) }
        .overlay(alignment: .top) {
            if hover { toolbar.padding(10).transition(.opacity.combined(with: .move(edge: .top))) }
        }
        .overlay(alignment: .bottomTrailing) {
            ResizeGrip()
                .frame(width: 26, height: 26)
                .overlay(GripGlyph().allowsHitTesting(false))
                .opacity(hover ? 1 : (style == .clear ? 0.001 : 0.35))
                .padding(4)
                .help("Drag to resize")
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .padding(10) // room for the drawn shadow
    }

    @ViewBuilder private func background(_ style: PanelStyle) -> some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        switch style {
        case .glass:
            shape.fill(.regularMaterial)
                .overlay(shape.strokeBorder(Color.white.opacity(0.18)))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        case .solid:
            shape.fill(LinearGradient(colors: [Color.brandNavy.opacity(0.96), Color(red: 0.04, green: 0.2, blue: 0.47).opacity(0.96)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(shape.strokeBorder(Color.brandAqua.opacity(0.25)))
                .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        case .clear:
            // Nearly invisible fill keeps the window hoverable and draggable.
            shape.fill(Color.black.opacity(hover ? 0.18 : 0.001))
                .overlay(shape.strokeBorder(Color.white.opacity(hover ? 0.35 : 0), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.9))
                .padding(.leading, 6)
            Spacer(minLength: 8)
            tools
            ToolButton(icon: model.config.panelStyle.icon, help: "Style: \(model.config.panelStyle.label) (click to change)") {
                model.config.panelStyle = model.config.panelStyle.next
            }
            ToolButton(icon: "xmark", help: "Hide", action: closePanel)
        }
        .padding(5)
        .background(Capsule().fill(Color.black.opacity(0.55)))
        .environment(\.colorScheme, .dark)
    }
}

extension PanelChrome where Tools == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.tools = EmptyView()
        self.content = content()
    }
}

struct ToolButton: View {
    var icon: String
    var label: String? = nil
    var help: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold))
                if let label { Text(label).font(.system(size: 11, weight: .bold, design: .rounded)) }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, label == nil ? 0 : 8)
            .frame(minWidth: 26, minHeight: 26)
            .background(Circle().fill(Color.white.opacity(0.14)).opacity(label == nil ? 1 : 0))
            .background(Capsule().fill(Color.white.opacity(0.14)).opacity(label == nil ? 0 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - QR

struct QRPanelView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PanelChrome(title: "Scan to join") {
            VStack(spacing: 12) {
                if let url = model.joinURL, let img = QR.image(url, size: 480) {
                    PanelText(text: "Scan to join", size: 15, weight: .heavy, secondary: true)
                    Image(nsImage: img).interpolation(.none).resizable().aspectRatio(1, contentMode: .fit)
                        .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    HStack(spacing: 8) {
                        LogoMark().frame(width: 30, height: 24)
                        PanelText(text: model.room?.slug ?? "", size: 18, weight: .heavy)
                    }
                    PanelText(text: model.roomLangs.map(Lang.flag).joined(separator: " ") + (model.attendees > 0 ? "  ·  \(model.attendees) here" : ""),
                              size: 13, weight: .semibold, secondary: true)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(18)
        }
    }
}

// MARK: - Q&A

struct QAPanelView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PanelChrome(title: "Audience questions · \(model.sortedQuestions.count)") {
            ToolButton(icon: "textformat.size.smaller", help: "Smaller") { model.config.qaFontSize = max(12, model.config.qaFontSize - 2) }
            ToolButton(icon: "textformat.size.larger", help: "Larger") { model.config.qaFontSize = min(40, model.config.qaFontSize + 2) }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                if let q = model.pinnedQuestion { PinnedQuestion(q: q) }
                if model.sortedQuestions.isEmpty {
                    VStack(spacing: 8) {
                        Text("🙋").font(.system(size: 40))
                        PanelText(text: "Questions from the audience appear here", size: 14, weight: .medium, secondary: true, alignment: .center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(model.sortedQuestions.filter { !$0.pinned }.prefix(12)) { q in QuestionRow(q: q) }
                        }
                    }
                    .scrollIndicators(.never)
                }
            }
            .padding(16)
            .animation(.snappy, value: model.sortedQuestions.map(\.id))
        }
    }
}

private struct PinnedQuestion: View {
    @Environment(AppModel.self) private var model
    let q: QuestionFull
    var body: some View {
        let clear = model.config.panelStyle == .clear
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("On screen", systemImage: "sparkles").font(.system(size: 12, weight: .heavy, design: .rounded)).foregroundStyle(Color.brandWarm)
                Spacer()
                Label("\(q.likes)", systemImage: "heart.fill").font(.system(size: 13, weight: .heavy)).foregroundStyle(Color.brandWarm)
            }
            PanelText(text: q.text(in: model.config.presenterLang), size: model.config.qaFontSize * 1.6, weight: .bold)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                PanelText(text: "— \(q.authorLabel) \(Lang.flag(q.originalLang))", size: 13, weight: .medium, secondary: true)
                Spacer()
                Button("Answered") { model.moderate(q, answered: true, pinned: false) }.buttonStyle(.pill(.secondary))
                Button("Unpin") { model.moderate(q, pinned: false) }.buttonStyle(.pill(.ghost))
            }
        }
        .padding(16)
        .background(Color.brandWarm.opacity(clear ? 0 : 0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.brandWarm.opacity(clear ? 0 : 0.35)))
    }
}

private struct QuestionRow: View {
    @Environment(AppModel.self) private var model
    let q: QuestionFull
    @State private var hover = false
    var body: some View {
        let clear = model.config.panelStyle == .clear
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 1) {
                Image(systemName: "heart.fill").font(.system(size: 12))
                Text("\(q.likes)").font(.system(size: 17, weight: .heavy, design: .rounded).monospacedDigit())
            }
            .frame(width: 38)
            .foregroundStyle(q.likes > 0 ? Color.brandWarm : Color.secondary)
            VStack(alignment: .leading, spacing: 4) {
                PanelText(text: q.text(in: model.config.presenterLang), size: model.config.qaFontSize, weight: .semibold)
                    .strikethrough(q.answered)
                    .opacity(q.answered ? 0.55 : 1)
                    .fixedSize(horizontal: false, vertical: true)
                PanelText(text: "\(q.authorLabel) \(Lang.flag(q.originalLang))", size: max(11, model.config.qaFontSize * 0.75), weight: .medium, secondary: true)
            }
            Spacer(minLength: 0)
            if hover {
                HStack(spacing: 6) {
                    ToolButton(icon: "pin.fill", help: "Show on screen") { model.moderate(q, pinned: true) }
                    ToolButton(icon: "checkmark", help: "Mark answered") { model.moderate(q, answered: !q.answered) }
                    ToolButton(icon: "eye.slash", help: "Hide") { model.moderate(q, hidden: true) }
                }
                .padding(4)
                .background(Capsule().fill(Color.black.opacity(0.5)))
            }
        }
        .padding(12)
        .background(clear ? Color.clear : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hover = $0 }
    }
}

// MARK: - Captions

struct CaptionPanelView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let langLabel = model.config.captionLang.isEmpty ? Lang.flag(model.config.presenterLang) : Lang.flag(model.config.captionLang)
        PanelChrome(title: model.isTranscribing ? "● Live captions" : "Captions (paused)") {
            ToolButton(icon: model.config.captionMode == .live ? "text.line.last.and.arrowtriangle.forward" : "text.append",
                       label: model.config.captionMode.label, help: "Live ↔ Additive") {
                model.config.captionMode = model.config.captionMode == .live ? .additive : .live
            }
            Menu {
                Button("\(Lang.flag(model.config.presenterLang))  Original") { model.config.captionLang = "" }
                ForEach(model.config.targetLangs, id: \.self) { l in
                    Button("\(Lang.flag(l))  \(Lang.displayName(l))") { model.config.captionLang = l }
                }
            } label: {
                Text(langLabel).font(.system(size: 13)).frame(minWidth: 26, minHeight: 26)
                    .background(Circle().fill(Color.white.opacity(0.14)))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("Caption language")
            ToolButton(icon: "textformat.size.smaller", help: "Smaller") { model.config.captionFontSize = max(20, model.config.captionFontSize - 4) }
            ToolButton(icon: "textformat.size.larger", help: "Larger") { model.config.captionFontSize = min(72, model.config.captionFontSize + 4) }
        } content: {
            Group {
                if model.config.captionMode == .live { LiveCaptions() } else { AdditiveCaptions() }
            }
            .padding(.horizontal, 26).padding(.vertical, 18)
        }
    }
}

/// Live: only the utterance being spoken now (or the last finished one), replaced in place.
private struct LiveCaptions: View {
    static func tail(_ s: String, max: Int) -> String {
        guard s.count > max else { return s }
        var cut = String(s.suffix(max))
        if let space = cut.firstIndex(of: " "), cut.distance(from: cut.startIndex, to: space) < 20 { cut = String(cut[cut.index(after: space)...]) }
        return "… " + cut
    }

    @Environment(AppModel.self) private var model
    var body: some View {
        let line = model.lines.last
        GeometryReader { geo in
            // Show the newest words: trim long utterances from the front at a word boundary (languages
            // without spaces, like Thai or Japanese, are trimmed by character).
            let size = model.config.captionFontSize
            let perLine = max(10, Int(geo.size.width / (size * 0.52)))
            let lines = max(1, Int(geo.size.height / (size * 1.25)))
            PanelText(text: Self.tail(line.map(model.captionText) ?? "", max: perLine * lines), size: size, weight: .bold, alignment: .center)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
            .opacity(line?.final == false ? 0.92 : 1)
            .animation(.easeOut(duration: 0.18), value: line?.text)
    }
}

/// Additive: one continuous, growing text. Bottom-anchored and clipped, so the newest words are always in view
/// and older ones flow off the top (Prezefren's additive mode).
private struct AdditiveCaptions: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let recent = Array(model.lines.suffix(30))
        let finished = recent.filter(\.final).map(model.captionText).joined(separator: " ")
        let current = recent.last.flatMap { $0.final ? nil : model.captionText($0) } ?? ""
        GeometryReader { geo in
            PanelText(text: [finished, current].filter { !$0.isEmpty }.joined(separator: " "),
                      size: model.config.captionFontSize, weight: .semibold)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: geo.size.width, alignment: .leading)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomLeading)
                .animation(.easeOut(duration: 0.18), value: finished.count + current.count)
        }
        .clipped()
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.25)], startPoint: .top, endPoint: .bottom))
    }
}

// MARK: - Resizing

/// Corner grip that resizes the borderless panel. An AppKit view, so a drag here never moves the window.
struct ResizeGrip: NSViewRepresentable {
    func makeNSView(context: Context) -> GripView { GripView() }
    func updateNSView(_ nsView: GripView, context: Context) {}

    final class GripView: NSView {
        private var startMouse = NSPoint.zero
        private var startFrame = NSRect.zero

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .frameResize(position: .bottomRight, directions: .all))
        }
        override func mouseDown(with event: NSEvent) {
            startMouse = NSEvent.mouseLocation
            startFrame = window?.frame ?? .zero
        }
        override func mouseDragged(with event: NSEvent) {
            guard let w = window else { return }
            let p = NSEvent.mouseLocation
            var f = startFrame
            f.size.width = max(w.minSize.width, startFrame.width + (p.x - startMouse.x))
            f.size.height = max(w.minSize.height, startFrame.height - (p.y - startMouse.y))
            f.origin.y = startFrame.maxY - f.size.height // keep the top edge in place
            w.setFrame(f, display: true)
        }
        override func mouseUp(with event: NSEvent) {
            window?.saveFrame(usingName: window?.frameAutosaveName ?? "")
        }
    }
}

private struct GripGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            for i in 0..<3 {
                let o = CGFloat(i) * 5 + 6
                var path = Path()
                path.move(to: CGPoint(x: size.width - 4, y: size.height - o))
                path.addLine(to: CGPoint(x: size.width - o, y: size.height - 4))
                ctx.stroke(path, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            }
        }
        .background(Circle().fill(Color.black.opacity(0.45)))
    }
}
