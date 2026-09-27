import SwiftUI

@main
struct LalaaiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        SelfTest.runIfRequested()
        Snapshot.runIfRequested()
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        // Main window: opens on launch so the app is never "invisible".
        Window("La Laai", id: "setup") {
            SetupView()
                .environment(model)
                .tint(.brandPrimary)
        }
        .defaultSize(width: 1000, height: 860)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.presented)

        .commands {
            CommandMenu("Presenter") {
                Button(model.isLive ? "End session" : "Go live") {
                    Task { if model.isLive { await model.endSession() } else { await model.goLive() } }
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                Button(model.isTranscribing ? "Pause mic  (⌃⌥⌘M anywhere)" : "Resume mic  (⌃⌥⌘M anywhere)") {
                    Task { await model.toggleTranscription() }
                }
                .disabled(!model.isLive)
                Divider()
                Button("Show/hide QR code  (⌃⌥⌘Q anywhere)") { model.panels.toggle("qr") }.disabled(!model.isLive)
                Button("Show/hide Q&A  (⌃⌥⌘A anywhere)") { model.panels.toggle("qa") }.disabled(!model.isLive)
                Button("Show/hide captions  (⌃⌥⌘C anywhere)") { model.panels.toggle("captions") }
                Divider()
                Toggle("Stay on top of presentations", isOn: Binding(get: { model.config.panelsAboveFullscreen },
                                                                     set: { model.config.panelsAboveFullscreen = $0 }))
            }
        }

        MenuBarExtra {
            MenuView().environment(model).tint(.brandPrimary)
        } label: {
            Image(systemName: model.isTranscribing ? "waveform.circle.fill" : "waveform.circle")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Scripted/test launches (--autolive) run in the background and never steal focus or keystrokes.
        if CommandLine.arguments.contains("--autolive") {
            NSApp.setActivationPolicy(.accessory)
            DispatchQueue.main.async { NSApp.windows.filter { $0.identifier?.rawValue == "setup" }.forEach { $0.orderOut(nil) } }
            return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Self.dumpWindows() }
    }

    /// Debug aid: LALAAI_DEBUG_WINDOWS=1 logs window frames to stderr.
    static func dumpWindows() {
        guard ProcessInfo.processInfo.environment["LALAAI_DEBUG_WINDOWS"] != nil else { return }
        for w in NSApp.windows {
            FileHandle.standardError.write("win id=\(w.identifier?.rawValue ?? "-") title=\(w.title) frame=\(w.frame) visible=\(w.isVisible) class=\(type(of: w))\n".data(using: .utf8)!)
        }
    }

    /// Clicking the app again (Finder/Dock/Spotlight) brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("setup") == true }) {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return false
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
