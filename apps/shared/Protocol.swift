import Foundation

// Mirrors shared/protocol.ts (presenter side only).

struct RoomInfo: Codable, Equatable {
    var slug: String
    var title: String
    var presenterName: String
    var presenterLang: String
    var languages: [String]
    var llmEnabled: Bool
    var live: Bool
    var attendeeCount: Int
}

struct CreateRoomRequest: Codable {
    var slug: String
    var title: String
    var presenterName: String
    var presenterLang: String
    var languages: [String]
    var llmEnabled: Bool
    var presenterToken: String?
}

struct CreateRoomResponse: Codable {
    var room: RoomInfo
    var presenterToken: String
    var joinUrl: String
}

struct Author: Codable, Equatable, Hashable {
    var uid: String
    var name: String
    var avatar: String
    var color: String
    var lang: String?
    /// Attendees can stay nameless until they ask or meet.
    var displayName: String { name.trimmingCharacters(in: .whitespaces).isEmpty ? "Guest" : name }
}

struct QuestionFull: Codable, Identifiable, Equatable {
    var id: String
    var author: Author
    var original: String
    var originalLang: String
    var texts: [String: String]
    var likes: Int
    var anonymous: Bool?
    var answered: Bool
    var pinned: Bool
    var hidden: Bool
    var createdAt: Double

    func text(in lang: String) -> String { originalLang == lang ? original : (texts[lang] ?? original) }
    /// Who to show as the author (anonymous askers stay anonymous, even to the presenter).
    var authorLabel: String { anonymous == true ? "Anonymous" : author.displayName }
}

struct Icebreaker: Codable, Equatable {
    var topic: String
    var prompt: String
}

struct IcebreakerJob: Codable, Identifiable, Equatable {
    struct Q: Codable, Equatable { var id: String; var text: String; var lang: String; var presenterText: String? }
    struct Person: Codable, Equatable { var uid: String; var name: String; var lang: String; var tagline: String? }
    var matchId: String
    var question: Q
    var people: [Person]
    var langs: [String]
    var id: String { matchId }
}

/// Incoming frames (relay → presenter).
enum RelayMessage {
    case welcome(room: RoomInfo, questions: [QuestionFull], pendingJobs: [IcebreakerJob])
    case roomUpdate(RoomInfo)
    case questionNew(QuestionFull)
    case questionState(QuestionFull)
    case questionRemove(String)
    case icebreakersNeeded(IcebreakerJob)
    case stats(attendees: Int, byLang: [String: Int])
    case error(String)
    case other

    private struct Envelope: Decodable { var type: String }
    private struct Welcome: Decodable { var room: RoomInfo; var questions: [QuestionFull]; var pendingJobs: [IcebreakerJob] }
    private struct RoomW: Decodable { var room: RoomInfo }
    private struct QW: Decodable { var question: QuestionFull }
    private struct IdW: Decodable { var id: String }
    private struct JobW: Decodable { var job: IcebreakerJob }
    private struct StatsW: Decodable { var attendees: Int; var byLang: [String: Int] }
    private struct ErrW: Decodable { var message: String }

    static func decode(_ data: Data) throws -> RelayMessage {
        let d = JSONDecoder()
        let type = try d.decode(Envelope.self, from: data).type
        switch type {
        case "presenter.welcome":
            let w = try d.decode(Welcome.self, from: data)
            return .welcome(room: w.room, questions: w.questions, pendingJobs: w.pendingJobs)
        case "room.update": return .roomUpdate(try d.decode(RoomW.self, from: data).room)
        case "question.new": return .questionNew(try d.decode(QW.self, from: data).question)
        case "question.state": return .questionState(try d.decode(QW.self, from: data).question)
        case "question.remove": return .questionRemove(try d.decode(IdW.self, from: data).id)
        case "icebreakers.needed": return .icebreakersNeeded(try d.decode(JobW.self, from: data).job)
        case "stats":
            let s = try d.decode(StatsW.self, from: data)
            return .stats(attendees: s.attendees, byLang: s.byLang)
        case "error": return .error(try d.decode(ErrW.self, from: data).message)
        default: return .other
        }
    }
}

/// Outgoing frames (presenter → relay).
enum PresenterMessage: Encodable {
    case segment(id: Int, final: Bool, source: String, texts: [String: String])
    case questionTranslations(id: String, texts: [String: String])
    case questionModerate(id: String, answered: Bool? = nil, pinned: Bool? = nil, hidden: Bool? = nil)
    case icebreakersResult(matchId: String, icebreakers: [String: [Icebreaker]], error: String?)
    case roomConfig(title: String?, presenterName: String?, presenterLang: String?, languages: [String]?, llmEnabled: Bool?)
    case ping

    private enum K: String, CodingKey {
        case type, id, final, source, texts, answered, pinned, hidden, matchId, icebreakers, error
        case title, presenterName, presenterLang, languages, llmEnabled
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case let .segment(id, final, source, texts):
            try c.encode("segment", forKey: .type)
            try c.encode(id, forKey: .id); try c.encode(final, forKey: .final)
            try c.encode(source, forKey: .source); try c.encode(texts, forKey: .texts)
        case let .questionTranslations(id, texts):
            try c.encode("question.translations", forKey: .type)
            try c.encode(id, forKey: .id); try c.encode(texts, forKey: .texts)
        case let .questionModerate(id, answered, pinned, hidden):
            try c.encode("question.moderate", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(answered, forKey: .answered)
            try c.encodeIfPresent(pinned, forKey: .pinned)
            try c.encodeIfPresent(hidden, forKey: .hidden)
        case let .icebreakersResult(matchId, icebreakers, error):
            try c.encode("icebreakers.result", forKey: .type)
            try c.encode(matchId, forKey: .matchId); try c.encode(icebreakers, forKey: .icebreakers)
            try c.encodeIfPresent(error, forKey: .error)
        case let .roomConfig(title, presenterName, presenterLang, languages, llmEnabled):
            try c.encode("room.config", forKey: .type)
            try c.encodeIfPresent(title, forKey: .title)
            try c.encodeIfPresent(presenterName, forKey: .presenterName)
            try c.encodeIfPresent(presenterLang, forKey: .presenterLang)
            try c.encodeIfPresent(languages, forKey: .languages)
            try c.encodeIfPresent(llmEnabled, forKey: .llmEnabled)
        case .ping:
            try c.encode("ping", forKey: .type)
        }
    }
}
