import { Icon, type IconName } from "./components/Icon";
import { useEffect, useState } from "preact/hooks";
import type { RoomInfo } from "@shared/protocol";
import { getIdentity } from "./identity";
import { fetchRoom, openSocket } from "./net";
import type { Link, LinkHandlers } from "./net";
import {
  conn,
  handleMessage,
  pendingIncoming,
  room,
  setLink,
  settingsOpen,
  showOnboarding,
  tab,
  welcomed,
} from "./store";
import type { Tab } from "./store";
import { setUiLang, t } from "./i18n";
import { Mascot } from "./components/Mascot";
import { Onboarding } from "./components/Onboarding";
import { Live } from "./components/Live";
import { QA } from "./components/QA";
import { Meet } from "./components/Meet";
import { Settings } from "./components/Settings";
import { Toasts } from "./components/Toasts";

const params = new URLSearchParams(location.search);
const MOCK = params.get("mock") === "1";

function parseSlug(): string | null {
  const m = location.pathname.match(/^\/m\/([^/?#]+)/);
  return m ? decodeURIComponent(m[1]).toLowerCase() : null;
}

function normalizeCode(s: string): string {
  return s
    .trim()
    .toLowerCase()
    .replace(/^.*\/m\//, "")
    .replace(/\s+/g, "-")
    .replace(/[^a-z0-9-]/g, "")
    .slice(0, 64);
}

// ─────────────────────────── entry: "/" ───────────────────────────
function EnterCode({ error }: { error?: boolean }) {
  const [code, setCode] = useState("");
  const go = (e: Event) => {
    e.preventDefault();
    const c = normalizeCode(code);
    if (c) location.assign(`/m/${encodeURIComponent(c)}${MOCK ? "?mock=1" : ""}`);
  };
  return (
    <main class="center-screen">
      <Mascot size={150} lead={t("hello")} />
      <h1 class="brand">
        La <span>Laai</span>
      </h1>
      <p class="brand-tagline">Melt the language barrier.<br />Break the ice.</p>
      <p class="muted center">{t("tagline")}</p>
      {error && (
        <div class="card warn-card" role="alert">
          <b>{t("notFoundTitle")}</b>
          <div class="small">{t("notFoundBody")}</div>
        </div>
      )}
      <form class="enter-form card" onSubmit={go}>
        <label class="field">
          <span class="field-label">{t("enterTitle")}</span>
          <input
            class="input big-input"
            value={code}
            autoCapitalize="none"
            autoCorrect="off"
            spellcheck={false}
            enterKeyHint="go"
            placeholder={t("enterPlaceholder")}
            onInput={(e) => setCode((e.target as HTMLInputElement).value)}
          />
          <span class="field-help">{t("enterHint")}</span>
        </label>
        <button class="btn primary big full" disabled={!normalizeCode(code)}>
          {t("join")} →
        </button>
      </form>
    </main>
  );
}

// ─────────────────────────── room shell ───────────────────────────
function Header() {
  const r = room.value!;
  const c = conn.value;
  return (
    <header class="topbar">
      <div class="topbar-main">
        <div class="topbar-titles">
          <h1 class="room-title" title={r.title}>
            {r.title}
          </h1>
          <div class="room-sub muted small">{t("by", { name: r.presenterName })}</div>
        </div>
        <div class="topbar-meta">
          <span class={`live-badge ${r.live ? "on" : ""}`}>
            <span class={`live-dot ${r.live ? "on" : ""}`} aria-hidden="true" />
            {r.live ? t("live") : t("offline")}
          </span>
          <span class="count-pill" aria-label={t("here", { n: r.attendeeCount })}>
            <Icon name="users" size={14} /> {r.attendeeCount}
          </span>
        </div>
      </div>
      {c !== "open" && (
        <div class="conn-bar" role="status">
          <span class="spinner" aria-hidden="true" /> {c === "reconnecting" ? t("reconnecting") : t("connecting")}
        </div>
      )}
    </header>
  );
}

const TABS: { id: Tab; icon: IconName; label: () => string }[] = [
  { id: "live", icon: "mic", label: () => t("tabLive") },
  { id: "qa", icon: "chat", label: () => t("tabQA") },
  { id: "meet", icon: "handshake", label: () => t("tabMeet") },
];

function TabBar() {
  const cur = tab.value;
  const pending = pendingIncoming.value.length;
  return (
    <nav class="tabbar" aria-label="Main">
      {TABS.map((x) => (
        <button
          key={x.id}
          class={`tab ${cur === x.id ? "on" : ""}`}
          aria-current={cur === x.id ? "page" : undefined}
          onClick={() => (tab.value = x.id)}
        >
          <span class="tab-icon" aria-hidden="true">
            <Icon name={x.icon} size={22} strokeWidth={cur === x.id ? 2.3 : 1.8} />
            {x.id === "meet" && pending > 0 && <span class="tab-badge">{pending}</span>}
          </span>
          <span class="tab-label">
            {x.label()}
            {x.id === "meet" && pending > 0 && <span class="sr-only"> ({pending})</span>}
          </span>
        </button>
      ))}
      <button class="tab" onClick={() => (settingsOpen.value = true)} aria-haspopup="dialog">
        <span class="tab-icon" aria-hidden="true">
          <Icon name="settings" size={22} strokeWidth={1.8} />
        </span>
        <span class="tab-label">{t("tabSettings")}</span>
      </button>
    </nav>
  );
}

function RoomApp() {
  const cur = tab.value;
  if (!welcomed.value) {
    return (
      <main class="center-screen">
        <Mascot size={120} greet={false} />
        <p class="muted">{t("connecting")}</p>
      </main>
    );
  }
  if (showOnboarding.value) return <Onboarding />;
  return (
    <div class="shell">
      <Header />
      <main class={`content tab-${cur}`}>
        {cur === "live" && <Live />}
        {cur === "qa" && <QA />}
        {cur === "meet" && <Meet />}
      </main>
      <TabBar />
      {settingsOpen.value && <Settings />}
    </div>
  );
}

type Phase = "loading" | "notfound" | "error" | "ready";

function RoomScreen({ slug }: { slug: string }) {
  const [phase, setPhase] = useState<Phase>("loading");
  const [attempt, setAttempt] = useState(0);

  useEffect(() => {
    let cancelled = false;
    let link: Link | null = null;
    const id = getIdentity();
    const handlers: LinkHandlers = {
      onMessage: handleMessage,
      onStatus: (s) => (conn.value = s),
    };
    (async () => {
      let info: RoomInfo | null = null;
      let mock: typeof import("./mock") | null = null;
      if (MOCK) {
        mock = await import("./mock");
        info = mock.mockRoom(slug);
      } else {
        const res = await fetchRoom(slug);
        if (cancelled) return;
        if (res.kind === "notfound") return setPhase("notfound");
        if (res.kind === "error") return setPhase("error");
        info = res.room;
      }
      if (cancelled) return;
      room.value = info;
      setUiLang(info.presenterLang);
      document.title = `${info.title} · La Laai`;
      setPhase("ready");
      link = mock ? mock.openMock(slug, id, handlers) : openSocket(slug, id, handlers);
      setLink(link);
    })();
    return () => {
      cancelled = true;
      setLink(null);
    };
  }, [slug, attempt]);

  if (phase === "loading") {
    return (
      <main class="center-screen">
        <Mascot size={120} greet={false} />
        <p class="muted">{t("loading")}</p>
      </main>
    );
  }
  if (phase === "notfound") {
    return (
      <NotLiveYet slug={slug} retry={() => setAttempt((a) => a + 1)} />
    );
  }
  if (phase === "error") {
    return (
      <main class="center-screen">
        <Mascot size={130} greet={false} mood="sleepy" />
        <h1 class="h1">{t("netErrorTitle")}</h1>
        <p class="muted center">{t("netErrorBody")}</p>
        <button class="btn primary big" onClick={() => (setPhase("loading"), setAttempt((a) => a + 1))}>
          {t("retry")}
        </button>
      </main>
    );
  }
  return <RoomApp />;
}

export function App() {
  const slug = parseSlug();
  const view = slug ? <RoomScreen slug={slug} /> : <EnterCode />;
  return (
    <>
      {view}
      <Toasts />
    </>
  );
}

/** Room doesn't exist (yet): the speaker probably hasn't pressed Go live. Poll and join automatically. */
function NotLiveYet({ slug, retry }: { slug: string; retry: () => void }) {
  useEffect(() => {
    const id = setInterval(retry, 3000);
    return () => clearInterval(id);
  }, [slug]);
  return (
    <main class="center-screen">
      <Mascot size={130} greet={false} mood="sleepy" />
      <h1 class="h1">{t("notFoundTitle")}</h1>
      <p class="muted center">
        <code class="code">{slug}</code> — {t("notFoundBody")}
      </p>
      <div class="muted small">…</div>
      <a class="btn primary big" href="/">
        {t("tryAnother")}
      </a>
    </main>
  );
}
