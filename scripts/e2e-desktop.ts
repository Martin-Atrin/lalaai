// End-to-end: relay + real lalaai.app (autolive, no mic) + two simulated phones + fake MCP agent.
// Run: bun scripts/e2e-desktop.ts   (expects relay on :8787 and apps/macos/build/lalaai.app built)
const BASE = process.env.RELAY ?? "http://127.0.0.1:8787";
const slug = `e2e-${Math.floor(Math.random() * 1e6)}`;
const root = new URL("..", import.meta.url).pathname;

const app = Bun.spawn([`${root}apps/macos/build/lalaai.app/Contents/MacOS/lalaai`, "--autolive"], {
  env: {
    ...process.env,
    LALAAI_RELAY: BASE, LALAAI_SLUG: slug, LALAAI_TITLE: "On-device ML", LALAAI_LOCALE: "en_US",
    LALAAI_TARGETS: "es,fr", LALAAI_MCP_PORT: "18799", LALAAI_PROVIDER: process.env.E2E_PROVIDER ?? "custom", LALAAI_MODEL: process.env.E2E_MODEL ?? "",
    LALAAI_CUSTOM_CMD: `${root}scripts/fake-agent.sh`, LALAAI_NO_MIC: "1",
  },
  stdout: "ignore", stderr: "ignore",
});

const step = (s: string) => console.log("✓", s);
async function until<T>(f: () => Promise<T | undefined> | T | undefined, what: string, ms = 20000): Promise<T> {
  const t = Date.now();
  while (Date.now() - t < ms) { const v = await f(); if (v) return v; await Bun.sleep(100); }
  throw new Error("timeout: " + what);
}
function phone(uid: string, profile: any) {
  const msgs: any[] = [];
  const ws = new WebSocket(`${BASE.replace("http", "ws")}/ws?room=${slug}&role=attendee&uid=${uid}&secret=${"k".repeat(24)}`);
  ws.onmessage = (e) => msgs.push(JSON.parse(String(e.data)));
  ws.onopen = () => ws.send(JSON.stringify({ type: "profile.update", profile }));
  return { msgs, send: (m: any) => ws.send(JSON.stringify(m)), close: () => ws.close(), last: (f: (m: any) => boolean) => [...msgs].reverse().find(f) };
}

try {
  const room = await until(async () => { const r = await fetch(`${BASE}/api/rooms/${slug}`); return r.ok ? r.json() : undefined; }, "room created by app");
  await until(async () => (await (await fetch(`${BASE}/api/rooms/${slug}`)).json()).live, "presenter socket live");
  step(`app went live: ${JSON.stringify(room.languages)}`);

  const A = phone("ana0000001", { name: "Ana", avatar: "fox", color: "#ff7a59", lang: "es", tagline: "iOS dev", contact: "@ana" });
  const B = phone("bob0000001", { name: "Bob", avatar: "owl", color: "#3366ff", lang: "fr", tagline: "ML researcher" });
  await until(() => A.last((m) => m.type === "welcome" && m.you) && B.last((m) => m.type === "welcome" && m.you), "welcomes");

  A.send({ type: "question.ask", text: "¿Cuánta batería consume la transcripción en el dispositivo?" });
  const q = await until(() => B.last((m) => m.type === "question.upsert" && m.question.translated), "desktop translated question to fr", 30000);
  step(`question translated es→fr on device: "${q.question.text}"`);

  B.send({ type: "question.like", id: q.question.id, like: true });
  await until(() => A.last((m) => m.type === "meet.update" && m.meet.likers.length), "A sees liker");
  A.send({ type: "meet.request", toUid: "bob0000001", questionId: q.question.id });
  const req = await until(() => B.last((m) => m.type === "meet.update" && m.meet.matches[0]?.status === "pending")?.meet.matches[0], "B gets request");
  B.send({ type: "meet.respond", matchId: req.id, accept: true });
  step("matched");

  const ma = await until(() => A.last((m) => m.type === "meet.update" && m.meet.matches[0]?.icebreakerSource === "llm")?.meet.matches[0], "A gets agent icebreakers", 170000);
  const mb = await until(() => B.last((m) => m.type === "meet.update" && m.meet.matches[0]?.icebreakerSource === "llm")?.meet.matches[0], "B gets agent icebreakers", 170000);
  step(`A (es) icebreaker: ${ma.icebreakers[0].topic} — ${ma.icebreakers[0].prompt}`);
  step(`B (fr) icebreaker: ${mb.icebreakers[0].topic} — ${mb.icebreakers[0].prompt}`);
  step(`B sees A's contact: ${mb.peer.contact}`);
  A.close(); B.close();
  console.log("E2E PASS");
} catch (e) {
  console.error("E2E FAIL", e);
  process.exitCode = 1;
} finally {
  app.kill();
  process.exit();
}
