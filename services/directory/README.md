# OpenHabits directory

An address book for OpenHabits servers, the way plex.tv is for Plex. A home
server's internet address changes from time to time; each server tells the
directory where it can be reached now, and a device away from home that
can't reach the address it knows asks the directory for the current one.

It runs as a Cloudflare Worker and fits easily in the free plan: servers
only write when their address changes (or once a week to stay listed), and
apps only look up after a connection fails.

## What it stores, and why it's safe

- Per server: a random-looking ID and up to four `https://` addresses. No
  names, emails or habits. Entries vanish 45 days after a server stops
  checking in. Turning remote access off empties the entry straight away
  (an empty placeholder is kept so an old update can't be replayed).
- Each server signs its updates with its own key, and its ID is derived from
  that key, so nobody can claim or change another server's entry.
- Lookups hand back the server's own signed update, and devices check that
  signature with the key they learned when they signed in. A wrong or
  hacked directory can make a connection fail, never send it to a different
  server.
- You can only look up an ID you already know, and only paired devices know
  it.

## Deploying

You need a domain on Cloudflare.

```sh
cd services/directory
npx wrangler login
npx wrangler kv namespace create SERVERS   # paste the id into wrangler.toml
# set routes in wrangler.toml to e.g. directory.yourdomain.com
npx wrangler deploy
curl https://directory.yourdomain.com/      # should describe itself
```

Servers use it when `DIRECTORY_URL` points at it (the release builds have
the official one built in). `DIRECTORY_URL=off` turns it off.

## Testing

`npm test` runs the tests with Node 22 or later, no install needed. `npm start`
runs it locally on port 8787 with in-memory storage.
