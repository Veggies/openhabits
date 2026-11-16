// OpenHabits directory: an address book for home servers.
//
// A server's home internet address changes from time to time. Each server
// tells the directory where it can be reached now; when a device away from
// home can't reach the address it knows, it asks the directory for the
// current one. It's the same job plex.tv does for Plex servers.
//
// It never sees anyone's habits, and it doesn't need to be trusted: devices
// still check the server's certificate fingerprint before sending anything,
// so a wrong answer can only fail to connect, never connect somewhere else.
//
// Each server signs its updates with its own key (ECDSA P-256). Its ID is
// derived from that key, so nobody else can claim or change its entry.
//
//   PUT /v1/servers/:id  {key, payload, sig}  payload = '{"id","urls","ts"}'
//   GET /v1/servers/:id  -> {urls}

const MAX_BODY = 2048;
const MAX_URLS = 4;
const MAX_URL_LENGTH = 200;
/// How far a server's clock may drift from ours.
const CLOCK_SKEW_MS = 10 * 60 * 1000;
/// Entries for servers that stop checking in are dropped after this long.
const EXPIRE_SECONDS = 45 * 24 * 60 * 60;
/// An unchanged entry is only rewritten this often, to keep it from expiring.
const REFRESH_MS = 7 * 24 * 60 * 60 * 1000;

export default {
  async fetch(request, env) {
    try {
      return await handle(request, env);
    } catch (e) {
      if (e instanceof Refusal) return json({ error: e.message }, e.status);
      throw e;
    }
  },
};

class Refusal extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

async function handle(request, env) {
  const url = new URL(request.url);
  if (url.pathname === "/") {
    return new Response(
      "OpenHabits directory. Servers publish where they can be reached; " +
        "apps look them up by ID. No habit data passes through here.\n",
      { headers: { "content-type": "text/plain; charset=utf-8" } },
    );
  }
  const match = url.pathname.match(/^\/v1\/servers\/([a-z2-7]{26})$/);
  if (!match) throw new Refusal(404, "Not found.");
  const id = match[1];

  if (request.method === "GET") {
    const entry = await env.SERVERS.get(`s:${id}`, "json");
    if (!entry) throw new Refusal(404, "No server with that ID.");
    return json({ urls: entry.urls });
  }
  if (request.method !== "PUT") throw new Refusal(405, "Use GET or PUT.");

  if (env.LIMITER) {
    const ip = request.headers.get("cf-connecting-ip") ?? "unknown";
    const { success } = await env.LIMITER.limit({ key: ip });
    if (!success) throw new Refusal(429, "Too many updates. Try again later.");
  }

  const text = await request.text();
  if (text.length > MAX_BODY) throw new Refusal(413, "Too large.");
  let body;
  try {
    body = JSON.parse(text);
  } catch {
    throw new Refusal(400, "Not JSON.");
  }
  const { key, payload, sig } = body ?? {};
  if (typeof key !== "string" || typeof payload !== "string" || typeof sig !== "string") {
    throw new Refusal(400, "Expected key, payload and sig.");
  }

  const keyBytes = fromBase64Url(key);
  if (keyBytes.length !== 65 || keyBytes[0] !== 4) {
    throw new Refusal(400, "The key must be an uncompressed P-256 point.");
  }
  if ((await idForKey(keyBytes)) !== id) {
    throw new Refusal(403, "That key doesn't belong to this ID.");
  }
  const publicKey = await crypto.subtle.importKey(
    "raw",
    keyBytes,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["verify"],
  );
  const valid = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    publicKey,
    fromBase64Url(sig),
    new TextEncoder().encode(payload),
  );
  if (!valid) throw new Refusal(403, "The signature doesn't match.");

  let update;
  try {
    update = JSON.parse(payload);
  } catch {
    throw new Refusal(400, "The payload isn't JSON.");
  }
  if (update.id !== id) throw new Refusal(400, "The payload is for another ID.");
  if (!Number.isSafeInteger(update.ts) || Math.abs(update.ts - Date.now()) > CLOCK_SKEW_MS) {
    throw new Refusal(400, "The timestamp is missing or too far from now. Check the server's clock.");
  }
  const urls = update.urls;
  if (!Array.isArray(urls) || urls.length > MAX_URLS || !urls.every(isServerUrl)) {
    throw new Refusal(400, `Give up to ${MAX_URLS} https:// addresses.`);
  }

  const stored = await env.SERVERS.get(`s:${id}`, "json");
  // Older than what we have: a replayed or delayed update.
  if (stored && update.ts <= stored.ts) throw new Refusal(409, "A newer update was already received.");

  if (urls.length === 0) {
    await env.SERVERS.delete(`s:${id}`);
    return json({ ok: true });
  }
  const unchanged =
    stored &&
    JSON.stringify(stored.urls) === JSON.stringify(urls) &&
    update.ts - stored.ts < REFRESH_MS;
  // Writes are the scarce resource (1,000 a day on Cloudflare's free plan),
  // so an update that changes nothing isn't written.
  if (!unchanged) {
    await env.SERVERS.put(`s:${id}`, JSON.stringify({ urls, ts: update.ts }), {
      expirationTtl: EXPIRE_SECONDS,
    });
  }
  return json({ ok: true });
}

function isServerUrl(value) {
  if (typeof value !== "string" || value.length > MAX_URL_LENGTH) return false;
  try {
    const url = new URL(value);
    return url.protocol === "https:" && url.pathname === "/" && !url.search && !url.username;
  } catch {
    return false;
  }
}

/// The ID for a public key: the first 16 bytes of its SHA-256, in lowercase
/// base32 (26 characters). The server computes it the same way.
export async function idForKey(keyBytes) {
  const hash = new Uint8Array(await crypto.subtle.digest("SHA-256", keyBytes));
  return base32(hash.slice(0, 16));
}

function base32(bytes) {
  const alphabet = "abcdefghijklmnopqrstuvwxyz234567";
  let bits = 0;
  let value = 0;
  let out = "";
  for (const byte of bytes) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out += alphabet[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) out += alphabet[(value << (5 - bits)) & 31];
  return out;
}

function fromBase64Url(text) {
  try {
    const b64 = text.replace(/-/g, "+").replace(/_/g, "/");
    return Uint8Array.from(atob(b64 + "=".repeat((4 - (b64.length % 4)) % 4)), (c) =>
      c.charCodeAt(0),
    );
  } catch {
    return new Uint8Array();
  }
}

function json(value, status = 200) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}
