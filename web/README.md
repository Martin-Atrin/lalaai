# web/ — the deployed part

Everything in this folder is what runs on a server. Nothing else in the repo is deployed.

| Path | What |
|---|---|
| `relay/` | Bun WebSocket relay: rooms, per-language fan-out, Q&A, anonymous questions, meet matching. `bun test` runs its tests. |
| `pwa/` | Attendee web app (Vite + Preact). `pnpm build` writes `pwa/dist`, which the relay serves at `/m/<meetup>`. |
| `shared/protocol.ts` | The wire contract. `apps/shared/Protocol.swift` mirrors it for the native apps. |
| `Dockerfile` | Builds the PWA and runs the relay in one image. Build context: this folder. |

## Deploy

With Railway, run this from the repo root:

```bash
railway up web --path-as-root
```

`--path-as-root` makes `web/` the build context; without it Railway uploads the whole repo.

On any Docker host:

```bash
docker build -t lalaai-web . && docker run -p 8787:8787 lalaai-web
```

**Environment variables:**
- `PORT` (default 8787)
- `PUBLIC_URL` (e.g. `https://lalaai.example.com`; otherwise derived from the request headers)
- `STATIC_DIR` (default `pwa/dist`)

Put the service behind HTTPS so attendee phones can install the web app.
