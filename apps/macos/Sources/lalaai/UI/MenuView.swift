import SwiftUI

/// Menu-bar popover: quick controls while presenting.
struct MenuView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                MicOrb(level: model.level, active: model.isTranscribing, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.room?.slug ?? "La Laai").font(.system(size: 16, weight: .heavy, design: .rounded))
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let err = model.lastError {
                Text(err).font(.system(size: 12)).foregroundStyle(Color.brandWarm).fixedSize(horizontal: false, vertical: true)
            }
            if model.isLive { live } else { start }
            Divider()
            HStack {
                Button { openWindow(id: "setup"); NSApp.activate() } label: { Label("Open La Laai", systemImage: "macwindow") }
                    .buttonStyle(.pill(.ghost))
                Spacer()
                Button("Quit") { Task { await model.endSession(); NSApp.terminate(nil) } }.buttonStyle(.pill(.ghost))
            }
        }
        .padding(18)
        .frame(width: 340)
    }

    private var subtitle: String {
        guard model.isLive else { return "Not live" }
        let relay = model.relayState == .connected ? "connected" : "reconnecting…"
        return "\(model.attendees) in the room · \(relay)"
    }

    private var start: some View {
        @Bindable var model = model
        return VStack(spacing: 10) {
            HStack(spacing: 8) {
                BigField(placeholder: "meetup-name", text: $model.config.slug, icon: "number", mono: true)
                Button { Task { await model.randomizeSlug() } } label: { Image(systemName: "dice.fill") }
                    .buttonStyle(.pill(.secondary)).help("Random name")
            }
            Button { Task { await model.goLive() } } label: {
                HStack { if model.isStarting { ProgressView().controlSize(.small) }; Text("Go live") }.frame(maxWidth: .infinity)
            }
            .buttonStyle(.pill(.primary, large: true))
            .disabled(model.isStarting || model.config.slug.count < 3)
        }
    }

    private var live: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let last = model.lines.last {
                Text(last.text).font(.system(size: 13, weight: .medium, design: .rounded)).lineLimit(3)
                    .foregroundStyle(last.final ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            HStack(spacing: 8) {
                toggle("qr", "qrcode")
                toggle("qa", "bubble.left.and.bubble.right.fill")
                toggle("captions", "captions.bubble.fill")
            }
            HStack(spacing: 8) {
                Button { Task { await model.toggleTranscription() } } label: {
                    Label(model.isTranscribing ? "Pause" : "Resume", systemImage: model.isTranscribing ? "pause.fill" : "mic.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.pill(.secondary))
                Button { Task { await model.endSession() } } label: {
                    Label("End", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.pill(.danger))
            }
        }
    }

    private func toggle(_ key: String, _ icon: String) -> some View {
        let open = model.openPanels.contains(key)
        return Button { model.panels.toggle(key) } label: {
            Image(systemName: icon).font(.system(size: 16, weight: .bold)).frame(maxWidth: .infinity, minHeight: 40)
                .foregroundStyle(open ? Color.white : Color.brandPrimary)
                .background(open ? AnyShapeStyle(Color.brandPrimary) : AnyShapeStyle(Color.brandAqua.opacity(0.18)),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
