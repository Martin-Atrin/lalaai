import AVFoundation
import Foundation
import Speech
import SwiftUI
import AppKit

/// `lalaai --selftest <audio-file> [locale] [targets,comma]` — headless check of ASR + translation + MCP.
enum SelfTest {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--selftest") else { return }
        let file = args.count > i + 1 ? args[i + 1] : ""
        let locale = args.count > i + 2 ? args[i + 2] : "en_US"
        let targets = args.count > i + 3 ? args[i + 3].split(separator: ",").map(String.init) : ["de", "es"]
        Task { @MainActor in
            await run(file: file, locale: locale, targets: targets)
            exit(0)
        }
        RunLoop.main.run()
    }

    @MainActor static func run(file: String, locale: String, targets: [String]) async {
        print("== translation languages:", await Lang.translationLanguages().joined(separator: ","))
        let tr = Translator()
        for t in targets { print("== pair en>\(t):", await tr.status(from: "en", to: t)) }
        guard !file.isEmpty else { return }
        do {
            let transcriber = SpeechTranscriber(locale: Locale(identifier: locale), transcriptionOptions: [],
                                                reportingOptions: [.volatileResults], attributeOptions: [])
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                print("== downloading speech model…"); try await req.downloadAndInstall()
            }
            let audio = try AVAudioFile(forReading: URL(fileURLWithPath: file))
            let collector = Task {
                var n = 0
                for try await r in transcriber.results {
                    let text = String(r.text.characters)
                    if r.isFinal {
                        let texts = await tr.translateAll(text, from: Lang.fromSpeechLocale(locale), to: targets)
                        print("FINAL:", text, texts)
                    } else { n += 1 }
                }
                print("== volatile updates:", n)
            }
            let analyzer = try await SpeechAnalyzer(inputAudioFile: audio, modules: [transcriber], finishAfterFile: true)
            _ = analyzer
            try await collector.value
        } catch {
            print("== ERROR:", error)
        }
    }
}

/// `lalaai --snapshot <dir>` renders the floating panels with sample data to PNGs (visual QA without screen recording).
enum Snapshot {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), args.count > i + 1 else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        Task { @MainActor in
            let m = AppModel()
            m.room = RoomInfo(slug: "cosmic-otter-42", title: "On-device ML", presenterName: "Martin", presenterLang: "en",
                              languages: ["en", "es", "fr", "de"], llmEnabled: true, live: true, attendeeCount: 37)
            m.joinURL = "https://lalaai.example.com/m/cosmic-otter-42"
            m.attendees = 37
            let a = Author(uid: "u1", name: "Ana", avatar: "fox", color: "#ff7a59", lang: "es")
            let b = Author(uid: "u2", name: "Jonas", avatar: "owl", color: "#3366ff", lang: "de")
            m.questions = [
                QuestionFull(id: "q1", author: a, original: "¿Cuánta batería consume?", originalLang: "es",
                             texts: ["en": "How much battery does on-device transcription use?"], likes: 14, answered: false, pinned: true, hidden: false, createdAt: 1),
                QuestionFull(id: "q2", author: b, original: "Funktioniert das auch offline?", originalLang: "de",
                             texts: ["en": "Does this also work fully offline?"], likes: 9, answered: false, pinned: false, hidden: false, createdAt: 2),
                QuestionFull(id: "q3", author: a, original: "Can I use my own model?", originalLang: "en",
                             texts: [:], likes: 3, answered: true, pinned: false, hidden: false, createdAt: 3),
            ]
            m.lines = [TranscriptLine(id: 1, text: "The Neural Engine does the heavy lifting,", final: true),
                       TranscriptLine(id: 2, text: "so nothing ever leaves this machine", final: false)]
            @MainActor func render<V: View>(_ name: String, _ v: V, _ size: CGSize) {
                let r = ImageRenderer(content: v.environment(m).frame(width: size.width, height: size.height).background(Color(white: 0.2)))
                r.scale = 2
                if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: dir.appending(path: "\(name).png"))
                }
            }
            render("qr", QRPanelView(), .init(width: 260, height: 320))
            render("qa", QAPanelView(), .init(width: 460, height: 520))
            render("captions", CaptionPanelView(), .init(width: 900, height: 150))
            render("menu", MenuView(), .init(width: 320, height: 330))
            m.translationLangs = ["ar", "de", "en", "es", "fr", "ja", "ko", "th", "vi", "zh"]
            m.config.targetLangs = ["th", "zh", "ja"]
            let setupBG = LinearGradient(colors: [Color.brandAqua.opacity(0.10), Color(nsColor: .windowBackgroundColor), Color.brandWarm.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing)
            render("setup-live", SetupContent().background(setupBG), .init(width: 1000, height: 1250))
            m.lines = [TranscriptLine(id: 1, text: "Welcome everyone to tonight's talk about building products for Southeast Asia.", final: true),
                       TranscriptLine(id: 2, text: "The Neural Engine does the heavy lifting,", final: true),
                       TranscriptLine(id: 3, text: "so nothing ever leaves this machine", final: false)]
            m.config.captionMode = .additive
            render("captions-additive", CaptionPanelView(), .init(width: 1000, height: 190))
            m.config.panelStyle = .clear
            m.config.captionMode = .live
            render("captions-clear", CaptionPanelView().background(LinearGradient(colors: [.orange, .purple], startPoint: .leading, endPoint: .trailing)), .init(width: 1000, height: 190))
            m.config.panelStyle = .solid
            render("qr-solid", QRPanelView(), .init(width: 280, height: 360))
            m.config.panelStyle = .glass
            m.room = nil
            render("setup-start", SetupContent().background(setupBG), .init(width: 1000, height: 1250))
            exit(0)
        }
        RunLoop.main.run()
    }
}
