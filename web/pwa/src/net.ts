import type { AttendeeToRelay, RelayToAttendee, RoomInfo } from "@shared/protocol";
import type { Identity } from "./identity";

export type ConnStatus = "connecting" | "open" | "reconnecting" | "closed";

export interface Link {
  send(msg: AttendeeToRelay): void;
  close(): void;
}

export interface LinkHandlers {
  onMessage(msg: RelayToAttendee): void;
  onStatus(status: ConnStatus): void;
}

export type RoomResult = { kind: "ok"; room: RoomInfo } | { kind: "notfound" } | { kind: "error" };

export async function fetchRoom(slug: string): Promise<RoomResult> {
  try {
    const res = await fetch(`/api/rooms/${encodeURIComponent(slug)}`, { headers: { accept: "application/json" } });
    if (res.status === 404) return { kind: "notfound" };
    if (!res.ok) return { kind: "error" };
    const room = (await res.json()) as RoomInfo;
    if (!room || typeof room.slug !== "string") return { kind: "error" };
    return { kind: "ok", room };
  } catch {
    return { kind: "error" };
  }
}

const PING_MS = 20_000;
const MAX_BACKOFF_MS = 15_000;

/** Real relay WebSocket with reconnect + backoff, keepalive ping and an outbox while offline. */
export function openSocket(slug: string, id: Identity, h: LinkHandlers): Link {
  let ws: WebSocket | null = null;
  let attempt = 0;
  let closed = false;
  let pingTimer: ReturnType<typeof setInterval> | undefined;
  let retryTimer: ReturnType<typeof setTimeout> | undefined;
  const outbox: AttendeeToRelay[] = [];

  const url = () => {
    const proto = location.protocol === "https:" ? "wss:" : "ws:";
    const q = new URLSearchParams({ room: slug, role: "attendee", uid: id.uid, secret: id.secret });
    return `${proto}//${location.host}/ws?${q.toString()}`;
  };

  const connect = () => {
    if (closed) return;
    clearTimeout(retryTimer);
    h.onStatus(attempt === 0 ? "connecting" : "reconnecting");
    let sock: WebSocket;
    try {
      sock = new WebSocket(url());
    } catch {
      scheduleRetry();
      return;
    }
    ws = sock;
    sock.onopen = () => {
      attempt = 0;
      h.onStatus("open");
      while (outbox.length && sock.readyState === WebSocket.OPEN) sock.send(JSON.stringify(outbox.shift()));
      clearInterval(pingTimer);
      pingTimer = setInterval(() => {
        if (sock.readyState === WebSocket.OPEN) sock.send(JSON.stringify({ type: "ping" }));
      }, PING_MS);
    };
    sock.onmessage = (ev) => {
      if (typeof ev.data !== "string") return;
      let msg: RelayToAttendee;
      try {
        msg = JSON.parse(ev.data);
      } catch {
        return;
      }
      if (msg && typeof msg.type === "string") h.onMessage(msg);
    };
    sock.onclose = () => {
      clearInterval(pingTimer);
      if (ws === sock) ws = null;
      if (!closed) scheduleRetry();
    };
    sock.onerror = () => {
      try {
        sock.close();
      } catch {
        /* ignore */
      }
    };
  };

  const scheduleRetry = () => {
    attempt++;
    h.onStatus("reconnecting");
    const base = Math.min(MAX_BACKOFF_MS, 500 * 2 ** Math.min(attempt, 6));
    const delay = base / 2 + Math.random() * (base / 2);
    retryTimer = setTimeout(connect, delay);
  };

  // Snap back quickly when the phone wakes up or regains network.
  const kick = () => {
    if (closed || ws) return;
    if (document.visibilityState === "visible" || navigator.onLine) {
      attempt = Math.min(attempt, 1);
      connect();
    }
  };
  const onVisible = () => document.visibilityState === "visible" && kick();
  document.addEventListener("visibilitychange", onVisible);
  window.addEventListener("online", kick);

  connect();

  return {
    send(msg) {
      if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(msg));
      else if (msg.type !== "ping") {
        outbox.push(msg);
        if (outbox.length > 50) outbox.shift();
      }
    },
    close() {
      closed = true;
      clearInterval(pingTimer);
      clearTimeout(retryTimer);
      document.removeEventListener("visibilitychange", onVisible);
      window.removeEventListener("online", kick);
      ws?.close();
      h.onStatus("closed");
    },
  };
}
