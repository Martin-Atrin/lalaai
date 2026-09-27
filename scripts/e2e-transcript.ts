// Live transcript path: lalaai.app streams a recording (as if mic) → ASR → translation → relay → phone.
const BASE = process.env.RELAY ?? "http://127.0.0.1:8787";
const slug = `tx-${Math.floor(Math.random() * 1e6)}`;
const root = new URL("..", import.meta.url).pathname;
const app = Bun.spawn([`${root}apps/macos/build/lalaai.app/Contents/MacOS/lalaai`, "--autolive"], {
  env: { ...process.env, LALAAI_RELAY: BASE, LALAAI_SLUG: slug, LALAAI_LOCALE: process.env.E2E_LOCALE ?? "en_US", LALAAI_TARGETS: process.env.E2E_TARGETS ?? "es,fr",
         LALAAI_PROVIDER: "none", LALAAI_MCP_PORT: "18799", LALAAI_AUDIO_FILE: process.env.E2E_AUDIO ?? `${root}apps/macos/build/demo-talk.aiff` },
  stdout: "ignore", stderr: "ignore",
});
try {
  for (let i = 0; i < 100 && !(await fetch(`${BASE}/api/rooms/${slug}`)).ok; i++) await Bun.sleep(100);
  const msgs: any[] = [];
  const ws = new WebSocket(`${BASE.replace("http", "ws")}/ws?room=${slug}&role=attendee&uid=esp0000001&secret=${"k".repeat(24)}`);
  ws.onmessage = (e) => msgs.push(JSON.parse(String(e.data)));
  ws.onopen = () => ws.send(JSON.stringify({ type: "profile.update", profile: { name: "Eva", avatar: "cat", color: "#aa3366", lang: process.env.E2E_VIEWER ?? "es" } }));
  const t0 = Date.now();
  await Bun.sleep(Number(process.env.E2E_WAIT ?? 25000));
  const segs = msgs.filter((m) => m.type === "segment").map((m) => m.segment);
  const partials = segs.filter((s) => !s.final), finals = segs.filter((s) => s.final);
  const firstAt = msgs.findIndex((m) => m.type === "segment");
  console.log(`partials=${partials.length} finals=${finals.length}`);
  for (const f of finals.slice(0, 4)) console.log(`  [${f.id}] ${f.text}\n      ↳ ${f.source}`);
  if (!finals.length || !partials.length) throw new Error("no live segments");
  console.log("TRANSCRIPT PASS");
  ws.close();
} catch (e) { console.error("FAIL", e); process.exitCode = 1; } finally { app.kill(); process.exit(); }
