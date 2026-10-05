# web/ — the deployed part

Everything in this folder is what runs on a server. Nothing else in the repo is deployed.

| Path | What |
|---|---|
| `relay/` | Bun WebSocket relay: rooms, per-language fan-out, Q&A, anonymous questions, meet matching. `bun test` runs its tests. |
| `pwa/` | Attendee web app (Vite + Preact). `pnpm build` writes `pwa/dist`, which the relay serves at `/m/<meetup>`. |
| `shared/protocol.ts` | The wire contract. `apps/shared/Protocol.swift` mirrors it for the native apps. |
| `Dockerfile` | Builds the PWA and runs the relay in one image. Build context: this folder. |

## Run it yourself

This is the self-hostable relay for La Laai: there is no hosted La Laai relay. One Docker image runs the relay and serves the attendee app.

On any Docker host:

```bash
docker build -t lalaai-relay . && docker run -p 8787:8787 lalaai-relay
```

Put it behind HTTPS (Caddy, nginx, or your platform's TLS) so phones can reach it from anywhere. On a container platform, deploy this folder with its Dockerfile using your own account. On Railway, run this from the repo root (`--path-as-root` makes `web/` the build context):

```bash
railway up web --path-as-root
```

No server: run `bun relay/src/server.ts` on the presenter's Mac and expose it with `cloudflared tunnel --url http://localhost:8787`.

**Environment variables:**
- `PORT` (default 8787)
- `PUBLIC_URL` (e.g. `https://lalaai.example.com`; otherwise derived from the request headers)
- `STATIC_DIR` (default `pwa/dist`)

Put the service behind HTTPS so attendee phones can install the web app.
