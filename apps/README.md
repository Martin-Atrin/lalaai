# apps/ — native presenter apps (not deployed)

| Path | What |
|---|---|
| `macos/` | Presenter app for macOS 26 (SwiftPM). Build with `./build-app.sh`; notarize with `./notarize.sh`. |
| `ios/` | Presenter app for iPhone/iPad (iOS 26). Open `LaLaai.xcodeproj`. |
| `shared/` | Swift shared by both apps: relay protocol and client, on-device speech engine (SpeechAnalyzer + Dictation), Apple Translation wrapper, language helpers, brand. The macOS target includes it through the `Sources/lalaai/Shared` symlink; the Xcode project references it as a synchronized folder. |
| `translator/` | On-device NLLB-200 helper (Python, uv) for languages Apple Translation lacks. Bundled into the Mac app; its Python env lives in `~/Library/Application Support/La Laai/`. |
