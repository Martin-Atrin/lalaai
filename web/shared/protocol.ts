// lalaai wire protocol — single source of truth shared by relay + PWA.
// The Swift desktop app mirrors these shapes in desktop/Sources/lalaai/Relay/Protocol.swift.
//
// Transport: JSON text frames over WebSocket at `/ws`.
//   presenter: /ws?room=<slug>&role=presenter&token=<presenterToken>
//   attendee:  /ws?room=<slug>&role=attendee&uid=<uid>&secret=<secret>
// Every frame is `{ "type": string, ...payload }`.
//
// HTTP:
//   GET  /api/health                      -> { ok: true }
//   GET  /api/names/random                -> { slug }
//   GET  /api/rooms/:slug                 -> RoomInfo | 404
//   POST /api/rooms  CreateRoomRequest    -> CreateRoomResponse | 409 (slug taken, token mismatch)
//   GET  /m/:slug                          -> PWA (attendee entry, what the QR encodes)

export type Lang = string; // BCP-47 language code, lowercase base: "en", "de", "cs", "ja", "zh", "es"...

export interface RoomInfo {
  slug: string;
  title: string;
  presenterName: string;
  presenterLang: Lang;
  languages: Lang[]; // languages attendees may pick (always includes presenterLang)
  llmEnabled: boolean; // presenter connected an LLM -> AI icebreakers unlocked
  live: boolean; // presenter socket currently connected
  attendeeCount: number;
}

export interface CreateRoomRequest {
  slug: string;
  title: string;
  presenterName: string;
  presenterLang: Lang;
  languages: Lang[];
  llmEnabled: boolean;
  /** Re-claim an existing room you own (desktop restart). */
  presenterToken?: string;
}
export interface CreateRoomResponse {
  room: RoomInfo;
  presenterToken: string;
  joinUrl: string; // absolute URL encoded in the QR code
}

/** Public identity of an attendee. `uid` is stable per device (localStorage). */
export interface Profile {
  uid: string;
  name: string; // display name, 1..32 chars
  avatar: string; // character id, e.g. "fox" | "owl" | ... (PWA renders the art)
  color: string; // hex accent, e.g. "#ff7a59"
  lang: Lang;
  /** Optional way to find you after the talk (LinkedIn/Telegram/email) — shared only with matches. */
  contact?: string;
  /** One-liner about you ("backend dev @ Acme, into climbing"). */
  tagline?: string;
  /** How to recognise you in the room ("red hat with stripes"). Shared only with accepted matches. */
  spotMe?: string;
}

/** A question as seen by one attendee (text already localized to their language). */
export interface QuestionView {
  id: string;
  author: Pick<Profile, "uid" | "name" | "avatar" | "color">;
  text: string; // in viewer language (falls back to original until translated)
  original: string;
  originalLang: Lang;
  translated: boolean; // text is a real translation into viewer lang
  likes: number;
  likedByMe: boolean;
  mine: boolean;
  /** Asked anonymously: `author` is masked for everyone but the asker (uid ""). */
  anonymous?: boolean;
  answered: boolean;
  pinned: boolean; // presenter put it on screen
  createdAt: number; // epoch ms
}

/** Transcript segment localized to the viewer's language. */
export interface SegmentView {
  id: number; // monotonically increasing per room; partials reuse the id until final
  final: boolean;
  text: string;
  source: string; // presenter-language text (for "show original" toggle)
  t: number; // epoch ms
}

export interface Icebreaker {
  topic: string; // 2-5 words, e.g. "Scaling Postgres"
  prompt: string; // an actual opener question
}

export type MatchStatus = "pending" | "accepted" | "declined";

export interface MatchView {
  id: string;
  status: MatchStatus;
  /** true when the viewer sent the request */
  outgoing: boolean;
  /** the other person; `contact` and `spotMe` present only once accepted */
  peer: Profile;
  /** Peer is the anonymous asker of the linking question: identity hidden until accepted. */
  peerMasked?: boolean;
  /** the question that connected you */
  questionId: string;
  questionText: string; // localized to viewer
  icebreakers: Icebreaker[];
  icebreakerSource: "llm" | "fallback" | "pending" | "none";
  createdAt: number;
}

export interface MeetState {
  /** people who liked *my* questions, keyed by questionId */
  likers: { questionId: string; questionText: string; people: Profile[] }[];
  matches: MatchView[];
}

// ─────────────────────────── attendee → relay ───────────────────────────
export type AttendeeToRelay =
  | { type: "profile.update"; profile: Omit<Profile, "uid"> }
  | { type: "question.ask"; text: string; anonymous?: boolean }
  | { type: "question.like"; id: string; like: boolean }
  | { type: "question.delete"; id: string }
  /** Ask to meet someone. Allowed when one of you liked the other's question.
   *  Omit `toUid` to wave at the (possibly anonymous) author of `questionId`. */
  | { type: "meet.request"; toUid?: string; questionId: string }
  | { type: "meet.respond"; matchId: string; accept: boolean }
  | { type: "ping" };

// ─────────────────────────── relay → attendee ───────────────────────────
export type RelayToAttendee =
  | {
      type: "welcome";
      room: RoomInfo;
      you: Profile | null; // null => onboarding required (send profile.update)
      segments: SegmentView[]; // recent history, in your lang
      questions: QuestionView[];
      meet: MeetState;
    }
  | { type: "room.update"; room: RoomInfo }
  | { type: "segment"; segment: SegmentView }
  | { type: "question.upsert"; question: QuestionView }
  | { type: "question.remove"; id: string }
  | { type: "meet.update"; meet: MeetState }
  | { type: "toast"; kind: "info" | "match" | "error"; message: string }
  | { type: "error"; message: string }
  | { type: "pong" };

// ─────────────────────────── presenter → relay ──────────────────────────
export type PresenterToRelay =
  | {
      type: "segment";
      id: number;
      final: boolean;
      source: string; // presenter-language text
      texts: Record<Lang, string>; // translations (may be partial/missing for partial segments)
    }
  | { type: "question.translations"; id: string; texts: Record<Lang, string> }
  | { type: "question.moderate"; id: string; answered?: boolean; pinned?: boolean; hidden?: boolean }
  /** icebreakers keyed by language; relay delivers each person their own language (falls back to any). */
  | { type: "icebreakers.result"; matchId: string; icebreakers: Record<Lang, Icebreaker[]>; error?: string }
  | {
      type: "room.config";
      title?: string;
      presenterName?: string;
      presenterLang?: Lang;
      languages?: Lang[];
      llmEnabled?: boolean;
    }
  | { type: "ping" };

/** Full question record the presenter sees (all translations). */
export interface QuestionFull {
  id: string;
  author: Pick<Profile, "uid" | "name" | "avatar" | "color" | "lang">;
  original: string;
  originalLang: Lang;
  texts: Record<Lang, string>;
  likes: number;
  /** author is masked (uid/name "") */
  anonymous?: boolean;
  answered: boolean;
  pinned: boolean;
  hidden: boolean;
  createdAt: number;
}

export interface IcebreakerJob {
  matchId: string;
  question: { id: string; text: string; lang: Lang; presenterText?: string };
  people: Pick<Profile, "uid" | "name" | "lang" | "tagline">[]; // exactly 2
  /** languages to write icebreakers in (each person's lang; relay sends per-person) */
  langs: Lang[];
}

// ─────────────────────────── relay → presenter ──────────────────────────
export type RelayToPresenter =
  | { type: "presenter.welcome"; room: RoomInfo; questions: QuestionFull[]; pendingJobs: IcebreakerJob[] }
  | { type: "room.update"; room: RoomInfo }
  /** New question needing translation into all room languages. */
  | { type: "question.new"; question: QuestionFull }
  /** Any change (likes, moderation, translations). */
  | { type: "question.state"; question: QuestionFull }
  | { type: "question.remove"; id: string }
  /** Two attendees matched; generate icebreakers (only sent when llmEnabled). */
  | { type: "icebreakers.needed"; job: IcebreakerJob }
  | { type: "stats"; attendees: number; byLang: Record<Lang, number> }
  | { type: "error"; message: string }
  | { type: "pong" };
