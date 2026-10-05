# Provenance of code copied from JoinInter

| La Laai path | Source (JoinInter repo) | Commit |
|---|---|---|
| `apps/macos/Sources/lalaai/Link/QuickTunnel.swift` | `apps/macos/Sources/joininter/Link/QuickTunnel.swift` | `54bf6b1dc6ffaf6e2188fa285d413d9b4c690c3b` |
| `apps/macos/scripts/fetch-cloudflared.sh` | `apps/macos/scripts/fetch-cloudflared.sh` | `54bf6b1` |
| cloudflared steps in `apps/macos/build-app.sh` | `apps/macos/build-app.sh` | `54bf6b1` |
| `apps/shared/Relay/*` | `apps/shared/Relay/*` | `20cb501` (first Swift port of the Bun relay), plus the `EmbeddedRelay.swift` relisten hunk of `145f333` |
| `apps/macos/Sources/lalaai-relay/main.swift` | `apps/macos/Sources/joininter-relay/main.swift` | `20cb501` |

Local changes: names, no named (branded) tunnels, `LALAAI_CLOUDFLARED` test hook, tunnel URL parsing ignores
`api.trycloudflare.com`, ad-hoc local signing.

## Third-party: cloudflared

`cloudflared` 2026.9.3 by Cloudflare, Apache License 2.0, ships unmodified (re-signed) in
`La Laai.app/Contents/Helpers`. Licence: `apps/macos/Resources/licenses/cloudflared-LICENSE.txt`, also bundled at
`Contents/Resources/Licenses/`. The build verifies the archive digest, the binary checksum and Cloudflare's
signature (team 68WVV388M8).
