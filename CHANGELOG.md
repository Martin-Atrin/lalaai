# Changelog

## Unreleased

- **Public link (Mac):** the Mac hosts the room itself and opens a free Cloudflare quick tunnel, so phones join
  from any network. Nothing to install: `cloudflared` ships inside the app. If Cloudflare is unreachable, phones
  on the same Wi-Fi can still join, and the link is retried; the QR code follows the new link.
- **iPhone hosts on Wi-Fi or Personal Hotspot.** No server needed.
- **La Laai Cloud is gone.** La Laai runs no server of its own. Saved settings move to Public link (Mac) or
  Wi-Fi/hotspot (iPhone). **Custom relay** stays for people who self-host `web/`.
