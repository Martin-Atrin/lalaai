# web/ — the self-hostable relay

La Laai runs no server of its own. This folder is the relay for people who want to host one; the Mac and iPhone apps embed the same relay (apps/shared/Relay).

| Path | What |
|---|---|
| `relay/` | Bun WebSocket relay: rooms, per-language fan-out, Q&A, anonymous questions, meet matching. `bun test` runs its tests. |
| `pwa/` | Attendee web app (Vite + Preact). `pnpm build` writes `pwa/dist`, which the relay serves at `/m/<meetup>`. |
| `shared/protocol.ts` | The wire contract. `apps/shared/Protocol.swift` mirrors it for the native apps. |
| `Dockerfile` | Builds the PWA and runs the relay in one image. Build context: this folder. |

## Self-hosting

Build the image from `web/` on any Docker host (Fly, Render, a VPS…), put it behind HTTPS and set `PUBLIC_URL`. Presenters enter that URL as **Custom relay**. The Mac and iPhone apps embed the same relay, so this is optional.

On any Docker host:

```bash
docker build -t lalaai-web . && docker run -p 8787:8787 lalaai-web
```

**Environment variables:**
- `PORT` (default 8787)
- `PUBLIC_URL` (e.g. `https://lalaai.example.com`; otherwise derived from the request headers)
- `STATIC_DIR` (default `pwa/dist`)

Put the service behind HTTPS so attendee phones can install the web app.
