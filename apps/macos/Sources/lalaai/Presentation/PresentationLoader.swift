import Foundation
import PDFKit

struct Presentation: Codable, Equatable {
    var fileName: String
    var slides: [String]

    var keywords: [String] { Self.keywords(from: slides.joined(separator: "\n")) }

    /// Distinctive terms (proper nouns, acronyms, jargon) used to bias the speech recognizer.
    static func keywords(from text: String, limit: Int = 60) -> [String] {
        var counts: [String: Int] = [:]
        let stop: Set<String> = ["The", "This", "That", "With", "From", "What", "When", "Where", "Your", "Our", "And", "For", "How", "Why", "Slide"]
        text.enumerateSubstrings(in: text.startIndex..., options: .byWords) { w, _, _, _ in
            guard let w, w.count >= 3, !stop.contains(w) else { return }
            let hasUpper = w.first!.isUppercase || w.dropFirst().contains(where: \.isUppercase)
            let hasDigit = w.contains(where: \.isNumber)
            if hasUpper || hasDigit { counts[w, default: 0] += 1 }
        }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(limit).map(\.key)
    }
}

enum PresentationLoader {
    static func load(_ url: URL) throws -> Presentation {
        let ext = url.pathExtension.lowercased()
        let slides: [String]
        switch ext {
        case "pdf":
            guard let doc = PDFDocument(url: url) else { throw Err("Cannot open PDF") }
            slides = (0..<doc.pageCount).map { doc.page(at: $0)?.string ?? "" }
        case "pptx":
            slides = try pptx(url)
        case "key":
            throw Err("Keynote files are packaged — export to PDF (File → Export To → PDF) and load that.")
        default:
            let text = try String(contentsOf: url, encoding: .utf8)
            // markdown decks: split on '---' or H1/H2 headings
            let parts = text.components(separatedBy: "\n---\n")
            slides = parts.count > 1 ? parts : text.components(separatedBy: "\n\n\n")
        }
        let cleaned = slides.map { $0.replacingOccurrences(of: "\u{0}", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
        return Presentation(fileName: url.lastPathComponent, slides: cleaned)
    }

    private static func pptx(_ url: URL) throws -> [String] {
        let list = try shell("/usr/bin/unzip", ["-Z1", url.path])
        let slideFiles = list.split(separator: "\n").map(String.init)
            .filter { $0.range(of: #"^ppt/slides/slide\d+\.xml$"#, options: .regularExpression) != nil }
            .sorted { num($0) < num($1) }
        return try slideFiles.map { f in
            let xml = try shell("/usr/bin/unzip", ["-p", url.path, f])
            // text runs live in <a:t>…</a:t>; paragraphs in <a:p>
            var out: [String] = []
            for para in xml.components(separatedBy: "</a:p>") {
                let runs = matches(#"<a:t>([^<]*)</a:t>"#, in: para)
                if !runs.isEmpty { out.append(runs.joined()) }
            }
            return decodeEntities(out.joined(separator: "\n"))
        }
    }

    private static func num(_ s: String) -> Int { Int(s.filter(\.isNumber)) ?? 0 }

    private static func matches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
            Range($0.range(at: 1), in: s).map { String(s[$0]) }
        }
    }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
    }

    private static func shell(_ bin: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
