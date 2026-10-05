// Embedded relay — rooms, transcript fan-out, Q&A, meet matching. A line-by-line port of
// web/relay/src/server.ts (the reference): same messages, same field order, same send order,
// same limits. Everything here runs on ERServer's serial queue.

import Foundation

/// Insertion-ordered map (JS `Map` semantics for iteration order).
struct EROrdered<V> {
    private(set) var keys: [String] = []
    private var dict: [String: V] = [:]

    subscript(key: String) -> V? { dict[key] }
    var count: Int { keys.count }
    var values: [V] { keys.map { dict[$0]! } }

    mutating func set(_ key: String, _ v: V) {
        if dict.updateValue(v, forKey: key) == nil { keys.append(key) }
    }

    mutating func remove(_ key: String) {
        if dict.removeValue(forKey: key) != nil, let i = keys.firstIndex(of: key) { keys.remove(at: i) }
    }
}

struct ERProfile {
    var uid: String
    var name: String
    var avatar: String
    var color: String
    var lang: String
    var contact: String?
    var tagline: String?
    var spotMe: String?

    var json: ERJ {
        .o(["uid": .s(uid), "name": .s(name), "avatar": .s(avatar), "color": .s(color), "lang": .s(lang),
            "contact": contact.map(ERJ.s), "tagline": tagline.map(ERJ.s), "spotMe": spotMe.map(ERJ.s)])
    }

    /// `{ ...rest, contact, spotMe }` (accepted match peer)
    var revealedJSON: ERJ {
        .o(["uid": .s(uid), "name": .s(name), "avatar": .s(avatar), "color": .s(color), "lang": .s(lang),
            "tagline": tagline.map(ERJ.s), "contact": contact.map(ERJ.s), "spotMe": spotMe.map(ERJ.s)])
    }

    /// `const { contact, spotMe, ...rest } = p`
    var publicJSON: ERJ {
        .o(["uid": .s(uid), "name": .s(name), "avatar": .s(avatar), "color": .s(color), "lang": .s(lang),
            "tagline": tagline.map(ERJ.s)])
    }
}

final class ERAttendee {
    let uid: String
    let secret: String
    var profile: ERProfile?
    var sockets: [ERConnection] = [] // a JS Set: insertion order, no duplicates
    var lastAskAt: Double = 0

    init(uid: String, secret: String) {
        self.uid = uid
        self.secret = secret
    }
}

struct ERSegment {
    var id: Double
    var final: Bool
    var source: String
    /// `msg.texts ?? {}` kept verbatim.
    var texts: ERJ
    var t: Int64
}

final class ERQuestion {
    let id: String
    let authorUid: String
    let original: String
    let originalLang: String
    var texts: ERObj
    var likes: [String] = [] // a JS Set
    let anonymous: Bool
    // Stored verbatim like the reference (moderation assigns whatever the presenter sent).
    var answered: ERJ = .bool(false)
    var pinned: ERJ = .bool(false)
    var hidden: ERJ = .bool(false)
    let createdAt: Int64

    init(id: String, authorUid: String, original: String, originalLang: String, texts: ERObj, anonymous: Bool, createdAt: Int64) {
        self.id = id
        self.authorUid = authorUid
        self.original = original
        self.originalLang = originalLang
        self.texts = texts
        self.anonymous = anonymous
        self.createdAt = createdAt
    }
}

final class ERMatch {
    let id: String
    let fromUid: String
    let toUid: String
    let questionId: String
    var status: String // pending | accepted | declined
    var icebreakers = ERObj() // lang → [Icebreaker]
    var source: String // llm | fallback | pending | none
    let createdAt: Int64
    var timer: DispatchWorkItem?

    init(id: String, fromUid: String, toUid: String, questionId: String, status: String, source: String, createdAt: Int64) {
        self.id = id
        self.fromUid = fromUid
        self.toUid = toUid
        self.questionId = questionId
        self.status = status
        self.source = source
        self.createdAt = createdAt
    }
}

final class ERRoom {
    let slug: String
    var title: String
    var presenterName: String
    var presenterLang: String
    var languages: [String]
    var llmEnabled: Bool
    let presenterToken: String
    var presenter: ERConnection?
    var attendees = EROrdered<ERAttendee>()
    var segments: [ERSegment] = []
    var questions = EROrdered<ERQuestion>()
    var matches = EROrdered<ERMatch>()
    var lastActive: Int64

    init(slug: String, title: String, presenterName: String, presenterLang: String, languages: [String], llmEnabled: Bool, presenterToken: String, lastActive: Int64) {
        self.slug = slug
        self.title = title
        self.presenterName = presenterName
        self.presenterLang = presenterLang
        self.languages = languages
        self.llmEnabled = llmEnabled
        self.presenterToken = presenterToken
        self.lastActive = lastActive
    }
}

final class ERCore {
    static let protocolVersion = 2
    static let minProtocolVersion = 1
    static let capabilities = ["transcript", "qa", "qa.anonymous", "meet", "icebreakers"]
    static let icebreakerTimeout: TimeInterval = 150
    static let roomTTLms: Int64 = 12 * 60 * 60 * 1000
    static let maxSegments = 300

    static let hello: ERJ = .o([
        "protocolVersion": .n(protocolVersion),
        "minProtocolVersion": .n(minProtocolVersion),
        "capabilities": .strs(capabilities),
        "impl": .s("swift"),
    ])
    static let anonAuthor: [(String, String)] = [("uid", ""), ("name", ""), ("avatar", "anon"), ("color", "#8a9bb8")]

    let queue: DispatchQueue
    let staticDir: String?
    let publicURL: String?
    var log: (String) -> Void = { _ in }
    var onRoomCount: (Int) -> Void = { _ in }

    private(set) var rooms: [String: ERRoom] = [:] {
        didSet { if rooms.count != oldValue.count { onRoomCount(rooms.count) } }
    }

    init(queue: DispatchQueue, staticDir: String?, publicURL: String?) {
        self.queue = queue
        self.staticDir = staticDir.map { ERPath.normalize($0) }
        if let u = publicURL, !u.isEmpty {
            self.publicURL = u.hasSuffix("/") ? String(u.dropLast()) : u
        } else {
            self.publicURL = nil
        }
    }

    static func nowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) }

    // MARK: helpers

    /// Canonical BCP-47-ish code that keeps meaningful variants: "zh_tw" → "zh-TW", "pt-pt" → "pt-PT", "EN" → "en".
    static func normLang(_ l: String) throws -> String {
        let src = l.isEmpty ? "en" : l
        let pieces = src.replacingOccurrences(of: "_", with: "-").split(separator: "-", omittingEmptySubsequences: true)
        guard let lang = pieces.first else { throw ERJSTypeError(what: "normLang") }
        var parts = [lang.lowercased()]
        func asciiLetters(_ s: Substring) -> Bool { s.utf8.allSatisfy { ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) } }
        func asciiDigits(_ s: Substring) -> Bool { s.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } }
        for p in pieces.dropFirst() {
            let n = p.utf8.count
            if n == 4 && asciiLetters(p) {
                parts.append(p.prefix(1).uppercased() + p.dropFirst().lowercased()) // script (Hant)
            } else if (n == 2 && asciiLetters(p)) || (n == 3 && asciiDigits(p)) {
                parts.append(p.uppercased()) // region (TW)
            }
        }
        return parts.joined(separator: "-")
    }

    /// normLang applied to an arbitrary JSON value (`(l || "en").replace(...)` throws for non-strings).
    static func normLang(_ v: ERJ?) throws -> String {
        if !erTruthy(v) { return try normLang("en") }
        guard case let .str(s)? = v else { throw ERJSTypeError(what: "normLang") }
        return try normLang(s)
    }

    static func normalizeLangs(_ langs: ERJ?, _ presenterLang: String) throws -> [String] {
        var list: [String] = []
        switch langs {
        case nil, .null?: break
        case let .arr(a)?: list = try a.map { try normLang($0) }
        default: throw ERJSTypeError(what: "languages.map")
        }
        var seen = Set<String>()
        var out: [String] = []
        for l in [presenterLang] + list where seen.insert(l).inserted { out.append(l) }
        return Array(out.prefix(48))
    }

    static func isSlug(_ s: String) -> Bool {
        // /^[a-z0-9][a-z0-9-]{2,39}$/
        let u = Array(s.utf8)
        guard u.count >= 3, u.count <= 40 else { return false }
        func ok(_ c: UInt8, dash: Bool) -> Bool { (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || (dash && c == 45) }
        guard ok(u[0], dash: false) else { return false }
        return u.dropFirst().allSatisfy { ok($0, dash: true) }
    }

    static func isUid(_ s: String) -> Bool {
        // /^[A-Za-z0-9_-]{8,64}$/
        let u = s.utf8
        guard u.count >= 8, u.count <= 64 else { return false }
        return u.allSatisfy { ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 95 || $0 == 45 }
    }

    static func isHexColor(_ s: String) -> Bool {
        // /^#[0-9a-fA-F]{6}$/
        let u = Array(s.utf8)
        guard u.count == 7, u[0] == 35 else { return false }
        return u.dropFirst().allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102) }
    }

    func roomInfo(_ r: ERRoom) -> ERJ {
        var count = 0
        for a in r.attendees.values where !a.sockets.isEmpty && a.profile != nil { count += 1 }
        return .o([
            "slug": .s(r.slug),
            "title": .s(r.title),
            "presenterName": .s(r.presenterName),
            "presenterLang": .s(r.presenterLang),
            "languages": .strs(r.languages),
            "llmEnabled": .b(r.llmEnabled),
            "live": .b(r.presenter != nil),
            "attendeeCount": .n(count),
        ])
    }

    func sendA(_ ws: ERConnection, _ msg: ERJ) { ws.sendText(msg.encoded()) }

    func sendUid(_ r: ERRoom, _ uid: String, _ msg: ERJ) {
        guard let a = r.attendees[uid], !a.sockets.isEmpty else { return }
        let frame = ERConnection.frame(opcode: 0x1, payload: msg.encoded())
        for ws in a.sockets { ws.sendFrame(frame) }
    }

    func sendP(_ r: ERRoom, _ msg: ERJ) { r.presenter?.sendText(msg.encoded()) }

    func eachOnline(_ r: ERRoom, _ fn: (ERAttendee) throws -> Void) rethrows {
        for a in r.attendees.values where !a.sockets.isEmpty { try fn(a) }
    }

    func langOf(_ r: ERRoom, _ uid: String) -> String {
        r.attendees[uid]?.profile?.lang ?? r.presenterLang
    }

    static func lookup(_ texts: ERJ, _ key: String) -> ERJ? {
        if case let .obj(o) = texts { return o[key] }
        return nil
    }

    func segmentView(_ r: ERRoom, _ s: ERSegment, _ lang: String) -> ERJ? {
        var text: ERJ? = lang == r.presenterLang ? .s(s.source) : Self.lookup(s.texts, lang)
        if text == nil {
            if !s.final { return nil } // don't stream untranslated partials
            text = .s(s.source)
        }
        return .o(["id": .num(s.id), "final": .b(s.final), "text": text, "source": .s(s.source), "t": .n(s.t)])
    }

    func publicAuthor(_ r: ERRoom, _ uid: String) -> [(String, String)] {
        let p = r.attendees[uid]?.profile
        return [("uid", uid), ("name", p?.name ?? ""), ("avatar", p?.avatar ?? "blob"), ("color", p?.color ?? "#999999")]
    }

    static func obj(_ pairs: [(String, String)], extra: [(String, ERJ)] = []) -> ERJ {
        var o = ERObj()
        for (k, v) in pairs { o.set(k, .s(v)) }
        for (k, v) in extra { o.set(k, v) }
        return .obj(o)
    }

    func questionView(_ r: ERRoom, _ q: ERQuestion, _ viewerUid: String) -> ERJ {
        let lang = langOf(r, viewerUid)
        let tr: ERJ? = lang == q.originalLang ? nil : q.texts[lang]
        let author = q.anonymous && q.authorUid != viewerUid ? Self.obj(Self.anonAuthor) : Self.obj(publicAuthor(r, q.authorUid))
        return .o([
            "id": .s(q.id),
            "author": author,
            "text": tr ?? .s(q.original),
            "original": .s(q.original),
            "originalLang": .s(q.originalLang),
            "translated": .b(tr != nil),
            "likes": .n(q.likes.count),
            "likedByMe": .b(q.likes.contains(viewerUid)),
            "mine": .b(q.authorUid == viewerUid),
            "anonymous": .b(q.anonymous),
            "answered": q.answered,
            "pinned": q.pinned,
            "createdAt": .n(q.createdAt),
        ])
    }

    func questionFull(_ r: ERRoom, _ q: ERQuestion) -> ERJ {
        let p = r.attendees[q.authorUid]?.profile
        let base = q.anonymous ? Self.anonAuthor : publicAuthor(r, q.authorUid)
        return .o([
            "id": .s(q.id),
            "author": Self.obj(base, extra: [("lang", .s(p?.lang ?? q.originalLang))]),
            "original": .s(q.original),
            "originalLang": .s(q.originalLang),
            "texts": .obj(q.texts),
            "likes": .n(q.likes.count),
            "anonymous": .b(q.anonymous),
            "answered": q.answered,
            "pinned": q.pinned,
            "hidden": q.hidden,
            "createdAt": .n(q.createdAt),
        ])
    }

    func questionText(_ r: ERRoom, _ q: ERQuestion?, _ lang: String) -> ERJ {
        guard let q else { return .s("") }
        return lang == q.originalLang ? .s(q.original) : (q.texts[lang] ?? .s(q.original))
    }

    /// questionText as a plain string (texts values are always strings).
    func questionString(_ r: ERRoom, _ q: ERQuestion?, _ lang: String) -> String {
        questionText(r, q, lang).string ?? ""
    }

    func matchView(_ r: ERRoom, _ m: ERMatch, _ viewerUid: String) -> ERJ {
        let peerUid = m.fromUid == viewerUid ? m.toUid : m.fromUid
        let lang = langOf(r, viewerUid)
        let peer = r.attendees[peerUid]?.profile
            ?? ERProfile(uid: peerUid, name: "", avatar: "blob", color: "#999999", lang: r.presenterLang)
        let q = r.questions[m.questionId]
        let ib: ERJ = m.icebreakers[lang] ?? m.icebreakers[r.presenterLang] ?? m.icebreakers.values.first ?? .arr([])
        let accepted = m.status == "accepted"
        // An anonymous asker stays hidden until the wave is accepted.
        let masked = !accepted && (q?.anonymous ?? false) && q?.authorUid == peerUid
        let peerJSON: ERJ = masked
            ? Self.obj([("uid", "anon-\(m.id)"), ("name", ""), ("avatar", "anon"), ("color", "#8a9bb8"), ("lang", peer.lang)])
            : accepted ? peer.revealedJSON : peer.publicJSON
        return .o([
            "id": .s(m.id),
            "status": .s(m.status),
            "outgoing": .b(m.fromUid == viewerUid),
            "peer": peerJSON,
            "peerMasked": .b(masked),
            "questionId": .s(m.questionId),
            "questionText": questionText(r, q, lang),
            "icebreakers": accepted ? ib : .arr([]),
            "icebreakerSource": .s(accepted ? m.source : "none"),
            "createdAt": .n(m.createdAt),
        ])
    }

    static func pairKey(_ a: String, _ b: String) -> String { a < b ? "\(a)|\(b)" : "\(b)|\(a)" }

    func meetState(_ r: ERRoom, _ uid: String) -> ERJ {
        let lang = langOf(r, uid)
        var matched = Set<String>()
        var matches: [(Int64, ERJ)] = []
        for m in r.matches.values {
            if m.fromUid != uid && m.toUid != uid { continue }
            if m.status != "declined" { matched.insert(m.fromUid == uid ? m.toUid : m.fromUid) }
            // declined requests are only shown to nobody (keeps it low-drama)
            if m.status != "declined" { matches.append((m.createdAt, matchView(r, m, uid))) }
        }
        var likers: [ERJ] = []
        for q in r.questions.values {
            if q.authorUid != uid || q.hidden.truthy || q.likes.isEmpty { continue }
            var people: [ERJ] = []
            for l in q.likes {
                if l == uid || matched.contains(l) { continue }
                if let p = r.attendees[l]?.profile { people.append(p.publicJSON) }
            }
            if !people.isEmpty {
                likers.append(.o(["questionId": .s(q.id), "questionText": questionText(r, q, lang), "people": .arr(people)]))
            }
        }
        // Array.prototype.sort is stable: newest first, ties keep insertion order
        let sorted = matches.enumerated().sorted { a, b in
            a.element.0 != b.element.0 ? a.element.0 > b.element.0 : a.offset < b.offset
        }.map { $0.element.1 }
        return .o(["likers": .arr(likers), "matches": .arr(sorted)])
    }

    func pushMeet(_ r: ERRoom, _ uid: String) {
        // meetState is only built when someone will receive it
        guard let a = r.attendees[uid], !a.sockets.isEmpty else { return }
        sendUid(r, uid, .o(["type": .s("meet.update"), "meet": meetState(r, uid)]))
    }

    func broadcastRoom(_ r: ERRoom) {
        let msg: ERJ = .o(["type": .s("room.update"), "room": roomInfo(r)])
        let frame = ERConnection.frame(opcode: 0x1, payload: msg.encoded())
        eachOnline(r) { a in for ws in a.sockets { ws.sendFrame(frame) } }
        r.presenter?.sendFrame(frame)
    }

    func pushStats(_ r: ERRoom) {
        guard r.presenter != nil else { return }
        var byLang = ERObj()
        var attendees = 0
        eachOnline(r) { a in
            guard let p = a.profile else { return }
            attendees += 1
            let n = byLang[p.lang].map { erJSNumber($0) } ?? 0
            byLang.set(p.lang, .num(n + 1))
        }
        sendP(r, .o(["type": .s("stats"), "attendees": .n(attendees), "byLang": .obj(byLang)]))
    }

    func broadcastQuestion(_ r: ERRoom, _ q: ERQuestion) {
        if q.hidden.truthy {
            let frame = ERConnection.frame(opcode: 0x1, payload: ERJ.o(["type": .s("question.remove"), "id": .s(q.id)]).encoded())
            eachOnline(r) { a in for ws in a.sockets { ws.sendFrame(frame) } }
        } else {
            eachOnline(r) { a in sendUid(r, a.uid, .o(["type": .s("question.upsert"), "question": questionView(r, q, a.uid)])) }
        }
        sendP(r, .o(["type": .s("question.state"), "question": questionFull(r, q)]))
    }

    func welcomeAttendee(_ r: ERRoom, _ ws: ERConnection, _ uid: String) {
        let a = r.attendees[uid]!
        let lang = langOf(r, uid)
        let segments = r.segments.compactMap { segmentView(r, $0, lang) }.suffix(80)
        let questions = r.questions.values.filter { !$0.hidden.truthy }.map { questionView(r, $0, uid) }
        sendA(ws, .o([
            "type": .s("welcome"),
            "room": roomInfo(r),
            "you": a.profile?.json ?? .null,
            "segments": .arr(Array(segments)),
            "questions": .arr(questions),
            "meet": meetState(r, uid),
            "relay": Self.hello,
        ]))
    }

    // MARK: icebreakers

    func jobFor(_ r: ERRoom, _ m: ERMatch) -> ERJ {
        let q = r.questions[m.questionId]
        var langs: [String] = []
        let people: [ERJ] = [m.fromUid, m.toUid].map { uid in
            let p = r.attendees[uid]?.profile
            let lang = p?.lang ?? r.presenterLang
            if !langs.contains(lang) { langs.append(lang) }
            let name = (p?.name).flatMap { $0.isEmpty ? nil : $0 } ?? "Guest"
            return .o(["uid": .s(uid), "name": .s(name), "lang": .s(lang), "tagline": p?.tagline.map(ERJ.s)])
        }
        return .o([
            "matchId": .s(m.id),
            "question": .o([
                "id": .s(m.questionId),
                "text": .s(q?.original ?? ""),
                "lang": .s(q?.originalLang ?? r.presenterLang),
                "presenterText": q.map { questionText(r, $0, r.presenterLang) },
            ]),
            "people": .arr(people),
            "langs": .strs(langs),
        ])
    }

    func applyFallback(_ r: ERRoom, _ m: ERMatch) {
        let q = r.questions[m.questionId]
        var langs: [String] = []
        for l in [langOf(r, m.fromUid), langOf(r, m.toUid)] where !langs.contains(l) { langs.append(l) }
        for l in langs {
            m.icebreakers.set(l, ERContent.fallbackIcebreakers(lang: l, question: questionString(r, q, l), talk: r.title))
        }
        m.source = "fallback"
    }

    func startIcebreakers(_ r: ERRoom, _ m: ERMatch) {
        if r.llmEnabled && r.presenter != nil {
            m.source = "pending"
            sendP(r, .o(["type": .s("icebreakers.needed"), "job": jobFor(r, m)]))
            // like setTimeout, the room/match stay referenced until the timer fires (or is cancelled)
            let work = DispatchWorkItem { [weak self] in
                m.timer = nil // break the match ↔ work item cycle
                guard let self, m.source == "pending" else { return }
                self.applyFallback(r, m)
                self.pushMeet(r, m.fromUid)
                self.pushMeet(r, m.toUid)
            }
            m.timer = work
            queue.asyncAfter(deadline: .now() + Self.icebreakerTimeout, execute: work)
        } else {
            applyFallback(r, m)
        }
    }

    // MARK: message handlers

    func onAttendee(_ r: ERRoom, _ uid: String, _ ws: ERConnection, _ msg: ERObj) throws {
        let a = r.attendees[uid]!
        func toast(_ kind: String, _ message: String) {
            sendA(ws, .o(["type": .s("toast"), "kind": .s(kind), "message": .s(message)]))
        }

        switch msg["type"]?.string {
        case "ping":
            sendA(ws, .o(["type": .s("pong")]))

        case "profile.update":
            let p = msg["profile"]?.object ?? ERObj() // non-objects have none of these fields
            let lang = try Self.normLang(erClean(p["lang"], 16))
            let langChanged = a.profile?.lang != lang
            let wasNew = a.profile == nil
            let color: String
            if case let .str(c)? = p["color"], Self.isHexColor(c) { color = c } else { color = "#45c2f9" }
            func opt(_ s: String) -> String? { s.isEmpty ? nil : s }
            a.profile = ERProfile(
                uid: uid,
                name: erClean(p["name"], 32), // optional: attendees may stay nameless until they ask or meet
                avatar: opt(erClean(p["avatar"], 24)) ?? "blob",
                color: color,
                lang: r.languages.contains(lang) ? lang : r.presenterLang,
                contact: opt(erClean(p["contact"], 120)),
                tagline: opt(erClean(p["tagline"], 120)),
                spotMe: opt(erClean(p["spotMe"], 80))
            )
            // Re-localize everything for all of this user's sockets.
            for s in a.sockets { welcomeAttendee(r, s, uid) }
            if wasNew || langChanged { broadcastRoom(r) }
            pushStats(r)
            // Name/avatar changes show on their questions & in others' meet lists.
            for q in r.questions.values where q.authorUid == uid { broadcastQuestion(r, q) }

        case "question.ask":
            guard let profile = a.profile else { return toast("error", "profile required") }
            let text = erClean(msg["text"], 280)
            if erLen(text) < 3 { return }
            let now = Self.nowMs()
            if Double(now) - a.lastAskAt < 8000 { return toast("error", "slow down") }
            a.lastAskAt = Double(now)
            var texts = ERObj()
            texts.set(profile.lang, .s(text))
            let q = ERQuestion(id: ERContent.rid(10), authorUid: uid, original: text, originalLang: profile.lang,
                               texts: texts, anonymous: erTruthy(msg["anonymous"]), createdAt: now)
            r.questions.set(q.id, q)
            eachOnline(r) { o in sendUid(r, o.uid, .o(["type": .s("question.upsert"), "question": questionView(r, q, o.uid)])) }
            sendP(r, .o(["type": .s("question.new"), "question": questionFull(r, q)]))

        case "question.like":
            guard case let .str(id)? = msg["id"], let q = r.questions[id], !q.hidden.truthy, a.profile != nil else { return }
            if erTruthy(msg["like"]) {
                if !q.likes.contains(uid) { q.likes.append(uid) }
            } else {
                q.likes.removeAll { $0 == uid }
            }
            broadcastQuestion(r, q)
            pushMeet(r, q.authorUid)

        case "question.delete":
            guard case let .str(id)? = msg["id"], let q = r.questions[id], q.authorUid == uid else { return }
            r.questions.remove(q.id)
            let frame = ERConnection.frame(opcode: 0x1, payload: ERJ.o(["type": .s("question.remove"), "id": .s(q.id)]).encoded())
            eachOnline(r) { o in for s in o.sockets { s.sendFrame(frame) } }
            sendP(r, .o(["type": .s("question.remove"), "id": .s(q.id)]))
            pushMeet(r, uid)

        case "meet.request":
            let q: ERQuestion? = msg["questionId"]?.string.flatMap { r.questions[$0] }
            // no toUid = wave at the (maybe anonymous) asker; a truthy non-string toUid matches nobody
            let toRaw = msg["toUid"]
            var to: String?
            var toInvalid = false
            if erTruthy(toRaw) {
                if case let .str(s)? = toRaw { to = s } else { toInvalid = true }
            } else {
                to = q?.authorUid
            }
            guard let q, let to, !toInvalid, let profile = a.profile, to != uid, r.attendees[to]?.profile != nil else {
                return toast("error", "cannot meet")
            }
            let linked = (q.authorUid == to && q.likes.contains(uid)) || (q.authorUid == uid && q.likes.contains(to))
            if !linked { return toast("error", "you are not connected by this question") }
            let key = Self.pairKey(uid, to)
            if let existing = r.matches.values.first(where: { Self.pairKey($0.fromUid, $0.toUid) == key && $0.status != "declined" }) {
                if existing.status == "pending" && existing.toUid == uid {
                    // they already asked us -> instant match
                    existing.status = "accepted"
                    startIcebreakers(r, existing)
                    notifyMatch(r, existing)
                }
                pushMeet(r, uid)
                return
            }
            let m = ERMatch(id: ERContent.rid(10), fromUid: uid, toUid: to, questionId: q.id, status: "pending", source: "none", createdAt: Self.nowMs())
            r.matches.set(m.id, m)
            pushMeet(r, uid)
            pushMeet(r, to)
            let hideMe = q.anonymous && q.authorUid == uid
            sendUid(r, to, .o(["type": .s("toast"), "kind": .s("info"), "message": .s(hideMe ? "👋" : "👋 \(profile.name.isEmpty ? "?" : profile.name)")]))

        case "meet.respond":
            guard case let .str(mid)? = msg["matchId"], let m = r.matches[mid], m.toUid == uid, m.status == "pending" else { return }
            m.status = erTruthy(msg["accept"]) ? "accepted" : "declined"
            if m.status == "accepted" {
                startIcebreakers(r, m)
                notifyMatch(r, m)
            }
            pushMeet(r, m.fromUid)
            pushMeet(r, m.toUid)

        default:
            break
        }
    }

    func notifyMatch(_ r: ERRoom, _ m: ERMatch) {
        for (me, other) in [(m.fromUid, m.toUid), (m.toUid, m.fromUid)] {
            let n = r.attendees[other]?.profile?.name ?? ""
            sendUid(r, me, .o(["type": .s("toast"), "kind": .s("match"), "message": .s("🎉 \(n.isEmpty ? "?" : n)")]))
            pushMeet(r, me)
        }
    }

    func onPresenter(_ r: ERRoom, _ msg: ERObj) throws {
        switch msg["type"]?.string {
        case "ping":
            sendP(r, .o(["type": .s("pong")]))

        case "segment":
            var id = erJSNumber(msg["id"]).rounded(.towardZero)
            if id.isNaN || id == 0 { id = 0 } // `|| 0` (also turns -0 into 0)
            var texts: ERJ = .obj(ERObj())
            if let t = msg["texts"], t != ERJ.null { texts = t }
            let seg = ERSegment(id: id, final: erTruthy(msg["final"]), source: erClean(msg["source"], 4000), texts: texts, t: Self.nowMs())
            if let last = r.segments.last, last.id == seg.id { r.segments[r.segments.count - 1] = seg } else { r.segments.append(seg) }
            if r.segments.count > Self.maxSegments { r.segments.removeFirst(r.segments.count - Self.maxSegments) }
            var cache: [String: Data?] = [:]
            eachOnline(r) { a in
                let lang = langOf(r, a.uid)
                if cache[lang] == nil {
                    let v = segmentView(r, seg, lang)
                    cache[lang] = .some(v.map { ERConnection.frame(opcode: 0x1, payload: ERJ.o(["type": .s("segment"), "segment": $0]).encoded()) })
                }
                if let f = cache[lang] ?? nil { for ws in a.sockets { ws.sendFrame(f) } }
            }

        case "question.translations":
            guard case let .str(id)? = msg["id"], let q = r.questions[id] else { return }
            for (l, t) in erEntries(msg["texts"]) {
                if case let .str(s) = t {
                    let tt = erTrim(s)
                    if !tt.isEmpty { q.texts.set(try Self.normLang(l), .s(erSlice(tt, 600))) }
                }
            }
            broadcastQuestion(r, q)
            // translated question text shows up in meet lists / match cards
            pushMeet(r, q.authorUid)
            for m in r.matches.values where m.questionId == q.id {
                pushMeet(r, m.fromUid)
                pushMeet(r, m.toUid)
            }

        case "question.moderate":
            guard case let .str(id)? = msg["id"], let q = r.questions[id] else { return }
            if let v = msg["answered"] { q.answered = v }
            if let v = msg["hidden"] { q.hidden = v }
            if let v = msg["pinned"] {
                // only one question on screen at a time
                if v.truthy {
                    for o in r.questions.values where o.pinned.truthy && o.id != q.id {
                        o.pinned = .bool(false)
                        broadcastQuestion(r, o)
                    }
                }
                q.pinned = v
            }
            broadcastQuestion(r, q)

        case "icebreakers.result":
            guard case let .str(mid)? = msg["matchId"], let m = r.matches[mid], m.source == "pending" else { return }
            m.timer?.cancel()
            m.timer = nil
            var got = ERObj()
            for (l, list) in erEntries(msg["icebreakers"]) {
                guard case let .arr(items) = list else { continue }
                let ok: [ERJ] = items.filter { i in
                    guard i.truthy, case .str? = i["prompt"] else { return false }
                    return true
                }.prefix(5).map { i in .o(["topic": .s(erClean(i["topic"], 60)), "prompt": .s(erClean(i["prompt"], 300))]) }
                if !ok.isEmpty { got.set(try Self.normLang(l), .arr(ok)) }
            }
            if erTruthy(msg["error"]) || got.isEmpty {
                applyFallback(r, m)
            } else {
                m.icebreakers = got
                m.source = "llm"
            }
            pushMeet(r, m.fromUid)
            pushMeet(r, m.toUid)

        case "room.config":
            if msg["title"] != nil {
                let t = erClean(msg["title"], 80)
                if !t.isEmpty { r.title = t }
            }
            if msg["presenterName"] != nil { r.presenterName = erClean(msg["presenterName"], 60) }
            if erTruthy(msg["presenterLang"]) { r.presenterLang = try Self.normLang(msg["presenterLang"]) }
            if erTruthy(msg["languages"]) { r.languages = try Self.normalizeLangs(msg["languages"], r.presenterLang) }
            if let v = msg["llmEnabled"] { r.llmEnabled = v.truthy }
            broadcastRoom(r)

        default:
            break
        }
    }

    // MARK: HTTP

    func publicBase(_ req: ERRequest) -> String {
        if let publicURL { return publicURL }
        let proto = req.header("x-forwarded-proto") ?? "http"
        let host = req.header("x-forwarded-host") ?? req.header("host") ?? "localhost"
        return "\(proto)://\(host)"
    }

    func createRoom(_ req: ERRequest) -> ERResponse {
        guard let parsed = ERJSONParser.parse(req.body) else { return .json(.o(["error": .s("bad json")]), 400) }
        if parsed == ERJ.null { return Self.internalError() } // `null.slug` throws
        let body = parsed.object ?? ERObj()
        let slug = erClean(body["slug"], 40).lowercased()
        if !Self.isSlug(slug) { return .json(.o(["error": .s("slug must be 3-40 chars: a-z 0-9 -")]), 400) }
        do {
            let pl = erClean(body["presenterLang"], 16)
            let presenterLang = try Self.normLang(pl.isEmpty ? "en" : pl)
            let token = body["presenterToken"]
            let r: ERRoom
            if let existing = rooms[slug] {
                guard erTruthy(token), token?.string == existing.presenterToken else {
                    return .json(.o(["error": .s("meetup name taken")]), 409)
                }
                let t = erClean(body["title"], 80)
                if !t.isEmpty { existing.title = t }
                existing.presenterName = erClean(body["presenterName"], 60)
                existing.presenterLang = presenterLang
                existing.languages = try Self.normalizeLangs(body["languages"], presenterLang)
                existing.llmEnabled = erTruthy(body["llmEnabled"])
                broadcastRoom(existing)
                r = existing
            } else {
                let t = erClean(body["title"], 80)
                let langs = try Self.normalizeLangs(body["languages"], presenterLang)
                var tok = ERContent.rid(32)
                if case let .str(s)? = token, erLen(s) >= 16 { tok = s }
                r = ERRoom(slug: slug, title: t.isEmpty ? slug : t, presenterName: erClean(body["presenterName"], 60),
                           presenterLang: presenterLang, languages: langs, llmEnabled: erTruthy(body["llmEnabled"]),
                           presenterToken: tok, lastActive: Self.nowMs())
                rooms[slug] = r
            }
            return .json(.o([
                "room": roomInfo(r),
                "presenterToken": .s(r.presenterToken),
                "joinUrl": .s("\(publicBase(req))/m/\(slug)"),
                "relay": Self.hello,
            ]))
        } catch {
            log("createRoom error: \(error)")
            return Self.internalError()
        }
    }

    static func internalError() -> ERResponse {
        // Bun's default error page is HTML
        ERResponse(status: 500, headers: [("Content-Type", "text/html;charset=utf-8")], body: Array("<!doctype html><title>Internal Server Error</title><h1>500 Internal Server Error</h1>".utf8))
    }

    func serveStatic(_ pathname: String) -> ERResponse {
        guard let dir = staticDir else {
            return .text("lalaai relay is running. PWA not built (pnpm -C pwa build).")
        }
        guard let decoded = ERURL.decodeURIComponent(pathname) else { return Self.internalError() } // URIError
        var rel = ERPath.normalize(decoded)
        while rel.hasPrefix("../") || rel.hasPrefix("..\\") { rel.removeFirst(3) }
        let path = ERPath.join(dir, rel)
        let fm = FileManager.default
        if path.hasPrefix(dir) && !rel.hasSuffix("/") {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue, let data = fm.contents(atPath: path) {
                let immutable = rel.hasPrefix("/assets/")
                let (type, disposition) = ERMime.type(for: path)
                var headers: [(String, String)] = [
                    ("Cache-Control", immutable ? "public, max-age=31536000, immutable" : "no-cache"),
                    ("Content-Type", type),
                ]
                if disposition { headers.append(("Content-Disposition", "filename=\"\((path as NSString).lastPathComponent)\"")) }
                return ERResponse(status: 200, headers: headers, body: [UInt8](data))
            }
        }
        let index = ERPath.join(dir, "index.html")
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: index, isDirectory: &isDir), !isDir.boolValue, let data = fm.contents(atPath: index) {
            return ERResponse(status: 200, headers: [("Content-Type", "text/html"), ("Cache-Control", "no-cache")], body: [UInt8](data))
        }
        return .text("lalaai relay is running. PWA not built (pnpm -C pwa build).")
    }

    func route(_ req: ERRequest) -> ERRouteResult {
        let p = req.pathname
        if req.method == "OPTIONS" { return .response(ERResponse(status: 200, headers: ERResponse.cors)) }

        if p == "/ws" {
            let slug = (ERURL.param(req.query, "room") ?? "").lowercased()
            guard let r = rooms[slug] else { return .response(.text("no such room", 404)) }
            let v = erJSNumber(ERURL.param(req.query, "v") ?? "1")
            if !(v.isFinite && v == v.rounded(.towardZero)) || v < Double(Self.minProtocolVersion) {
                return .response(.json(.o(["error": .s("protocol"), "min": .n(Self.minProtocolVersion), "max": .n(Self.protocolVersion)]), 426))
            }
            if ERURL.param(req.query, "role") == "presenter" {
                if ERURL.param(req.query, "token") != r.presenterToken { return .response(.text("bad token", 403)) }
                return .upgrade(.presenter(slug: slug))
            }
            let uid = ERURL.param(req.query, "uid") ?? ""
            let secret = ERURL.param(req.query, "secret") ?? ""
            if !Self.isUid(uid) || erLen(secret) < 16 { return .response(.text("bad identity", 400)) }
            if let a = r.attendees[uid] {
                if a.secret != secret { return .response(.text("identity mismatch", 403)) }
            } else {
                r.attendees.set(uid, ERAttendee(uid: uid, secret: secret))
            }
            return .upgrade(.attendee(slug: slug, uid: uid))
        }

        if p == "/api/health" {
            return .response(.json(.o(["ok": .b(true), "rooms": .n(rooms.count), "relay": Self.hello])))
        }
        if p == "/api/names/random" {
            var slug = ERContent.randomSlug()
            while rooms[slug] != nil { slug = ERContent.randomSlug() }
            return .response(.json(.o(["slug": .s(slug)])))
        }
        if p == "/api/rooms" && req.method == "POST" { return .response(createRoom(req)) }
        let prefix = "/api/rooms/"
        if p.hasPrefix(prefix) {
            let s = String(p.dropFirst(prefix.count))
            if !s.isEmpty && s.utf8.allSatisfy({ ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 }) {
                if let r = rooms[s] { return .response(.json(roomInfo(r))) }
                return .response(.json(.o(["error": .s("not found")]), 404))
            }
        }
        if p.hasPrefix("/api/") { return .response(.json(.o(["error": .s("not found")]), 404)) }
        return .response(serveStatic(p))
    }

    // MARK: WebSocket lifecycle

    func wsOpen(_ ws: ERConnection) {
        guard let role = ws.role, let r = rooms[role.slug] else { ws.close(); return }
        r.lastActive = Self.nowMs()
        switch role {
        case .presenter:
            if let old = r.presenter, old !== ws { old.close(code: 4000, reason: "replaced") }
            r.presenter = ws
            let pendingJobs = r.matches.values.filter { $0.source == "pending" }.map { jobFor(r, $0) }
            let questions = r.questions.values.map { questionFull(r, $0) }
            ws.sendText(ERJ.o([
                "type": .s("presenter.welcome"),
                "room": roomInfo(r),
                "questions": .arr(questions),
                "pendingJobs": .arr(pendingJobs),
                "relay": Self.hello,
            ]).encoded())
            broadcastRoom(r)
            pushStats(r)
        case let .attendee(_, uid):
            guard let a = r.attendees[uid] else { ws.close(); return }
            if !a.sockets.contains(where: { $0 === ws }) { a.sockets.append(ws) }
            welcomeAttendee(r, ws, a.uid)
            if a.profile != nil && a.sockets.count == 1 {
                broadcastRoom(r)
                pushStats(r)
            }
        }
    }

    func wsMessage(_ ws: ERConnection, _ raw: [UInt8]) {
        guard let role = ws.role, let r = rooms[role.slug] else { return }
        r.lastActive = Self.nowMs()
        guard let parsed = ERJSONParser.parse(raw), case let .obj(msg) = parsed, case .str? = msg["type"] else { return }
        do {
            switch role {
            case .presenter:
                if r.presenter === ws { try onPresenter(r, msg) }
            case let .attendee(_, uid):
                try onAttendee(r, uid, ws, msg)
            }
        } catch {
            log("handler error \(error)")
        }
    }

    func wsClose(_ ws: ERConnection) {
        guard let role = ws.role, let r = rooms[role.slug] else { return }
        switch role {
        case .presenter:
            if r.presenter === ws {
                r.presenter = nil
                broadcastRoom(r)
            }
        case let .attendee(_, uid):
            guard let a = r.attendees[uid] else { return }
            a.sockets.removeAll { $0 === ws }
            if a.profile != nil && a.sockets.isEmpty {
                broadcastRoom(r)
                pushStats(r)
            }
        }
    }

    /// Drops rooms nobody presented in for 12 h.
    func sweep() {
        let now = Self.nowMs()
        for (slug, r) in rooms where r.presenter == nil && now - r.lastActive > Self.roomTTLms {
            rooms[slug] = nil
        }
    }

    func reset() {
        for r in rooms.values { for m in r.matches.values { m.timer?.cancel(); m.timer = nil } }
        rooms = [:]
    }
}

extension ERJ: Equatable {
    static func == (a: ERJ, b: ERJ) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case let (.bool(x), .bool(y)): return x == y
        case let (.num(x), .num(y)): return x == y
        case let (.str(x), .str(y)): return x == y
        case let (.arr(x), .arr(y)): return x == y
        case let (.obj(x), .obj(y)): return x.keys == y.keys && x.keys.allSatisfy { x[$0]! == y[$0]! }
        default: return false
        }
    }
}
