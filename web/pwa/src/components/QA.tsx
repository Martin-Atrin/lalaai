import { useMemo, useRef, useState } from "preact/hooks";
import { signal } from "@preact/signals";
import type { QuestionView } from "@shared/protocol";
import {
  askerState,
  askQuestion,
  deleteQuestion,
  peerState,
  questions,
  requestMeet,
  toggleLike,
} from "../store";
import { t, uiLang, displayName } from "../i18n";
import { langNameIn } from "../langs";
import { Avatar } from "./Avatar";
import { Mascot } from "./Mascot";

const MAX = 280;
/** Draft survives tab switches. */
const draft = signal("");
const anonDraft = signal(false);
type Sort = "top" | "new";

function sortQuestions(list: QuestionView[], sort: Sort): QuestionView[] {
  return [...list].sort((a, b) => {
    if (a.pinned !== b.pinned) return a.pinned ? -1 : 1;
    if (sort === "top" && a.likes !== b.likes) return b.likes - a.likes;
    return b.createdAt - a.createdAt;
  });
}

function QuestionCard({ q }: { q: QuestionView }) {
  const [orig, setOrig] = useState(false);
  const [pop, setPop] = useState(0);
  const hidden = q.anonymous && !q.mine;
  const ps = !q.mine && q.likedByMe ? (hidden ? askerState(q.id) : peerState(q.author.uid)) : "none";

  const like = () => {
    if (q.mine) return;
    toggleLike(q);
    if (!q.likedByMe) setPop((x) => x + 1);
  };

  return (
    <article class={`card q ${q.pinned ? "pinned" : ""} ${q.answered ? "answered" : ""}`}>
      <header class="q-head">
        <Avatar who={q.author} size={34} />
        <div class="q-who">
          <span class="q-name">
            {hidden ? t("anonymous") : displayName(q.author.name)}
            {q.mine && <span class="muted"> · {t("you")}</span>}
            {q.mine && q.anonymous && <span class="muted small"> · 🎭 {t("mineAnon")}</span>}
          </span>
          <span class="q-badges">
            {q.pinned && <span class="badge pin">📌 {t("onScreen")}</span>}
            {q.answered && <span class="badge ok">✓ {t("answered")}</span>}
          </span>
        </div>
        {q.mine && (
          <button
            class="icon-btn subtle"
            aria-label={t("delete")}
            title={t("delete")}
            onClick={() => confirm(t("deleteConfirm")) && deleteQuestion(q.id)}
          >
            🗑
          </button>
        )}
      </header>
      <p class="q-text" dir="auto">
        {orig ? q.original : q.text}
      </p>
      {q.translated && (
        <button class="link small muted" onClick={() => setOrig((o) => !o)} aria-pressed={orig}>
          🌐 {t("translatedFrom", { lang: langNameIn(q.originalLang, uiLang.value) })} ·{" "}
          <u>{orig ? t("hideOriginal") : t("showOriginal")}</u>
        </button>
      )}
      <footer class="q-foot">
        <button
          class={`like ${q.likedByMe ? "on" : ""}`}
          onClick={like}
          disabled={q.mine}
          aria-pressed={q.likedByMe}
          aria-label={`${q.likedByMe ? t("unlike") : t("like")} (${q.likes})`}
        >
          <span class="heart" key={pop} aria-hidden="true">
            {q.likedByMe ? "♥" : "♡"}
          </span>
          <span class="like-count">{q.likes}</span>
        </button>
        {!q.mine && q.likedByMe && (
          <button
            class="chip-btn"
            disabled={ps !== "none"}
            onClick={() => requestMeet(hidden ? undefined : q.author.uid, q.id)}
          >
            {ps === "matched" ? `🤝 ${t("matched")}` : ps === "requested" || ps === "incoming" ? `✓ ${t("requested")}` : `👋 ${t("meetAsker")}`}
          </button>
        )}
      </footer>
    </article>
  );
}

export function QA() {
  const [sort, setSort] = useState<Sort>("top");
  const text = draft.value;
  const setText = (v: string) => (draft.value = v);
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const list = questions.value;
  const sorted = useMemo(() => sortQuestions(list, sort), [list, sort]);

  const submit = (e: Event) => {
    e.preventDefault();
    if (!text.trim()) return;
    askQuestion(text, anonDraft.value);
    setText("");
    if (inputRef.current) inputRef.current.style.height = "";
    setSort("new");
  };

  const left = MAX - text.length;

  return (
    <div class="qa">
      <div class="scroll">
        <div class="seg-ctl" role="tablist" aria-label="Sort">
          <button role="tab" aria-selected={sort === "top"} class={sort === "top" ? "on" : ""} onClick={() => setSort("top")}>
            🔥 {t("sortTop")}
          </button>
          <button role="tab" aria-selected={sort === "new"} class={sort === "new" ? "on" : ""} onClick={() => setSort("new")}>
            ✨ {t("sortNew")}
          </button>
        </div>
        {sorted.length === 0 ? (
          <div class="empty">
            <Mascot size={110} greet={false} />
            <p class="muted">{t("noQuestions")}</p>
          </div>
        ) : (
          <div class="stack">
            {sorted.map((q) => (
              <QuestionCard key={q.id} q={q} />
            ))}
          </div>
        )}
      </div>
      {anonDraft.value && <p class="anon-note">🎭 {t("askAnonOn")}</p>}
      <form class="composer" onSubmit={submit}>
        <button
          type="button"
          class={`anon-toggle ${anonDraft.value ? "on" : ""}`}
          aria-pressed={anonDraft.value}
          title={t("askAnonToggle")}
          aria-label={t("askAnonToggle")}
          onClick={() => (anonDraft.value = !anonDraft.value)}
        >
          🎭
        </button>
        <div class="composer-box">
          <textarea
            class="composer-input"
            ref={inputRef}
            rows={1}
            value={text}
            maxLength={MAX}
            dir="auto"
            placeholder={t("askPh")}
            aria-label={t("askPh")}
            onInput={(e) => {
              const el = e.target as HTMLTextAreaElement;
              setText(el.value);
              el.style.height = "auto";
              el.style.height = Math.min(el.scrollHeight, 120) + "px";
            }}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey && !e.isComposing) submit(e);
            }}
          />
          {text.length > 200 && <span class={`count ${left < 20 ? "warn" : ""}`}>{t("charsLeft", { n: left })}</span>}
        </div>
        <button class="send-btn" type="submit" disabled={!text.trim()} aria-label={t("send")}>
          ➤
        </button>
      </form>
    </div>
  );
}
