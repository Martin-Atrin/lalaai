import type { MatchView, Profile } from "@shared/protocol";
import { meet, peerState, requestMeet, respondMeet, room, you } from "../store";
import { t, displayName } from "../i18n";
import { Avatar } from "./Avatar";
import { Mascot } from "./Mascot";

function PersonRow({ p, questionId }: { p: Profile; questionId: string }) {
  const st = peerState(p.uid);
  return (
    <li class="person">
      <Avatar who={p} size={40} />
      <div class="person-info">
        <div class="person-name">{displayName(p.name)}</div>
        {p.tagline && <div class="muted small ellip">{p.tagline}</div>}
      </div>
      {st === "none" || st === "declined" ? (
        <button class="btn primary sm" onClick={() => requestMeet(p.uid, questionId)} disabled={st === "declined"}>
          {t("sayHi")}
        </button>
      ) : (
        <span class={`status-chip ${st}`}>
          {st === "matched" ? `🤝 ${t("matched")}` : st === "incoming" ? `📨 ${t("requests")}` : `✓ ${t("requested")}`}
        </span>
      )}
    </li>
  );
}

function ContactLine({ contact }: { contact: string }) {
  const c = contact.trim();
  let href: string | null = null;
  if (/^https?:\/\//i.test(c)) href = c;
  else if (/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(c)) href = `mailto:${c}`;
  else if (/^(t\.me|linkedin\.com|www\.linkedin\.com)\//i.test(c)) href = `https://${c}`;
  else if (/^@\w{3,}$/.test(c)) href = `https://t.me/${c.slice(1)}`;
  return (
    <div class="contact">
      <span class="muted small">{t("reachThem")}</span>
      {href ? (
        <a href={href} target="_blank" rel="noopener noreferrer" class="contact-val">
          {c}
        </a>
      ) : (
        <span class="contact-val" style={{ userSelect: "all" }}>
          {c}
        </span>
      )}
    </div>
  );
}

/** A masked peer is the anonymous asker; their name appears only once the wave is accepted. */
function peerName(m: MatchView) {
  return m.peerMasked ? t("anonymousAsker") : displayName(m.peer.name);
}

function MatchCard({ m }: { m: MatchView }) {
  return (
    <article class="card match" style={{ "--peer": m.peer.color } as Record<string, string>}>
      <header class="match-head">
        <Avatar who={m.peer} size={56} />
        <div>
          <div class="match-name">{peerName(m)}</div>
          {m.peer.tagline && <div class="muted small">{m.peer.tagline}</div>}
        </div>
      </header>
      {m.peer.spotMe && (
        <div class="spot">
          <span class="spot-eyes" aria-hidden="true">👀</span>
          <div>
            <div class="muted small">{t("spotThem")}</div>
            <div class="spot-val" dir="auto">{m.peer.spotMe}</div>
          </div>
        </div>
      )}
      {m.peer.contact && <ContactLine contact={m.peer.contact} />}
      <div class="match-q">
        <span class="muted small">{t("connectedOver")}</span>
        <q dir="auto">{m.questionText}</q>
      </div>
      <div class="ice">
        <div class="ice-title">🧊 {t("icebreakers")}</div>
        {m.icebreakerSource === "pending" ? (
          <div class="cooking" role="status">
            <span class="pot" aria-hidden="true">
              🍳
            </span>
            <span>{t("cooking")}</span>
            <div class="shimmer" />
            <div class="shimmer short" />
          </div>
        ) : (
          <ul class="ice-list">
            {m.icebreakers.map((ib, i) => (
              <li key={i}>
                <span class="topic">{ib.topic}</span>
                <span dir="auto">{ib.prompt}</span>
              </li>
            ))}
          </ul>
        )}
        {m.icebreakerSource === "fallback" && <p class="muted small note">{t("fallbackNote")}</p>}
      </div>
    </article>
  );
}

export function Meet() {
  const st = meet.value;
  const r = room.value;
  const myUid = you.value?.uid;
  const incoming = st.matches.filter((m) => m.status === "pending" && !m.outgoing);
  const outgoing = st.matches.filter((m) => m.status === "pending" && m.outgoing);
  const accepted = [...st.matches.filter((m) => m.status === "accepted")].sort((a, b) => b.createdAt - a.createdAt);
  const likers = st.likers
    .map((l) => ({ ...l, people: l.people.filter((p) => p.uid !== myUid) }))
    .filter((l) => l.people.length);

  return (
    <div class="scroll meet">
      <section class="meet-hero card soft">
        <Mascot size={84} greet={false} mood="party" />
        <div>
          <h2 class="h2">{t("meetTitle")}</h2>
          <p class="muted small">{t("meetBody")}</p>
        </div>
      </section>
      {r && !r.llmEnabled && <p class="note-bar">✨ {t("llmOff")}</p>}

      {(incoming.length > 0 || outgoing.length > 0) && (
        <section>
          <h3 class="sec-title">
            {t("requests")} {incoming.length > 0 && <span class="count-badge">{incoming.length}</span>}
          </h3>
          <ul class="stack">
            {incoming.map((m) => (
              <li class="card req" key={m.id}>
                <div class="person">
                  <Avatar who={m.peer} size={44} />
                  <div class="person-info">
                    <div class="person-name">
                      {peerName(m)} <span class="muted small">{t("wantsToMeet")}</span>
                    </div>
                    {m.peer.tagline && <div class="muted small">{m.peer.tagline}</div>}
                    {m.peerMasked && <div class="muted small">🎭 {t("revealNote")}</div>}
                  </div>
                </div>
                <q class="req-q small" dir="auto">
                  {m.questionText}
                </q>
                <div class="row gap">
                  <button class="btn ghost grow" onClick={() => respondMeet(m.id, false)}>
                    {t("decline")}
                  </button>
                  <button class="btn primary grow" onClick={() => respondMeet(m.id, true)}>
                    {t("accept")} 🤝
                  </button>
                </div>
              </li>
            ))}
            {outgoing.map((m) => (
              <li class="card req out" key={m.id}>
                <div class="person">
                  <Avatar who={m.peer} size={36} />
                  <div class="person-info">
                    <div class="person-name">{peerName(m)}</div>
                    <div class="muted small">{m.peerMasked ? `🎭 ${t("revealNote")}` : t("waitingReply")}</div>
                  </div>
                  <span class="status-chip requested">{t("outgoing")}</span>
                </div>
              </li>
            ))}
          </ul>
        </section>
      )}

      <section>
        <h3 class="sec-title">{t("matches")}</h3>
        {accepted.length === 0 ? (
          <p class="muted small pad">{t("noMatches")}</p>
        ) : (
          <div class="stack">
            {accepted.map((m) => (
              <MatchCard key={m.id} m={m} />
            ))}
          </div>
        )}
      </section>

      <section>
        <h3 class="sec-title">{t("likedYours")}</h3>
        {likers.length === 0 ? (
          <p class="muted small pad">{t("noLikers")}</p>
        ) : (
          <div class="stack">
            {likers.map((l) => (
              <div class="card" key={l.questionId}>
                <q class="liked-q" dir="auto">
                  {l.questionText}
                </q>
                <ul class="people">
                  {l.people.map((p) => (
                    <PersonRow key={p.uid} p={p} questionId={l.questionId} />
                  ))}
                </ul>
              </div>
            ))}
          </div>
        )}
      </section>
    </div>
  );
}
