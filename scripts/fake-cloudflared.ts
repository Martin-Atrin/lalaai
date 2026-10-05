#!/usr/bin/env bun
// Stand-in for `cloudflared tunnel --url http://127.0.0.1:<port>` in e2e tests, for networks that block
// trycloudflare.com. The app uses it when LALAAI_CLOUDFLARED points here.
//   default                      proxies HTTP + WebSocket from a fresh local port to --url and prints a
//                                cloudflared-style banner with http://127.0.0.1:<port> as the "tunnel" URL
//   FAKE_CLOUDFLARED=unreachable prints the error cloudflared prints when Cloudflare can't be reached, then exits 1
const args = process.argv.slice(2);
const target = args[args.indexOf("--url") + 1];
if (!target?.startsWith("http://")) {
  console.error("fake-cloudflared: expected --url http://…");
  process.exit(2);
}
const log = (s: string) => process.stderr.write(`${new Date().toISOString()} INF ${s}\n`);

if (process.env.FAKE_CLOUDFLARED === "unreachable") {
  log("Requesting new quick Tunnel on trycloudflare.com...");
  process.stderr.write(
    `${new Date().toISOString()} ERR Error requesting new quick Tunnel error="Post \\"https://api.trycloudflare.com/tunnel\\": dial tcp: lookup api.trycloudflare.com: no such host"\n`,
  );
  process.exit(1);
}

type Pipe = { path: string; upstream?: WebSocket; queue: (string | Buffer)[] };
const wsTarget = target.replace(/^http/, "ws");

const server = Bun.serve<Pipe, {}>({
  hostname: "127.0.0.1",
  port: 0,
  async fetch(req, srv) {
    const u = new URL(req.url);
    if (req.headers.get("upgrade")?.toLowerCase() === "websocket") {
      return srv.upgrade(req, { data: { path: u.pathname + u.search, queue: [] } }) ? undefined : new Response("upgrade failed", { status: 400 });
    }
    const headers = new Headers(req.headers);
    headers.set("x-forwarded-host", u.host);
    headers.set("x-forwarded-proto", "http");
    const body = req.method === "GET" || req.method === "HEAD" ? undefined : await req.arrayBuffer();
    try {
      return await fetch(target + u.pathname + u.search, { method: req.method, headers, body, redirect: "manual" });
    } catch {
      return new Response("origin unreachable", { status: 502 });
    }
  },
  websocket: {
    open(ws) {
      const up = new WebSocket(wsTarget + ws.data.path);
      ws.data.upstream = up;
      up.onopen = () => { for (const m of ws.data.queue.splice(0)) up.send(m); };
      up.onmessage = (e) => ws.send(e.data as string);
      up.onclose = () => ws.close();
      up.onerror = () => ws.close();
    },
    message(ws, m) {
      const up = ws.data.upstream;
      if (up?.readyState === WebSocket.OPEN) up.send(m);
      else ws.data.queue.push(m);
    },
    close(ws) { ws.data.upstream?.close(); },
  },
});

const url = `http://127.0.0.1:${server.port}`;
log("Requesting new quick Tunnel on trycloudflare.com...");
log("+--------------------------------------------------------------------------------------------+");
log("|  Your quick Tunnel has been created! Visit it at (it may take some time to be reachable):  |");
log(`|  ${url.padEnd(90)}|`);
log("+--------------------------------------------------------------------------------------------+");
process.on("SIGTERM", () => process.exit(0));
// Like a child that loses its parent: don't outlive the app.
const parent = process.ppid;
setInterval(() => { if (process.ppid !== parent) process.exit(0); }, 500);
