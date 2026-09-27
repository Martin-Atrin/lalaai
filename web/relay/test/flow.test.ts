import { afterAll, beforeAll, expect, test } from "bun:test";
import type { Subprocess } from "bun";

const PORT = 18787;
const BASE = `http://127.0.0.1:${PORT}`;
let proc: Subprocess;

beforeAll(async () => {
  proc = Bun.spawn(["bun", "src/server.ts"], { env: { ...process.env, PORT: String(PORT), HOST: "127.0.0.1" }, stdout: "ignore" });
  for (let i = 0; i < 50; i++) {
    try { if ((await fetch(`${BASE}/api/health`)).ok) return; } catch {}
    await Bun.sleep(100);
  }
  throw new Error("relay did not start");
});
afterAll(() => proc.kill());

class Client {
  msgs: any[] = [];
  ws!: WebSocket;
  constructor(public url: string) {}
  open() {
    return new Promise<this>((res, rej) => {
      this.ws = new WebSocket(this.url);
      this.ws.onmessage = (e) => this.msgs.push(JSON.parse(String(e.data)));
      this.ws.onopen = () => res(this);
      this.ws.onerror = rej;
    });
  }
  send(m: any) { this.ws.send(JSON.stringify(m)); }
  async wait(pred: (m: any) => boolean, ms = 2000) {
    const t = Date.now();
    while (Date.now() - t < ms) {
      const i = this.msgs.findIndex(pred);
      if (i >= 0) return this.msgs.splice(0, i + 1)[i];
      await Bun.sleep(10);
    }
    throw new Error("timeout waiting; got " + JSON.stringify(this.msgs.map((m) => m.type)));
  }
}

test("full meetup flow", async () => {
  const slug = (await (await fetch(`${BASE}/api/names/random`)).json()).slug as string;
  const create = await fetch(`${BASE}/api/rooms`, {
    method: "POST",
    body: JSON.stringify({ slug, title: "Talk", presenterName: "Pres", presenterLang: "en", languages: ["de", "cs"], llmEnabled: true }),
  });
  const { presenterToken, joinUrl, room } = await create.json();
  expect(joinUrl).toBe(`${BASE}/m/${slug}`);
  expect(room.languages).toEqual(["en", "de", "cs"]);
  // taken without token
  expect((await fetch(`${BASE}/api/rooms`, { method: "POST", body: JSON.stringify({ slug, presenterLang: "en", languages: [] }) })).status).toBe(409);

  const ws = BASE.replace("http", "ws") + "/ws";
  const P = await new Client(`${ws}?room=${slug}&role=presenter&token=${presenterToken}`).open();
  await P.wait((m) => m.type === "presenter.welcome");

  const A = await new Client(`${ws}?room=${slug}&role=attendee&uid=aaaaaaaaaa&secret=${"s".repeat(20)}`).open();
  const w = await A.wait((m) => m.type === "welcome");
  expect(w.you).toBeNull();
  A.send({ type: "profile.update", profile: { name: "Anna", avatar: "fox", color: "#112233", lang: "de", contact: "@anna" } });
  await A.wait((m) => m.type === "welcome" && m.you?.lang === "de");

  const B = await new Client(`${ws}?room=${slug}&role=attendee&uid=bbbbbbbbbb&secret=${"t".repeat(20)}`).open();
  B.send({ type: "profile.update", profile: { name: "Bob", avatar: "owl", color: "#445566", lang: "cs" } });
  await B.wait((m) => m.type === "welcome" && m.you?.name === "Bob");
  await P.wait((m) => m.type === "stats" && m.attendees === 2);

  // impersonation blocked
  const bad = await fetch(`${BASE}/ws?room=${slug}&role=attendee&uid=aaaaaaaaaa&secret=${"x".repeat(20)}`, { headers: { upgrade: "websocket", connection: "upgrade", "sec-websocket-key": "dGhlIHNhbXBsZSBub25jZQ==", "sec-websocket-version": "13" } });
  expect(bad.status).toBe(403);

  // transcript: partial without de translation is not sent to A, final falls back to source
  P.send({ type: "segment", id: 1, final: false, source: "Hello", texts: { cs: "Ahoj" } });
  expect((await B.wait((m) => m.type === "segment")).segment.text).toBe("Ahoj");
  P.send({ type: "segment", id: 1, final: true, source: "Hello world", texts: { de: "Hallo Welt" } });
  const sa = await A.wait((m) => m.type === "segment");
  expect(sa.segment).toMatchObject({ id: 1, final: true, text: "Hallo Welt", source: "Hello world" });

  // Q&A: A asks in German, presenter translates
  A.send({ type: "question.ask", text: "Wie skaliert das?" });
  const qn = await P.wait((m) => m.type === "question.new");
  expect(qn.question.originalLang).toBe("de");
  const qid = qn.question.id;
  const bq = await B.wait((m) => m.type === "question.upsert");
  expect(bq.question).toMatchObject({ text: "Wie skaliert das?", translated: false, mine: false });
  P.send({ type: "question.translations", id: qid, texts: { en: "How does it scale?", cs: "Jak to škáluje?" } });
  expect((await B.wait((m) => m.type === "question.upsert" && m.question.translated)).question.text).toBe("Jak to škáluje?");

  // B likes it -> A sees liker
  B.send({ type: "question.like", id: qid, like: true });
  expect((await P.wait((m) => m.type === "question.state" && m.question.likes === 1)).question.texts.en).toBe("How does it scale?");
  const meetA = await A.wait((m) => m.type === "meet.update" && m.meet.likers.length === 1);
  expect(meetA.meet.likers[0].people[0]).toMatchObject({ uid: "bbbbbbbbbb", name: "Bob" });
  expect(meetA.meet.likers[0].people[0].contact).toBeUndefined();

  // A asks to meet B, B accepts -> presenter gets job, returns icebreakers
  A.send({ type: "meet.request", toUid: "bbbbbbbbbb", questionId: qid });
  const req = await B.wait((m) => m.type === "meet.update" && m.meet.matches.length === 1);
  const match = req.meet.matches[0];
  expect(match).toMatchObject({ status: "pending", outgoing: false, questionText: "Jak to škáluje?" });
  expect(match.peer.contact).toBeUndefined();
  B.send({ type: "meet.respond", matchId: match.id, accept: true });
  const job = (await P.wait((m) => m.type === "icebreakers.needed")).job;
  expect(job.langs.sort()).toEqual(["cs", "de"]);
  const pend = await B.wait((m) => m.type === "meet.update" && m.meet.matches[0]?.status === "accepted");
  expect(pend.meet.matches[0].icebreakerSource).toBe("pending");
  expect(pend.meet.matches[0].peer.contact).toBe("@anna");
  P.send({ type: "icebreakers.result", matchId: match.id, icebreakers: { de: [{ topic: "Skalierung", prompt: "Wie?" }], cs: [{ topic: "Škálování", prompt: "Jak?" }] } });
  const doneA = await A.wait((m) => m.type === "meet.update" && m.meet.matches[0]?.icebreakerSource === "llm");
  expect(doneA.meet.matches[0].icebreakers[0].topic).toBe("Skalierung");
  const doneB = await B.wait((m) => m.type === "meet.update" && m.meet.matches[0]?.icebreakerSource === "llm");
  expect(doneB.meet.matches[0].icebreakers[0].topic).toBe("Škálování");

  // moderation: pin
  P.send({ type: "question.moderate", id: qid, pinned: true });
  expect((await A.wait((m) => m.type === "question.upsert" && m.question.pinned)).question.mine).toBe(true);

  for (const c of [P, A, B]) c.ws.close();
});

test("serves PWA fallback for /m/:slug", async () => {
  const r = await fetch(`${BASE}/m/anything`);
  expect(r.status).toBe(200);
});

test("anonymous questions stay anonymous until a wave is accepted", async () => {
  const slug = `anon-${Math.floor(Math.random() * 1e6)}`;
  const { presenterToken } = await (await fetch(`${BASE}/api/rooms`, {
    method: "POST",
    body: JSON.stringify({ slug, title: "T", presenterName: "P", presenterLang: "en", languages: ["th"], llmEnabled: false }),
  })).json();
  const ws = BASE.replace("http", "ws") + "/ws";
  const P = await new Client(`${ws}?room=${slug}&role=presenter&token=${presenterToken}`).open();
  const A = await new Client(`${ws}?room=${slug}&role=attendee&uid=tongtong01&secret=${"a".repeat(20)}`).open();
  A.send({ type: "profile.update", profile: { name: "Tong", avatar: "cat", color: "#112233", lang: "th", spotMe: "red hat with stripes", contact: "@tong" } });
  await A.wait((m) => m.type === "welcome" && m.you?.name === "Tong");
  const B = await new Client(`${ws}?room=${slug}&role=attendee&uid=samsam0001&secret=${"b".repeat(20)}`).open();
  B.send({ type: "profile.update", profile: { name: "Sam", avatar: "owl", color: "#445566", lang: "en", spotMe: "green backpack" } });
  await B.wait((m) => m.type === "welcome" && m.you?.name === "Sam");

  A.send({ type: "question.ask", text: "ไม่อยากบอกชื่อ แต่อยากถาม", anonymous: true });
  const bq = (await B.wait((m) => m.type === "question.upsert")).question;
  expect(bq.anonymous).toBe(true);
  expect(bq.author).toEqual({ uid: "", name: "", avatar: "anon", color: "#8a9bb8" });
  const pq = (await P.wait((m) => m.type === "question.new")).question;
  expect(pq.author.uid).toBe("");
  expect(pq.author.name).toBe("");
  const aq = (await A.wait((m) => m.type === "question.upsert")).question;
  expect(aq.mine).toBe(true);
  expect(aq.author.name).toBe("Tong");

  // B likes, then waves at the anonymous asker without knowing who it is
  B.send({ type: "question.like", id: bq.id, like: true });
  B.send({ type: "meet.request", questionId: bq.id });
  const bPending = (await B.wait((m) => m.type === "meet.update" && m.meet.matches[0]?.status === "pending")).meet.matches[0];
  expect(bPending.peerMasked).toBe(true);
  expect(bPending.peer.name).toBe("");
  expect(JSON.stringify(bPending)).not.toContain("tongtong01");
  const aPending = (await A.wait((m) => m.type === "meet.update" && m.meet.matches[0]?.status === "pending")).meet.matches[0];
  expect(aPending.peer.name).toBe("Sam");
  expect(aPending.peer.spotMe).toBeUndefined();

  // Tong accepts -> both revealed, including how to spot each other
  A.send({ type: "meet.respond", matchId: aPending.id, accept: true });
  const bDone = (await B.wait((m) => m.type === "meet.update" && m.meet.matches[0]?.status === "accepted")).meet.matches[0];
  expect(bDone.peerMasked).toBe(false);
  expect(bDone.peer).toMatchObject({ name: "Tong", spotMe: "red hat with stripes", contact: "@tong" });
  const aDone = (await A.wait((m) => m.type === "meet.update" && m.meet.matches[0]?.status === "accepted")).meet.matches[0];
  expect(aDone.peer.spotMe).toBe("green backpack");
  for (const c of [P, A, B]) c.ws.close();
});
