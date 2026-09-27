const ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

function randomBase62(len: number): string {
  let out = "";
  const buf = new Uint8Array(len * 2);
  while (out.length < len) {
    crypto.getRandomValues(buf);
    for (const b of buf) {
      if (b < 248) out += ALPHABET[b % 62]; // 248 = 62*4 -> no modulo bias
      if (out.length === len) break;
    }
  }
  return out;
}

const memory = new Map<string, string>();

export function storageGet(key: string): string | null {
  try {
    const v = localStorage.getItem(key);
    if (v !== null) return v;
  } catch {
    /* private mode / blocked */
  }
  return memory.get(key) ?? null;
}

export function storageSet(key: string, value: string): void {
  memory.set(key, value);
  try {
    localStorage.setItem(key, value);
  } catch {
    /* fall back to memory */
  }
}

export interface Identity {
  uid: string;
  secret: string;
}

let cached: Identity | null = null;

export function getIdentity(): Identity {
  if (cached) return cached;
  let uid = storageGet("lalaai.uid");
  let secret = storageGet("lalaai.secret");
  if (!uid || uid.length !== 16) {
    uid = randomBase62(16);
    storageSet("lalaai.uid", uid);
  }
  if (!secret || secret.length !== 32) {
    secret = randomBase62(32);
    storageSet("lalaai.secret", secret);
  }
  cached = { uid, secret };
  return cached;
}
