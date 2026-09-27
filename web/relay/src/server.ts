// lalaai relay: rooms, transcript fan-out, Q&A, meet matching. In-memory, single process.
import type { ServerWebSocket } from "bun";
import { join, normalize } from "node:path";
import type {
  AttendeeToRelay,
  CreateRoomRequest,
  CreateRoomResponse,
  Icebreaker,
  IcebreakerJob,
  Lang,
  MatchView,
  MeetState,
  PresenterToRelay,
  Profile,
  QuestionFull,
  QuestionView,
  RelayToAttendee,
  RelayToPresenter,
  RoomInfo,
  SegmentView,
} from "../../shared/protocol";
import { fallbackIcebreakers } from "./icebreakers";
import { randomSlug } from "./names";

const PORT = Number(process.env.PORT ?? 8787);
const PUBLIC_URL = process.env.PUBLIC_URL?.replace(/\/$/, ""); // e.g. https://lalaai.example.com
const STATIC_DIR = normalize(process.env.STATIC_DIR ?? join(import.meta.dir, "../../pwa/dist"));
const ICEBREAKER_TIMEOUT_MS = 150_000; // agent CLIs can take a minute+ to read context and submit
const ROOM_TTL_MS = 12 * 60 * 60 * 1000;
const MAX_SEGMENTS = 300;

type WsData =
  | { role: "presenter"; slug: string }
  | { role: "attendee"; slug: string; uid: string };

interface Attendee {
  uid: string;
  secret: string;
  profile: Profile | null;
  sockets: Set<ServerWebSocket<WsData>>;
  lastAskAt: number;
}

interface Segment {
  id: number;
  final: boolean;
  source: string;
  texts: Record<Lang, string>;
  t: number;
}

interface Question {
  id: string;
  authorUid: string;
  original: string;
  originalLang: Lang;
  texts: Record<Lang, string>;
  likes: Set<string>;
  /** asked anonymously: author hidden from everyone except themselves (and matches, once accepted) */
  anonymous: boolean;
  answered: boolean;
  pinned: boolean;
  hidden: boolean;
  createdAt: number;
}

const ANON_AUTHOR = { uid: "", name: "", avatar: "anon", color: "#8a9bb8" };

interface Match {
  id: string;
  fromUid: string;
  toUid: string;
  questionId: string;
  status: "pending" | "accepted" | "declined";
  icebreakers: Record<Lang, Icebreaker[]>;
  source: MatchView["icebreakerSource"];
  createdAt: number;
  timer?: ReturnType<typeof setTimeout>;
}

interface Room {
  slug: string;
  title: string;
  presenterName: string;
  presenterLang: Lang;
  languages: Lang[];
  llmEnabled: boolean;
  presenterToken: string;
  presenter: ServerWebSocket<WsData> | null;
  attendees: Map<string, Attendee>;
  segments: Segment[];
  questions: Map<string, Question>;
  matches: Map<string, Match>;
  lastActive: number;
}

const rooms = new Map<string, Room>();

// ───────────────────────────── helpers ─────────────────────────────
const rid = (n = 12) => {
  const abc = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const bytes = crypto.getRandomValues(new Uint8Array(n));
  return Array.from(bytes, (b) => abc[b % abc.length]).join("");
};
/** Canonical BCP-47-ish code that keeps meaningful variants: "zh_tw" → "zh-TW", "pt-pt" → "pt-PT", "EN" → "en". */
const normLang = (l: string) => {
  const [lang, ...rest] = (l || "en").replace(/_/g, "-").split("-").filter(Boolean);
  const parts = [lang!.toLowerCase()];
  for (const p of rest) {
    if (/^[a-z]{4}$/i.test(p)) parts.push(p[0]!.toUpperCase() + p.slice(1).toLowerCase()); // script (Hant)
    else if (/^([a-z]{2}|\d{3})$/i.test(p)) parts.push(p.toUpperCase()); // region (TW)
  }
  return parts.join("-");
};
const SLUG_RE = /^[a-z0-9][a-z0-9-]{2,39}$/;
const clean = (s: unknown, max: number) => (typeof s === "string" ? s.trim().slice(0, max) : "");

function roomInfo(r: Room): RoomInfo {
  let count = 0;
  for (const a of r.attendees.values()) if (a.sockets.size && a.profile) count++;
  return {
    slug: r.slug,
    title: r.title,
    presenterName: r.presenterName,
    presenterLang: r.presenterLang,
    languages: r.languages,
    llmEnabled: r.llmEnabled,
    live: !!r.presenter,
    attendeeCount: count,
  };
}

function sendA(ws: ServerWebSocket<WsData>, msg: RelayToAttendee) {
  ws.send(JSON.stringify(msg));
}
function sendUid(r: Room, uid: string, msg: RelayToAttendee) {
  const a = r.attendees.get(uid);
  if (!a) return;
  const s = JSON.stringify(msg);
  for (const ws of a.sockets) ws.send(s);
}
function sendP(r: Room, msg: RelayToPresenter) {
  r.presenter?.send(JSON.stringify(msg));
}
function eachOnline(r: Room, fn: (a: Attendee) => void) {
  for (const a of r.attendees.values()) if (a.sockets.size) fn(a);
}

function langOf(r: Room, uid: string): Lang {
  return r.attendees.get(uid)?.profile?.lang ?? r.presenterLang;
}

function segmentView(r: Room, s: Segment, lang: Lang): SegmentView | null {
  let text = lang === r.presenterLang ? s.source : s.texts[lang];
  if (text === undefined) {
    if (!s.final) return null; // don't stream untranslated partials
    text = s.source;
  }
  return { id: s.id, final: s.final, text, source: s.source, t: s.t };
}

function publicAuthor(r: Room, uid: string) {
  const p = r.attendees.get(uid)?.profile;
  return { uid, name: p?.name ?? "", avatar: p?.avatar ?? "blob", color: p?.color ?? "#999999" };
}

function questionView(r: Room, q: Question, viewerUid: string): QuestionView {
  const lang = langOf(r, viewerUid);
  const tr = lang === q.originalLang ? undefined : q.texts[lang];
  return {
    id: q.id,
    author: q.anonymous && q.authorUid !== viewerUid ? ANON_AUTHOR : publicAuthor(r, q.authorUid),
    text: tr ?? q.original,
    original: q.original,
    originalLang: q.originalLang,
    translated: tr !== undefined,
    likes: q.likes.size,
    likedByMe: q.likes.has(viewerUid),
    mine: q.authorUid === viewerUid,
    anonymous: q.anonymous,
    answered: q.answered,
    pinned: q.pinned,
    createdAt: q.createdAt,
  };
}

function questionFull(r: Room, q: Question): QuestionFull {
  const p = r.attendees.get(q.authorUid)?.profile;
  return {
    id: q.id,
    author: { ...(q.anonymous ? ANON_AUTHOR : publicAuthor(r, q.authorUid)), lang: p?.lang ?? q.originalLang },
    original: q.original,
    originalLang: q.originalLang,
    texts: q.texts,
    likes: q.likes.size,
    anonymous: q.anonymous,
    answered: q.answered,
    pinned: q.pinned,
    hidden: q.hidden,
    createdAt: q.createdAt,
  };
}

function questionText(r: Room, q: Question | undefined, lang: Lang) {
  if (!q) return "";
  return lang === q.originalLang ? q.original : (q.texts[lang] ?? q.original);
}

function matchView(r: Room, m: Match, viewerUid: string): MatchView {
  const peerUid = m.fromUid === viewerUid ? m.toUid : m.fromUid;
  const lang = langOf(r, viewerUid);
  const peer = r.attendees.get(peerUid)?.profile ?? {
    uid: peerUid, name: "", avatar: "blob", color: "#999999", lang: r.presenterLang,
  };
  const { contact, spotMe, ...rest } = peer;
  const q = r.questions.get(m.questionId);
  const ib = m.icebreakers[lang] ?? m.icebreakers[r.presenterLang] ?? Object.values(m.icebreakers)[0] ?? [];
  const accepted = m.status === "accepted";
  // An anonymous asker stays hidden until the wave is accepted.
  const masked = !accepted && !!q?.anonymous && q.authorUid === peerUid;
  return {
    id: m.id,
    status: m.status,
    outgoing: m.fromUid === viewerUid,
    peer: masked
      ? { ...ANON_AUTHOR, uid: `anon-${m.id}`, lang: peer.lang }
      : accepted ? { ...rest, contact, spotMe } : { ...rest },
    peerMasked: masked,
    questionId: m.questionId,
    questionText: questionText(r, q, lang),
    icebreakers: m.status === "accepted" ? ib : [],
    icebreakerSource: m.status === "accepted" ? m.source : "none",
    createdAt: m.createdAt,
  };
}

function pairKey(a: string, b: string) {
  return a < b ? `${a}|${b}` : `${b}|${a}`;
}

function meetState(r: Room, uid: string): MeetState {
  const lang = langOf(r, uid);
  const matched = new Set<string>();
  const matches: MatchView[] = [];
  for (const m of r.matches.values()) {
    if (m.fromUid !== uid && m.toUid !== uid) continue;
    if (m.status !== "declined") matched.add(m.fromUid === uid ? m.toUid : m.fromUid);
    // declined requests are only shown to nobody (keeps it low-drama)
    if (m.status !== "declined") matches.push(matchView(r, m, uid));
  }
  const likers: MeetState["likers"] = [];
  for (const q of r.questions.values()) {
    if (q.authorUid !== uid || q.hidden || q.likes.size === 0) continue;
    const people: Profile[] = [];
    for (const l of q.likes) {
      if (l === uid || matched.has(l)) continue;
      const p = r.attendees.get(l)?.profile;
      if (p) {
        const { contact: _c, spotMe: _s, ...pub } = p;
        people.push(pub);
      }
    }
    if (people.length) likers.push({ questionId: q.id, questionText: questionText(r, q, lang), people });
  }
  matches.sort((a, b) => b.createdAt - a.createdAt);
  return { likers, matches };
}

function pushMeet(r: Room, uid: string) {
  sendUid(r, uid, { type: "meet.update", meet: meetState(r, uid) });
}

function broadcastRoom(r: Room) {
  const room = roomInfo(r);
  eachOnline(r, (a) => sendUid(r, a.uid, { type: "room.update", room }));
  sendP(r, { type: "room.update", room });
}

function pushStats(r: Room) {
  const byLang: Record<Lang, number> = {};
  let attendees = 0;
  eachOnline(r, (a) => {
    if (!a.profile) return;
    attendees++;
    byLang[a.profile.lang] = (byLang[a.profile.lang] ?? 0) + 1;
  });
  sendP(r, { type: "stats", attendees, byLang });
}

function broadcastQuestion(r: Room, q: Question) {
  if (q.hidden) {
    eachOnline(r, (a) => sendUid(r, a.uid, { type: "question.remove", id: q.id }));
  } else {
    eachOnline(r, (a) => sendUid(r, a.uid, { type: "question.upsert", question: questionView(r, q, a.uid) }));
  }
  sendP(r, { type: "question.state", question: questionFull(r, q) });
}

function welcomeAttendee(r: Room, ws: ServerWebSocket<WsData>, uid: string) {
  const a = r.attendees.get(uid)!;
  const lang = langOf(r, uid);
  const segments = r.segments
    .map((s) => segmentView(r, s, lang))
    .filter((s): s is SegmentView => !!s)
    .slice(-80);
  const questions = [...r.questions.values()].filter((q) => !q.hidden).map((q) => questionView(r, q, uid));
  sendA(ws, { type: "welcome", room: roomInfo(r), you: a.profile, segments, questions, meet: meetState(r, uid) });
}

// ───────────────────────────── icebreakers ─────────────────────────────
function jobFor(r: Room, m: Match): IcebreakerJob {
  const q = r.questions.get(m.questionId);
  const people = [m.fromUid, m.toUid].map((uid) => {
    const p = r.attendees.get(uid)?.profile;
    return { uid, name: p?.name || "Guest", lang: p?.lang ?? r.presenterLang, tagline: p?.tagline };
  });
  return {
    matchId: m.id,
    question: {
      id: m.questionId,
      text: q?.original ?? "",
      lang: q?.originalLang ?? r.presenterLang,
      presenterText: q ? questionText(r, q, r.presenterLang) : undefined,
    },
    people,
    langs: [...new Set(people.map((p) => p.lang))],
  };
}

function applyFallback(r: Room, m: Match) {
  const q = r.questions.get(m.questionId);
  const langs = new Set([langOf(r, m.fromUid), langOf(r, m.toUid)]);
  for (const l of langs) m.icebreakers[l] = fallbackIcebreakers(l, questionText(r, q, l), r.title);
  m.source = "fallback";
}

function startIcebreakers(r: Room, m: Match) {
  if (r.llmEnabled && r.presenter) {
    m.source = "pending";
    sendP(r, { type: "icebreakers.needed", job: jobFor(r, m) });
    m.timer = setTimeout(() => {
      if (m.source !== "pending") return;
      applyFallback(r, m);
      pushMeet(r, m.fromUid);
      pushMeet(r, m.toUid);
    }, ICEBREAKER_TIMEOUT_MS);
  } else {
    applyFallback(r, m);
  }
}

// ───────────────────────────── message handlers ─────────────────────────────
function onAttendee(r: Room, uid: string, ws: ServerWebSocket<WsData>, msg: AttendeeToRelay) {
  const a = r.attendees.get(uid)!;
  const toast = (kind: "info" | "error" | "match", message: string) => sendA(ws, { type: "toast", kind, message });

  switch (msg.type) {
    case "ping":
      return sendA(ws, { type: "pong" });

    case "profile.update": {
      const p = msg.profile ?? ({} as Profile);
      const lang = normLang(clean(p.lang, 16));
      const langChanged = a.profile?.lang !== lang;
      const wasNew = !a.profile;
      a.profile = {
        uid,
        name: clean(p.name, 32), // optional: attendees may stay nameless until they ask or meet
        avatar: clean(p.avatar, 24) || "blob",
        color: /^#[0-9a-fA-F]{6}$/.test(p.color ?? "") ? p.color : "#45c2f9",
        lang: r.languages.includes(lang) ? lang : r.presenterLang,
        contact: clean(p.contact, 120) || undefined,
        tagline: clean(p.tagline, 120) || undefined,
        spotMe: clean(p.spotMe, 80) || undefined,
      };
      // Re-localize everything for all of this user's sockets.
      for (const s of a.sockets) welcomeAttendee(r, s, uid);
      if (wasNew || langChanged) broadcastRoom(r);
      pushStats(r);
      // Name/avatar changes show on their questions & in others' meet lists.
      for (const q of r.questions.values()) if (q.authorUid === uid) broadcastQuestion(r, q);
      return;
    }

    case "question.ask": {
      if (!a.profile) return toast("error", "profile required");
      const text = clean(msg.text, 280);
      if (text.length < 3) return;
      const now = Date.now();
      if (now - a.lastAskAt < 8_000) return toast("error", "slow down");
      a.lastAskAt = now;
      const q: Question = {
        id: rid(10),
        authorUid: uid,
        original: text,
        originalLang: a.profile.lang,
        texts: { [a.profile.lang]: text },
        likes: new Set(),
        anonymous: !!msg.anonymous,
        answered: false,
        pinned: false,
        hidden: false,
        createdAt: now,
      };
      r.questions.set(q.id, q);
      eachOnline(r, (o) => sendUid(r, o.uid, { type: "question.upsert", question: questionView(r, q, o.uid) }));
      sendP(r, { type: "question.new", question: questionFull(r, q) });
      return;
    }

    case "question.like": {
      const q = r.questions.get(msg.id);
      if (!q || q.hidden || !a.profile) return;
      if (msg.like) q.likes.add(uid);
      else q.likes.delete(uid);
      broadcastQuestion(r, q);
      pushMeet(r, q.authorUid);
      return;
    }

    case "question.delete": {
      const q = r.questions.get(msg.id);
      if (!q || q.authorUid !== uid) return;
      r.questions.delete(q.id);
      eachOnline(r, (o) => sendUid(r, o.uid, { type: "question.remove", id: q.id }));
      sendP(r, { type: "question.remove", id: q.id });
      pushMeet(r, uid);
      return;
    }

    case "meet.request": {
      const q = r.questions.get(msg.questionId);
      const to = msg.toUid || q?.authorUid; // no toUid = wave at the (maybe anonymous) asker
      if (!q || !to || !a.profile || to === uid || !r.attendees.get(to)?.profile) return toast("error", "cannot meet");
      const linked =
        (q.authorUid === to && q.likes.has(uid)) || (q.authorUid === uid && q.likes.has(to));
      if (!linked) return toast("error", "you are not connected by this question");
      const key = pairKey(uid, to);
      const existing = [...r.matches.values()].find((m) => pairKey(m.fromUid, m.toUid) === key && m.status !== "declined");
      if (existing) {
        if (existing.status === "pending" && existing.toUid === uid) {
          // they already asked us -> instant match
          existing.status = "accepted";
          startIcebreakers(r, existing);
          notifyMatch(r, existing);
        }
        pushMeet(r, uid);
        return;
      }
      const m: Match = {
        id: rid(10),
        fromUid: uid,
        toUid: to,
        questionId: q.id,
        status: "pending",
        icebreakers: {},
        source: "none",
        createdAt: Date.now(),
      };
      r.matches.set(m.id, m);
      pushMeet(r, uid);
      pushMeet(r, to);
      const hideMe = q.anonymous && q.authorUid === uid;
      sendUid(r, to, { type: "toast", kind: "info", message: hideMe ? "👋" : `👋 ${a.profile.name || "?"}` });
      return;
    }

    case "meet.respond": {
      const m = r.matches.get(msg.matchId);
      if (!m || m.toUid !== uid || m.status !== "pending") return;
      m.status = msg.accept ? "accepted" : "declined";
      if (m.status === "accepted") {
        startIcebreakers(r, m);
        notifyMatch(r, m);
      }
      pushMeet(r, m.fromUid);
      pushMeet(r, m.toUid);
      return;
    }
  }
}

function notifyMatch(r: Room, m: Match) {
  for (const [me, other] of [[m.fromUid, m.toUid], [m.toUid, m.fromUid]] as const) {
    const name = r.attendees.get(other)?.profile?.name || "?";
    sendUid(r, me, { type: "toast", kind: "match", message: `🎉 ${name}` });
    pushMeet(r, me);
  }
}

function onPresenter(r: Room, msg: PresenterToRelay) {
  switch (msg.type) {
    case "ping":
      return sendP(r, { type: "pong" });

    case "segment": {
      const seg: Segment = {
        id: Math.trunc(Number(msg.id)) || 0,
        final: !!msg.final,
        source: clean(msg.source, 4000),
        texts: msg.texts ?? {},
        t: Date.now(),
      };
      const last = r.segments[r.segments.length - 1];
      if (last && last.id === seg.id) r.segments[r.segments.length - 1] = seg;
      else r.segments.push(seg);
      if (r.segments.length > MAX_SEGMENTS) r.segments.splice(0, r.segments.length - MAX_SEGMENTS);
      const cache = new Map<Lang, string | null>();
      eachOnline(r, (a) => {
        const lang = langOf(r, a.uid);
        if (!cache.has(lang)) {
          const v = segmentView(r, seg, lang);
          cache.set(lang, v ? JSON.stringify({ type: "segment", segment: v } satisfies RelayToAttendee) : null);
        }
        const s = cache.get(lang);
        if (s) for (const ws of a.sockets) ws.send(s);
      });
      return;
    }

    case "question.translations": {
      const q = r.questions.get(msg.id);
      if (!q) return;
      for (const [l, t] of Object.entries(msg.texts ?? {})) if (typeof t === "string" && t.trim()) q.texts[normLang(l)] = t.trim().slice(0, 600);
      broadcastQuestion(r, q);
      // translated question text shows up in meet lists / match cards
      pushMeet(r, q.authorUid);
      for (const m of r.matches.values()) if (m.questionId === q.id) { pushMeet(r, m.fromUid); pushMeet(r, m.toUid); }
      return;
    }

    case "question.moderate": {
      const q = r.questions.get(msg.id);
      if (!q) return;
      if (msg.answered !== undefined) q.answered = msg.answered;
      if (msg.hidden !== undefined) q.hidden = msg.hidden;
      if (msg.pinned !== undefined) {
        // only one question on screen at a time
        if (msg.pinned) for (const o of r.questions.values()) if (o.pinned && o.id !== q.id) { o.pinned = false; broadcastQuestion(r, o); }
        q.pinned = msg.pinned;
      }
      broadcastQuestion(r, q);
      return;
    }

    case "icebreakers.result": {
      const m = r.matches.get(msg.matchId);
      if (!m || m.source !== "pending") return;
      clearTimeout(m.timer);
      const got: Record<Lang, Icebreaker[]> = {};
      for (const [l, list] of Object.entries(msg.icebreakers ?? {})) {
        if (!Array.isArray(list)) continue;
        const ok = list
          .filter((i) => i && typeof i.prompt === "string")
          .slice(0, 5)
          .map((i) => ({ topic: clean(i.topic, 60), prompt: clean(i.prompt, 300) }));
        if (ok.length) got[normLang(l)] = ok;
      }
      if (msg.error || !Object.keys(got).length) applyFallback(r, m);
      else {
        m.icebreakers = got;
        m.source = "llm";
      }
      pushMeet(r, m.fromUid);
      pushMeet(r, m.toUid);
      return;
    }

    case "room.config": {
      if (msg.title !== undefined) r.title = clean(msg.title, 80) || r.title;
      if (msg.presenterName !== undefined) r.presenterName = clean(msg.presenterName, 60);
      if (msg.presenterLang) r.presenterLang = normLang(msg.presenterLang);
      if (msg.languages) r.languages = normalizeLangs(msg.languages, r.presenterLang);
      if (msg.llmEnabled !== undefined) r.llmEnabled = !!msg.llmEnabled;
      broadcastRoom(r);
      return;
    }
  }
}

function normalizeLangs(langs: Lang[], presenterLang: Lang) {
  return [...new Set([presenterLang, ...(langs ?? []).map(normLang)])].slice(0, 48);
}

// ───────────────────────────── HTTP ─────────────────────────────
function publicBase(req: Request) {
  if (PUBLIC_URL) return PUBLIC_URL;
  const url = new URL(req.url);
  const proto = req.headers.get("x-forwarded-proto") ?? url.protocol.replace(":", "");
  const host = req.headers.get("x-forwarded-host") ?? req.headers.get("host") ?? url.host;
  return `${proto}://${host}`;
}

const cors = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET,POST,OPTIONS",
  "access-control-allow-headers": "content-type",
};
const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json", ...cors } });

async function createRoom(req: Request) {
  let body: CreateRoomRequest;
  try {
    body = (await req.json()) as CreateRoomRequest;
  } catch {
    return json({ error: "bad json" }, 400);
  }
  const slug = clean(body.slug, 40).toLowerCase();
  if (!SLUG_RE.test(slug)) return json({ error: "slug must be 3-40 chars: a-z 0-9 -" }, 400);
  const presenterLang = normLang(clean(body.presenterLang, 16) || "en");
  let r = rooms.get(slug);
  if (r) {
    if (!body.presenterToken || body.presenterToken !== r.presenterToken) return json({ error: "meetup name taken" }, 409);
    r.title = clean(body.title, 80) || r.title;
    r.presenterName = clean(body.presenterName, 60);
    r.presenterLang = presenterLang;
    r.languages = normalizeLangs(body.languages, presenterLang);
    r.llmEnabled = !!body.llmEnabled;
    broadcastRoom(r);
  } else {
    r = {
      slug,
      title: clean(body.title, 80) || slug,
      presenterName: clean(body.presenterName, 60),
      presenterLang,
      languages: normalizeLangs(body.languages, presenterLang),
      llmEnabled: !!body.llmEnabled,
      presenterToken: body.presenterToken && body.presenterToken.length >= 16 ? body.presenterToken : rid(32),
      presenter: null,
      attendees: new Map(),
      segments: [],
      questions: new Map(),
      matches: new Map(),
      lastActive: Date.now(),
    };
    rooms.set(slug, r);
  }
  const res: CreateRoomResponse = {
    room: roomInfo(r),
    presenterToken: r.presenterToken,
    joinUrl: `${publicBase(req)}/m/${slug}`,
  };
  return json(res);
}

async function serveStatic(pathname: string) {
  const rel = normalize(decodeURIComponent(pathname)).replace(/^(\.\.[/\\])+/, "");
  const path = join(STATIC_DIR, rel);
  if (path.startsWith(STATIC_DIR) && !rel.endsWith("/")) {
    const f = Bun.file(path);
    if (await f.exists()) {
      const immutable = rel.startsWith("/assets/");
      return new Response(f, { headers: { "cache-control": immutable ? "public, max-age=31536000, immutable" : "no-cache" } });
    }
  }
  const index = Bun.file(join(STATIC_DIR, "index.html"));
  if (await index.exists()) return new Response(index, { headers: { "content-type": "text/html", "cache-control": "no-cache" } });
  return new Response("lalaai relay is running. PWA not built (pnpm -C pwa build).", { status: 200 });
}

// ───────────────────────────── server ─────────────────────────────
const server = Bun.serve<WsData>({
  port: PORT,
  hostname: process.env.HOST ?? "0.0.0.0",
  async fetch(req, srv) {
    const url = new URL(req.url);
    const p = url.pathname;
    if (req.method === "OPTIONS") return new Response(null, { headers: cors });

    if (p === "/ws") {
      const slug = (url.searchParams.get("room") ?? "").toLowerCase();
      const r = rooms.get(slug);
      if (!r) return new Response("no such room", { status: 404 });
      const role = url.searchParams.get("role");
      if (role === "presenter") {
        if (url.searchParams.get("token") !== r.presenterToken) return new Response("bad token", { status: 403 });
        if (srv.upgrade(req, { data: { role: "presenter", slug } })) return;
      } else {
        const uid = url.searchParams.get("uid") ?? "";
        const secret = url.searchParams.get("secret") ?? "";
        if (!/^[A-Za-z0-9_-]{8,64}$/.test(uid) || secret.length < 16) return new Response("bad identity", { status: 400 });
        const a = r.attendees.get(uid);
        if (a && a.secret !== secret) return new Response("identity mismatch", { status: 403 });
        if (!a) r.attendees.set(uid, { uid, secret, profile: null, sockets: new Set(), lastAskAt: 0 });
        if (srv.upgrade(req, { data: { role: "attendee", slug, uid } })) return;
      }
      return new Response("upgrade failed", { status: 400 });
    }

    if (p === "/api/health") return json({ ok: true, rooms: rooms.size });
    if (p === "/api/names/random") {
      let slug = randomSlug();
      while (rooms.has(slug)) slug = randomSlug();
      return json({ slug });
    }
    if (p === "/api/rooms" && req.method === "POST") return createRoom(req);
    const m = p.match(/^\/api\/rooms\/([a-z0-9-]+)$/);
    if (m) {
      const r = rooms.get(m[1]!);
      return r ? json(roomInfo(r)) : json({ error: "not found" }, 404);
    }
    if (p.startsWith("/api/")) return json({ error: "not found" }, 404);
    return serveStatic(p);
  },
  websocket: {
    idleTimeout: 120,
    open(ws) {
      const r = rooms.get(ws.data.slug);
      if (!r) return ws.close();
      r.lastActive = Date.now();
      if (ws.data.role === "presenter") {
        if (r.presenter && r.presenter !== ws) r.presenter.close(4000, "replaced");
        r.presenter = ws;
        const pendingJobs = [...r.matches.values()].filter((m) => m.source === "pending").map((m) => jobFor(r, m));
        const questions = [...r.questions.values()].map((q) => questionFull(r, q));
        ws.send(JSON.stringify({ type: "presenter.welcome", room: roomInfo(r), questions, pendingJobs } satisfies RelayToPresenter));
        broadcastRoom(r);
        pushStats(r);
      } else {
        const a = r.attendees.get(ws.data.uid)!;
        a.sockets.add(ws);
        welcomeAttendee(r, ws, a.uid);
        if (a.profile && a.sockets.size === 1) {
          broadcastRoom(r);
          pushStats(r);
        }
      }
    },
    message(ws, raw) {
      const r = rooms.get(ws.data.slug);
      if (!r) return;
      r.lastActive = Date.now();
      let msg: any;
      try {
        msg = JSON.parse(typeof raw === "string" ? raw : new TextDecoder().decode(raw));
      } catch {
        return;
      }
      if (!msg || typeof msg.type !== "string") return;
      try {
        if (ws.data.role === "presenter") {
          if (r.presenter === ws) onPresenter(r, msg);
        } else onAttendee(r, ws.data.uid, ws, msg);
      } catch (e) {
        console.error("handler error", e);
      }
    },
    close(ws) {
      const r = rooms.get(ws.data.slug);
      if (!r) return;
      if (ws.data.role === "presenter") {
        if (r.presenter === ws) {
          r.presenter = null;
          broadcastRoom(r);
        }
      } else {
        const a = r.attendees.get(ws.data.uid);
        a?.sockets.delete(ws);
        if (a?.profile && a.sockets.size === 0) {
          broadcastRoom(r);
          pushStats(r);
        }
      }
    },
  },
});

setInterval(() => {
  const now = Date.now();
  for (const [slug, r] of rooms) {
    if (!r.presenter && now - r.lastActive > ROOM_TTL_MS) rooms.delete(slug);
  }
}, 10 * 60 * 1000);

console.log(`lalaai relay on http://${server.hostname}:${server.port}  static=${STATIC_DIR}`);
