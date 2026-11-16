// Runs the directory on this machine for testing, with storage in memory:
//   node local.mjs [port]     (default 8787)
import { createServer } from "node:http";

import worker from "./src/index.js";

const data = new Map();
const SERVERS = {
  async get(key, type) {
    const value = data.get(key);
    return value === undefined ? null : type === "json" ? JSON.parse(value) : value;
  },
  async put(key, value) {
    data.set(key, value);
  },
  async delete(key) {
    data.delete(key);
  },
};

const port = Number(process.argv[2] ?? 8787);
createServer(async (req, res) => {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const body = chunks.length ? Buffer.concat(chunks) : undefined;
  const response = await worker.fetch(
    new Request(`http://localhost:${port}${req.url}`, { method: req.method, headers: req.headers, body }),
    { SERVERS },
  );
  res.writeHead(response.status, Object.fromEntries(response.headers));
  res.end(Buffer.from(await response.arrayBuffer()));
  console.log(req.method, req.url, response.status);
}).listen(port, () => console.log(`Directory on http://localhost:${port}`));
