// End-to-end: Public link. The real lalaai.app hosts the event (embedded relay + bundled cloudflared quick tunnel),
// and simulated phones join through the URL the app puts in its QR code.
// Run: bun scripts/e2e-public-link.ts   (needs apps/macos/build/lalaai.app; no relay of your own)
//   E2E_TUNNEL=auto (default)  real Cloudflare; if trycloudflare.com is blocked, scripts/fake-cloudflared.ts instead
//   E2E_TUNNEL=real | fake     force one
// Covers: phone joins via the tunnel URL, the tunnel drops and comes back on a new URL (QR follows it, room state
// survives), and Cloudflare unreachable → clear Wi-Fi-only fallback.
import { networkInterfaces } from "node:os";

const root = new URL("..", import.meta.url).pathname;
const APP = `${root}apps/macos/build/lalaai.app/Contents/MacOS/lalaai`;
const FAKE = `${root}scripts/fake-cloudflared.ts`;
const MODE = process.env.E2E_TUNNEL ?? "auto";

const step = (s: string) => console.log("✓", s);
async function until<T>(f: () => Promise<T | undefined> | T | undefined, what: string, ms = 20000): Promise<T> {
  const t = Date.now();
  while (Date.now() - t < ms) { const v = await f(); if (v) return v; await Bun.sleep(100); }
  throw new Error("timeout: " + what);
}

class App {
  lines: string[] = [];
  proc: ReturnType<typeof Bun.spawn>;
  constructor(public slug: string, env: Record<string, string>) {
    this.proc = Bun.spawn([APP, "--autolive"], {
      env: {
        ...process.env,
        LALAAI_LINK: "publicLink", LALAAI_SLUG: slug, LALAAI_TITLE: "Tunnel test", LALAAI_LOCALE: "en_US",
        LALAAI_TARGETS: "es", LALAAI_MCP_PORT: "18797", LALAAI_PROVIDER: "none", LALAAI_NO_MIC: "1",
        LALAAI_TUNNEL_RETRY: "1", LALAAI_TUNNEL_HEALTH_INTERVAL: "2", ...env,
      },
      stdout: "ignore", stderr: "pipe",
    });
    (async () => {
      const dec = new TextDecoder();
      let buf = "";
      for await (const chunk of this.proc.stderr as ReadableStream<Uint8Array>) {
        buf += dec.decode(chunk, { stream: true });
        const parts = buf.split("\n");
        buf = parts.pop()!;
        for (const l of parts) { this.lines.push(l); if (process.env.E2E_VERBOSE) console.log("  app:", l); }
      }
    })();
  }
  /** Every join URL the app has shown, oldest first. */
  joins() { return this.lines.flatMap((l) => (l.startsWith("lalaai: join: ") ? [l.slice(14)] : [])); }
  has(s: string) { return this.lines.some((l) => l.includes(s)); }
  relayPort() { for (const l of this.lines) { const m = l.match(/lalaai: relay on :(\d+)/); if (m) return Number(m[1]); } }
  async stop() { this.proc.kill(); await this.proc.exited; }
}

function phone(base: string, slug: string, uid: string) {
  const msgs: any[] = [];
  const ws = new WebSocket(`${base.replace(/^http/, "ws")}/ws?room=${slug}&role=attendee&uid=${uid}&secret=${"k".repeat(24)}`);
  ws.onmessage = (e) => msgs.push(JSON.parse(String(e.data)));
  ws.onopen = () => ws.send(JSON.stringify({ type: "profile.update", profile: { name: uid, avatar: "fox", color: "#ff7a59", lang: "es" } }));
  return { msgs, ws, send: (m: any) => ws.send(JSON.stringify(m)), last: (f: (m: any) => boolean) => [...msgs].reverse().find(f) };
}

const baseOf = (join: string) => join.replace(/\/m\/[^/]+$/, "");
const lanIPs = new Set(Object.values(networkInterfaces()).flat().filter((a) => a?.family === "IPv4").map((a) => a!.address));
const isLan = (u: string) => { try { const h = new URL(u).hostname; return h !== "127.0.0.1" && lanIPs.has(h); } catch { return false; } };

/** Phone opens the QR link, then joins the room over WebSocket through the same host. */
async function joinThrough(base: string, slug: string, uid: string) {
  const page = await fetch(`${base}/m/${slug}`);
  if (!page.ok || !(await page.text()).includes("<html")) throw new Error(`join page via ${base}: HTTP ${page.status}`);
  const p = phone(base, slug, uid);
  const w = await until(() => p.last((m) => m.type === "welcome"), `welcome via ${base}`, 20000);
  if (w.room.title !== "Tunnel test") throw new Error("wrong room: " + JSON.stringify(w.room));
  return p;
}

async function publicLinkFlow(kind: "real" | "fake"): Promise<boolean> {
  const slug = `e2e-tun-${Math.floor(Math.random() * 1e6)}`;
  const tunnelish = kind === "real" ? (u: string) => /^https:\/\/[a-z0-9-]+\.trycloudflare\.com\//.test(u) : (u: string) => u.startsWith("http://127.0.0.1:");
  const app = new App(slug, kind === "fake" ? { LALAAI_CLOUDFLARED: FAKE } : { LALAAI_TUNNEL_TIMEOUT: "60" });
  try {
    let first: string;
    try {
      first = await until(() => app.joins().find(tunnelish), `${kind} public link`, kind === "real" ? 75000 : 20000);
    } catch (e) {
      if (kind === "real") {
        console.log(`  (real quick tunnel not reachable from this network: ${app.lines.filter((l) => l.includes("public link")).pop() ?? "timeout"})`);
        return false;
      }
      throw e;
    }
    step(`[${kind}] app shows public link ${first}`);
    const base = baseOf(first);
    const room = await (await fetch(`${base}/api/rooms/${slug}`)).json();
    if (!room.live) throw new Error("presenter not live behind the tunnel");

    const A = await joinThrough(base, slug, "tunnel0001");
    step(`[${kind}] phone joined through the tunnel`);
    A.send({ type: "question.ask", text: "¿Funciona desde fuera de la red?" });
    const local = phone(`http://127.0.0.1:${app.relayPort()}`, slug, "local00001");
    await until(() => local.last((m) => m.type === "question.upsert" && m.question.text.includes("fuera")), "question reaches the room");
    step(`[${kind}] question asked through the tunnel reached the room`);

    // Tunnel drops: kill cloudflared (our app's child). The QR falls back, then follows the new hostname.
    const kids = (await new Response(Bun.spawn(["pgrep", "-P", String(app.proc.pid)]).stdout).text()).trim().split("\n").filter(Boolean);
    if (!kids.length) throw new Error("no cloudflared child process");
    for (const pid of kids) process.kill(Number(pid), "SIGKILL");
    await until(() => A.ws.readyState === WebSocket.CLOSED, "old link closes", 15000);
    const next = await until(() => app.joins().filter(tunnelish).find((u) => u !== first), "new public link after drop", kind === "real" ? 90000 : 20000);
    if (lanIPs.size > 1 && !app.joins().slice(app.joins().indexOf(first)).some(isLan)) console.log("  (note: no Wi-Fi fallback URL shown during the gap)");
    step(`[${kind}] tunnel recovered on ${next}`);
    const B = await joinThrough(baseOf(next), slug, "tunnel0002");
    const w = B.last((m) => m.type === "welcome");
    if (!w.questions.some((q: any) => q.original.includes("fuera"))) throw new Error("room state lost across the tunnel restart");
    step(`[${kind}] phone rejoined via the new link, room state intact`);
    return true;
  } finally {
    await app.stop();
  }
}

async function fallbackFlow() {
  const slug = `e2e-off-${Math.floor(Math.random() * 1e6)}`;
  const app = new App(slug, { LALAAI_CLOUDFLARED: FAKE, FAKE_CLOUDFLARED: "unreachable" });
  try {
    await until(() => app.has("public link failed"), "tunnel failure reported");
    const port = await until(() => app.relayPort(), "relay port");
    const room = await (await fetch(`http://127.0.0.1:${port}/api/rooms/${slug}`)).json();
    if (!room.live) throw new Error("app didn't stay live without Cloudflare");
    const lan = app.joins().find(isLan);
    if (lan) {
      await joinThrough(baseOf(lan), slug, "wifi000001");
      step(`Cloudflare unreachable: QR falls back to Wi-Fi (${lan}), phone joined`);
    } else {
      step("Cloudflare unreachable: app stays live on this Mac (no Wi-Fi address here to test the LAN QR)");
    }
    await Bun.sleep(2500); // retries keep failing quietly; the app must not drop the room
    if (!(await (await fetch(`http://127.0.0.1:${port}/api/rooms/${slug}`)).json()).live) throw new Error("room dropped while retrying");
    step("retries keep running without dropping the room");
  } finally {
    await app.stop();
  }
}

try {
  let ran = false;
  if (MODE === "real" || MODE === "auto") ran = await publicLinkFlow("real");
  if (MODE === "real" && !ran) throw new Error("real quick tunnel unavailable");
  if (MODE === "fake" || (MODE === "auto" && !ran)) await publicLinkFlow("fake");
  await fallbackFlow();
  console.log("\nPUBLIC LINK E2E PASSED");
  process.exit(0);
} catch (e) {
  console.error("\nPUBLIC LINK E2E FAILED:", e);
  process.exit(1);
}
