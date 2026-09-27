import { computed, effect, signal } from "@preact/signals";
import type {
  AttendeeToRelay,
  MeetState,
  Profile,
  QuestionView,
  RelayToAttendee,
  RoomInfo,
  SegmentView,
} from "@shared/protocol";
import { getIdentity, storageGet, storageSet } from "./identity";
import { setUiLang } from "./i18n";
import type { ConnStatus, Link } from "./net";

// ───────────────────────────── preferences ─────────────────────────────
export type DisplayMode = "flow" | "captions";
export type FontSize = "s" | "m" | "l" | "xl";
export type Theme = "auto" | "light" | "dark" | "contrast";
export interface Prefs {
  mode: DisplayMode;
  fontSize: FontSize;
  showOriginal: boolean;
  theme: Theme;
}
const DEFAULT_PREFS: Prefs = { mode: "flow", fontSize: "m", showOriginal: false, theme: "auto" };

function loadPrefs(): Prefs {
  try {
    const raw = storageGet("lalaai.prefs");
    if (raw) return { ...DEFAULT_PREFS, ...(JSON.parse(raw) as Partial<Prefs>) };
  } catch {
    /* ignore */
  }
  return { ...DEFAULT_PREFS };
}

export const prefs = signal<Prefs>(loadPrefs());
export function setPref<K extends keyof Prefs>(k: K, v: Prefs[K]) {
  prefs.value = { ...prefs.value, [k]: v };
}
effect(() => {
  const p = prefs.value;
  storageSet("lalaai.prefs", JSON.stringify(p));
  const root = document.documentElement;
  if (p.theme === "auto") delete root.dataset.theme;
  else root.dataset.theme = p.theme;
  root.dataset.font = p.fontSize;
});

// ───────────────────────────── room state ─────────────────────────────
export const room = signal<RoomInfo | null>(null);
export const you = signal<Profile | null>(null);
export const welcomed = signal(false);
export const segments = signal<SegmentView[]>([]);
export const questions = signal<QuestionView[]>([]);
export const meet = signal<MeetState>({ likers: [], matches: [] });
export const conn = signal<ConnStatus>("connecting");

// ───────────────────────────── UI state ─────────────────────────────
export type Tab = "live" | "qa" | "meet";
export const tab = signal<Tab>("live");
export const settingsOpen = signal(false);
export const editingProfile = signal(false);
/** `${toUid}:${questionId}` for requests we sent but haven't seen reflected in meet.matches yet. */
export const requestedLocal = signal<Set<string>>(new Set());

/** Name prompt shown lazily: on first question (skippable) or before a Meet action (required). */
export interface NameGate {
  reason: "ask" | "meet";
  /** `anonymous` is true when the user chose "ask anonymously" instead of giving a name. */
  run: (anonymous: boolean) => void;
}
export const nameGate = signal<NameGate | null>(null);
/** The user chose "ask anonymously" this session — later nameless questions stay anonymous without asking again. */
let skippedNameForAsk = false;

export const showOnboarding = computed(
  () => welcomed.value && (you.value === null || editingProfile.value || nameGate.value !== null),
);

/** Runs `run` once the user has a name (or, for questions, chose to stay anonymous). */
function withName(reason: NameGate["reason"], run: (anonymous: boolean) => void) {
  const hasName = !!you.value?.name?.trim();
  if (hasName) return run(false);
  if (reason === "ask" && skippedNameForAsk) return run(true);
  nameGate.value = { reason, run };
}

export function completeNameGate(skipped: boolean) {
  const g = nameGate.value;
  nameGate.value = null;
  if (!g) return;
  if (skipped && g.reason === "ask") skippedNameForAsk = true;
  if (!skipped || g.reason === "ask") g.run(skipped);
}
export const pendingIncoming = computed(() =>
  meet.value.matches.filter((m) => m.status === "pending" && !m.outgoing),
);

// UI language follows the chosen transcript language (or the room's until chosen).
effect(() => {
  const l = you.value?.lang;
  if (l) setUiLang(l);
});

// ───────────────────────────── toasts ─────────────────────────────
export interface Toast {
  id: number;
  kind: "info" | "match" | "error";
  message: string;
}
export const toasts = signal<Toast[]>([]);
let toastSeq = 0;
export function pushToast(kind: Toast["kind"], message: string) {
  const id = ++toastSeq;
  toasts.value = [...toasts.value.slice(-2), { id, kind, message }];
  if (kind === "match") {
    try {
      navigator.vibrate?.([40, 60, 40, 60, 120]);
    } catch {
      /* ignore */
    }
  }
  setTimeout(() => dismissToast(id), kind === "match" ? 6000 : 3800);
}
export function dismissToast(id: number) {
  toasts.value = toasts.value.filter((t) => t.id !== id);
}

// ───────────────────────────── link ─────────────────────────────
let link: Link | null = null;
export function setLink(l: Link | null) {
  link?.close();
  link = l;
}
export function send(msg: AttendeeToRelay) {
  link?.send(msg);
}

// ───────────────────────────── reducers ─────────────────────────────
const MAX_SEGMENTS = 400;

function upsertSegment(list: SegmentView[], seg: SegmentView): SegmentView[] {
  const stop = Math.max(0, list.length - 60);
  for (let i = list.length - 1; i >= stop; i--) {
    if (list[i].id === seg.id) {
      const next = list.slice();
      next[i] = seg;
      return next;
    }
    if (list[i].id < seg.id) break;
  }
  let next: SegmentView[];
  if (!list.length || list[list.length - 1].id < seg.id) next = [...list, seg];
  else {
    let i = list.length;
    while (i > 0 && list[i - 1].id > seg.id) i--;
    next = [...list.slice(0, i), seg, ...list.slice(i)];
  }
  return next.length > MAX_SEGMENTS ? next.slice(-MAX_SEGMENTS) : next;
}

export function handleMessage(msg: RelayToAttendee) {
  switch (msg.type) {
    case "welcome": {
      // A second welcome (e.g. after a language change) fully replaces state.
      room.value = msg.room;
      you.value = msg.you;
      segments.value = [...msg.segments].sort((a, b) => a.id - b.id).slice(-MAX_SEGMENTS);
      questions.value = msg.questions;
      meet.value = msg.meet;
      welcomed.value = true;
      if (msg.you) editingProfile.value = false;
      else setUiLang(msg.room.presenterLang);
      pruneRequested();
      break;
    }
    case "room.update":
      room.value = msg.room;
      break;
    case "segment":
      segments.value = upsertSegment(segments.value, msg.segment);
      break;
    case "question.upsert": {
      const q = msg.question;
      const list = questions.value;
      const i = list.findIndex((x) => x.id === q.id);
      if (i === -1) questions.value = [...list, q];
      else {
        const next = list.slice();
        next[i] = q;
        questions.value = next;
      }
      break;
    }
    case "question.remove":
      questions.value = questions.value.filter((q) => q.id !== msg.id);
      break;
    case "meet.update":
      meet.value = msg.meet;
      pruneRequested();
      break;
    case "toast":
      pushToast(msg.kind, msg.message);
      break;
    case "error":
      pushToast("error", msg.message);
      break;
    case "pong":
      break;
  }
}

function pruneRequested() {
  if (!requestedLocal.value.size) return;
  const known = new Set(meet.value.matches.map((m) => m.peer.uid));
  const viaQuestion = new Set(meet.value.matches.map((m) => m.questionId));
  const next = new Set(
    [...requestedLocal.value].filter((k) => {
      const [u, q] = k.split(":");
      return !(known.has(u!) || (u === "?" && viaQuestion.has(q!)));
    }),
  );
  if (next.size !== requestedLocal.value.size) requestedLocal.value = next;
}

// ───────────────────────────── actions ─────────────────────────────
export function updateProfile(p: Omit<Profile, "uid">) {
  const clean: Omit<Profile, "uid"> = {
    name: p.name.trim().slice(0, 32),
    avatar: p.avatar,
    color: p.color,
    lang: p.lang,
  };
  if (p.tagline?.trim()) clean.tagline = p.tagline.trim().slice(0, 80);
  if (p.contact?.trim()) clean.contact = p.contact.trim().slice(0, 120);
  if (p.spotMe?.trim()) clean.spotMe = p.spotMe.trim().slice(0, 80);
  send({ type: "profile.update", profile: clean });
  // Optimistic: the relay may or may not echo a fresh welcome.
  you.value = { uid: getIdentity().uid, ...clean };
  editingProfile.value = false;
}

export function changeLang(lang: string) {
  const me = you.value;
  if (!me || me.lang === lang) return;
  const { uid: _uid, ...rest } = me;
  updateProfile({ ...rest, lang });
}

export function toggleLike(q: QuestionView) {
  const like = !q.likedByMe;
  questions.value = questions.value.map((x) =>
    x.id === q.id ? { ...x, likedByMe: like, likes: Math.max(0, x.likes + (like ? 1 : -1)) } : x,
  );
  send({ type: "question.like", id: q.id, like });
}

export function askQuestion(text: string, anonymous = false) {
  const s = text.trim().slice(0, 280);
  if (!s) return;
  // Explicitly anonymous questions need no name at all.
  if (anonymous) return send({ type: "question.ask", text: s, anonymous: true });
  withName("ask", (anon) => send({ type: "question.ask", text: s, anonymous: anon || undefined }));
}

export function deleteQuestion(id: string) {
  questions.value = questions.value.filter((q) => q.id !== id);
  send({ type: "question.delete", id });
}

/** `toUid` undefined = wave at the author of `questionId` (works for anonymous askers). */
export function requestMeet(toUid: string | undefined, questionId: string) {
  withName("meet", () => {
    requestedLocal.value = new Set([...requestedLocal.value, `${toUid ?? "?"}:${questionId}`]);
    send(toUid ? { type: "meet.request", toUid, questionId } : { type: "meet.request", questionId });
  });
}

/** Wave state towards the asker of someone else's question (identity may be hidden). */
export function askerState(questionId: string): "none" | "requested" | "incoming" | "matched" | "declined" {
  const m = meet.value.matches.find((x) => x.questionId === questionId);
  if (m) {
    if (m.status === "accepted") return "matched";
    if (m.status === "declined") return "declined";
    return m.outgoing ? "requested" : "incoming";
  }
  return requestedLocal.value.has(`?:${questionId}`) ? "requested" : "none";
}

export function respondMeet(matchId: string, accept: boolean) {
  if (accept && !you.value?.name?.trim()) return withName("meet", () => respondMeet(matchId, true));
  meet.value = {
    ...meet.value,
    matches: meet.value.matches.map((m) =>
      m.id === matchId ? { ...m, status: accept ? "accepted" : "declined" } : m,
    ),
  };
  send({ type: "meet.respond", matchId, accept });
}

/** Relationship with a peer for rendering "Say hi" / "Requested" / "Matched" states. */
export function peerState(uid: string): "none" | "requested" | "incoming" | "matched" | "declined" {
  const m = meet.value.matches.find((x) => x.peer.uid === uid);
  if (m) {
    if (m.status === "accepted") return "matched";
    if (m.status === "declined") return "declined";
    return m.outgoing ? "requested" : "incoming";
  }
  for (const k of requestedLocal.value) if (k.startsWith(uid + ":")) return "requested";
  return "none";
}
