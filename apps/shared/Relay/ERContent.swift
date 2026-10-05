// Embedded relay — static content ported from web/relay/src/icebreakers.ts and names.ts.

import Foundation

enum ERContent {
    private typealias Template = @Sendable (_ q: String, _ talk: String) -> [(String, String)]

    // Used when the presenter has no LLM connected (or it times out). Deliberately generic but warm.
    private static let templates: [String: Template] = [
        "en": { q, talk in [
            ("Your question", "What made you curious about “\(q)”?"),
            ("The talk", "What's one idea from “\(talk)” you'd actually try this month?"),
            ("Real world", "Where have you run into this problem in your own work or life?"),
        ] },
        "cs": { q, talk in [
            ("Vaše otázka", "Proč vás zajímá „\(q)“?"),
            ("Přednáška", "Kterou myšlenku z „\(talk)“ byste tento měsíc opravdu vyzkoušeli?"),
            ("Praxe", "Kde jste na tenhle problém narazili vy sami?"),
        ] },
        "de": { q, talk in [
            ("Deine Frage", "Was hat dich an „\(q)“ neugierig gemacht?"),
            ("Der Vortrag", "Welche Idee aus „\(talk)“ würdest du diesen Monat ausprobieren?"),
            ("Praxis", "Wo bist du selbst schon auf dieses Problem gestoßen?"),
        ] },
        "es": { q, talk in [
            ("Tu pregunta", "¿Qué te llevó a preguntar “\(q)”?"),
            ("La charla", "¿Qué idea de “\(talk)” probarías este mes?"),
            ("En la práctica", "¿Dónde te has encontrado con este problema?"),
        ] },
        "fr": { q, talk in [
            ("Ta question", "Qu'est-ce qui t'a donné envie de demander « \(q) » ?"),
            ("La conférence", "Quelle idée de « \(talk) » essaierais-tu ce mois-ci ?"),
            ("En pratique", "Où as-tu déjà rencontré ce problème ?"),
        ] },
        "th": { q, talk in [
            ("คำถามของคุณ", "อะไรทำให้คุณสนใจเรื่อง “\(q)”?"),
            ("ทอล์กนี้", "ไอเดียไหนจาก “\(talk)” ที่คุณอยากลองทำจริง ๆ ในเดือนนี้?"),
            ("ชีวิตจริง", "คุณเคยเจอปัญหานี้ในงานหรือชีวิตของคุณตอนไหนบ้าง?"),
        ] },
        "ja": { q, talk in [
            ("あなたの質問", "「\(q)」に興味を持ったきっかけは？"),
            ("今日のトーク", "「\(talk)」の中で、今月さっそく試したいアイデアは？"),
            ("実体験", "この問題に実際に出会ったのはどんな場面でしたか？"),
        ] },
        "zh": { q, talk in [
            ("你的问题", "是什么让你对“\(q)”感兴趣？"),
            ("这场分享", "“\(talk)”里有哪个想法你这个月就想试试？"),
            ("真实经历", "你在工作或生活中哪里遇到过这个问题？"),
        ] },
        "uk": { q, talk in [
            ("Твоє питання", "Що зацікавило тебе в «\(q)»?"),
            ("Доповідь", "Яку ідею з «\(talk)» ти спробуєш цього місяця?"),
            ("Практика", "Де ти сам стикався з цією проблемою?"),
        ] },
    ]

    /// `fallbackIcebreakers(lang, question, talk)` as JSON `[{topic, prompt}]`.
    static func fallbackIcebreakers(lang: String, question: String, talk: String) -> ERJ {
        let q = erLen(question) > 90 ? erSlice(question, 87) + "…" : question
        // regional variants (zh-TW, pt-PT) fall back to their base language's templates
        let base = String(lang.split(separator: "-", omittingEmptySubsequences: false).first ?? "")
        let t = templates[lang] ?? templates[base] ?? templates["en"]!
        return .arr(t(q, talk).map { .o(["topic": .s($0.0), "prompt": .s($0.1)]) })
    }

    private static let adj = [
        "cosmic", "sunny", "brave", "curious", "gentle", "lucky", "mellow", "nimble", "quiet", "rapid",
        "snappy", "witty", "zesty", "bold", "breezy", "clever", "dapper", "fuzzy", "jolly", "plucky",
        "shiny", "spicy", "swift", "tidy", "vivid", "wild", "cozy", "electric", "golden", "misty",
    ]
    private static let noun = [
        "otter", "falcon", "panda", "lynx", "koala", "badger", "heron", "gecko", "walrus", "yak",
        "comet", "nebula", "pixel", "quasar", "maple", "cactus", "pebble", "harbor", "summit", "meadow",
        "octopus", "narwhal", "puffin", "raccoon", "tapir", "wombat", "orca", "moth", "bison", "fox",
    ]

    static func randomSlug() -> String {
        "\(adj.randomElement()!)-\(noun.randomElement()!)-\(Int.random(in: 10...99))"
    }

    private static let ridAlphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    /// `rid(n)`: random id from a crypto RNG (same alphabet and modulo mapping as server.ts).
    static func rid(_ n: Int = 12) -> String {
        var g = SystemRandomNumberGenerator()
        return String((0..<n).map { _ in ridAlphabet[Int(UInt8.random(in: 0...255, using: &g)) % ridAlphabet.count] })
    }
}
