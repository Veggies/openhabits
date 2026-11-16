// Run with: npm test (in services/directory)
import assert from "node:assert/strict";
import { beforeEach, test } from "node:test";

import worker, { idForKey } from "../src/index.js";

/// Cloudflare KV, in memory. Counts writes, the scarce resource.
class FakeKV {
  data = new Map();
  writes = 0;
  async get(key, type) {
    const value = this.data.get(key);
    return value === undefined ? null : type === "json" ? JSON.parse(value) : value;
  }
  async put(key, value) {
    this.writes++;
    this.data.set(key, value);
  }
  async delete(key) {
    this.data.delete(key);
  }
}

const base64Url = (bytes) =>
  Buffer.from(bytes).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

/// A home server with its own signing key.
async function makeServer() {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, [
    "sign",
    "verify",
  ]);
  const raw = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
  const id = await idForKey(raw);
  return {
    id,
    async update(urls, { ts = Date.now(), forId = id, signer = pair.privateKey } = {}) {
      const payload = JSON.stringify({ id: forId, urls, ts });
      const sig = await crypto.subtle.sign(
        { name: "ECDSA", hash: "SHA-256" },
        signer,
        new TextEncoder().encode(payload),
      );
      return { key: base64Url(raw), payload, sig: base64Url(new Uint8Array(sig)) };
    },
    privateKey: pair.privateKey,
  };
}

let env;
beforeEach(() => {
  env = { SERVERS: new FakeKV() };
});

const call = async (method, id, body) => {
  const response = await worker.fetch(
    new Request(`https://directory.example/v1/servers/${id}`, {
      method,
      body: body === undefined ? undefined : JSON.stringify(body),
    }),
    env,
  );
  return { status: response.status, body: await response.json() };
};

test("a server publishes its address and devices look it up", async () => {
  const server = await makeServer();
  assert.match(server.id, /^[a-z2-7]{26}$/);
  assert.equal((await call("PUT", server.id, await server.update(["https://203.0.113.7:8443"]))).status, 200);
  assert.deepEqual(await call("GET", server.id), {
    status: 200,
    body: { urls: ["https://203.0.113.7:8443"] },
  });
});

test("the address follows the server when it changes", async () => {
  const server = await makeServer();
  await call("PUT", server.id, await server.update(["https://203.0.113.7:8443"], { ts: Date.now() - 1000 }));
  await call("PUT", server.id, await server.update(["https://198.51.100.9:8443"]));
  assert.deepEqual((await call("GET", server.id)).body.urls, ["https://198.51.100.9:8443"]);
});

test("nothing is written when nothing changed", async () => {
  const server = await makeServer();
  await call("PUT", server.id, await server.update(["https://203.0.113.7:8443"], { ts: Date.now() - 1000 }));
  await call("PUT", server.id, await server.update(["https://203.0.113.7:8443"]));
  assert.equal(env.SERVERS.writes, 1);
});

test("nobody else can change a server's entry", async () => {
  const server = await makeServer();
  const intruder = await makeServer();
  await call("PUT", server.id, await server.update(["https://203.0.113.7:8443"], { ts: Date.now() - 1000 }));

  // Their own key, claiming this server's ID.
  const claimed = await intruder.update(["https://evil.example"], { forId: server.id });
  assert.equal((await call("PUT", server.id, claimed)).status, 403);

  // This server's public key, signed by someone else.
  const forged = await server.update(["https://evil.example"], { signer: intruder.privateKey });
  assert.equal((await call("PUT", server.id, forged)).status, 403);

  assert.deepEqual((await call("GET", server.id)).body.urls, ["https://203.0.113.7:8443"]);
});

test("an old update can't be replayed", async () => {
  const server = await makeServer();
  const old = await server.update(["https://203.0.113.7:8443"], { ts: Date.now() - 5000 });
  await call("PUT", server.id, old);
  await call("PUT", server.id, await server.update(["https://198.51.100.9:8443"]));
  assert.equal((await call("PUT", server.id, old)).status, 409);
  const stale = await server.update(["https://203.0.113.7:8443"], { ts: Date.now() - 60 * 60 * 1000 });
  assert.equal((await call("PUT", server.id, stale)).status, 400);
  assert.deepEqual((await call("GET", server.id)).body.urls, ["https://198.51.100.9:8443"]);
});

test("turning remote access off removes the entry", async () => {
  const server = await makeServer();
  await call("PUT", server.id, await server.update(["https://203.0.113.7:8443"], { ts: Date.now() - 1000 }));
  await call("PUT", server.id, await server.update([]));
  assert.equal((await call("GET", server.id)).status, 404);
});

test("only a few https addresses are accepted", async () => {
  const server = await makeServer();
  for (const urls of [
    ["http://203.0.113.7:8080"],
    ["https://203.0.113.7:8443/some/path"],
    ["https://a.example", "https://b.example", "https://c.example", "https://d.example", "https://e.example"],
    ["not a url"],
  ]) {
    assert.equal((await call("PUT", server.id, await server.update(urls))).status, 400, String(urls));
  }
  assert.equal(env.SERVERS.writes, 0);
});

test("unknown IDs and odd paths get a plain no", async () => {
  const server = await makeServer();
  assert.equal((await call("GET", server.id)).status, 404);
  assert.equal((await call("GET", "NOT-AN-ID")).status, 404);
});

test("a rate limit, when configured, is respected", async () => {
  env.LIMITER = { limit: async () => ({ success: false }) };
  const server = await makeServer();
  assert.equal((await call("PUT", server.id, await server.update(["https://203.0.113.7:8443"]))).status, 429);
});
