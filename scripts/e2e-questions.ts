// Reverse direction: attendees ask in es / th → presenter sees English (via MCP get_questions),
// and every attendee sees every question in their own language.
const BASE = process.env.RELAY ?? "http://127.0.0.1:8787";
const slug = `q-${Math.floor(Math.random() * 1e6)}`;
const root = new URL("..", import.meta.url).pathname;
const app = Bun.spawn([`${root}apps/macos/build/lalaai.app/Contents/MacOS/lalaai`, "--autolive"], {
  env: { ...process.env, LALAAI_RELAY: BASE, LALAAI_SLUG: slug, LALAAI_LOCALE: "en_US", LALAAI_TARGETS: "th,es", LALAAI_PROVIDER: "none", LALAAI_NO_MIC: "1", LALAAI_MCP_PORT: "18799" },
  stdout: "ignore", stderr: "ignore",
});
const until = async <T>(f: () => T | undefined | Promise<T | undefined>, what: string, ms = 20000): Promise<T> => {
  const t = Date.now();
  while (Date.now() - t < ms) { const v = await f(); if (v) return v; await Bun.sleep(100); }
  throw new Error("timeout: " + what);
};
function phone(uid: string, profile: any) {
  const msgs: any[] = [];
  const ws = new WebSocket(`${BASE.replace("http", "ws")}/ws?room=${slug}&role=attendee&uid=${uid}&secret=${"k".repeat(24)}`);
  ws.onmessage = (e) => msgs.push(JSON.parse(String(e.data)));
  ws.onopen = () => ws.send(JSON.stringify({ type: "profile.update", profile }));
  const qs = () => { const m = new Map<string, any>(); for (const x of msgs) { if (x.type === "welcome") for (const q of x.questions) m.set(q.id, q); if (x.type === "question.upsert") m.set(x.question.id, x.question); } return m; };
  return { msgs, qs, send: (m: any) => ws.send(JSON.stringify(m)), close: () => ws.close() };
}
const mcp = async (name: string) => {
  const r = await fetch("http://127.0.0.1:18799/mcp", { method: "POST", body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: {} } }) });
  return JSON.parse((await r.json()).result.content[0].text);
};
try {
  await until(async () => (await fetch(`${BASE}/api/rooms/${slug}`)).ok && (await (await fetch(`${BASE}/api/rooms/${slug}`)).json()).live, "live");
  const ES = phone("esp0000001", { name: "Lucía", avatar: "frog", color: "#45c2f9", lang: "es" });
  const TH = phone("tha0000001", { name: "Ploy", avatar: "cat", color: "#f9606c", lang: "th" });
  const EN = phone("eng0000001", { name: "Sam", avatar: "owl", color: "#002060", lang: "en" });
  await until(() => [ES, TH, EN].every((p) => p.msgs.some((m) => m.type === "welcome" && m.you)), "welcomes");
  ES.send({ type: "question.ask", text: "¿Dónde encuentro espacios de coworking en Nimman?" });
  await Bun.sleep(9000); // relay rate-limits per person, not globally — but keep ordering readable
  TH.send({ type: "question.ask", text: "จะเริ่มทำงานกับลูกค้าต่างชาติได้อย่างไร" });
  const all = (p: any) => [...p.qs().values()].filter((q: any) => q.translated || q.mine);
  await until(() => all(ES).length === 2 && all(TH).length === 2 && all(EN).length === 2, "everyone sees both translated", 30000);
  const show = (who: string, p: any) => { console.log(`${who} sees:`); for (const q of p.qs().values()) console.log(`   ${q.translated ? "🌐" : "  "} ${q.text}   [orig ${q.originalLang}]`); };
  show("🇪🇸 Lucía", ES); show("🇹🇭 Ploy", TH); show("🇬🇧 Sam", EN);
  const pres = await mcp("get_questions");
  console.log("🎤 Presenter (en) sees:"); for (const q of pres.questions) console.log(`      ${q.text}   [orig ${q.original_lang}]`);
  if (pres.questions.some((q: any) => q.text === q.original)) throw new Error("presenter saw an untranslated question");
  console.log("QUESTIONS PASS");
  [ES, TH, EN].forEach((p) => p.close());
} catch (e) { console.error("FAIL", e); process.exitCode = 1; } finally { app.kill(); process.exit(); }
