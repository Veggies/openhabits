# OpenHabits server

The server keeps everyone's devices in sync. It's one small container with a
SQLite database, and it serves a setup page where the owner creates accounts,
turns on remote access and adds devices.

## Install

| Where | How |
| --- | --- |
| TrueNAS | Apps → Discover Apps → search for OpenHabits. Before it's in the catalog: ⋮ → *Install via YAML* with [`deploy/truenas/openhabits.yaml`](../../deploy/truenas/openhabits.yaml). |
| Anything with Docker | Download [`deploy/docker-compose.yml`](../../deploy/docker-compose.yml) and run `docker compose up -d`. Works on Linux, Unraid, Synology, a Raspberry Pi and Portainer. |
| Just Docker | `docker run -d --name openhabits --network host -v openhabits-data:/data ghcr.io/veggies/openhabits-server:1` |

Then open `http://<your-server>:8080` and follow the setup page.

The image is published for `linux/amd64` and `linux/arm64`. Tags: `1.2.3`,
`1.2`, `1` and `latest`. Using `1` gets you fixes and new features but never a
release that needs you to change anything.

## Settings

All of these are optional. The setup page covers everything for most people.

| Variable | Default | What it does |
| --- | --- | --- |
| `PORT` | `8080` | Port for the app and the setup page on your home network. |
| `HTTPS_PORT` | `8443` | Secure port devices use away from home. |
| `DB_PATH` | `/data/data.sqlite` | Where the database lives. The certificate is kept next to it. |
| `DIRECTORY_URL` | `https://directory.ryanruddock.com` | Where the server publishes its current address, so devices away from home can find it after your internet address changes (see `services/directory`). Only the address is sent, signed by the server; `off` turns it off. |
| `PUBLIC_URL` | | Only for a reverse proxy or tunnel that has its own certificate (e.g. Tailscale Funnel, Caddy), e.g. `https://habits.example.com`. Setting it turns remote access on; after that, changes made on the setup page (including turning remote access off) stick until the value here changes. |
| `TRUST_PROXY` | `false` | Set to `true` behind a reverse proxy (Caddy, nginx, Traefik) so the server sees visitors' real addresses; it then uses the address your proxy adds to `X-Forwarded-For`. Use `cloudflare` for a Cloudflare tunnel. Either way, the header is only believed when the request comes from this machine or your home network. |
| `SERVER_NAME` | | The name devices show for this server. |
| `OWNER_USERNAME`, `OWNER_PASSWORD` | | Creates the owner account on first start, for installs with no browser step. |

## Networking

With host networking (the default in our Compose file and on TrueNAS), the
server can ask your router to open its remote access port by itself (UPnP).
Docker Desktop on macOS and Windows runs containers in a VM, so there you
publish ports 8080 and 8443 instead and forward 8443 on your router by hand.

### When your internet address changes

Your home's internet address changes from time to time. The server tells the
OpenHabits directory its new address, and a device away from home that can't
reach the old one asks the directory where to go, the way Plex apps ask
plex.tv. The server signs each address it publishes, and devices only use
addresses with its signature, so the directory never has to be trusted.
Nothing to set up.

### Your own domain

If you already run a reverse proxy (Caddy, Traefik, Nginx Proxy Manager) or a
tunnel like Tailscale Funnel, put its address under *Advanced → Reverse
proxy address* on the setup page, or set `PUBLIC_URL`. Devices then use it,
with its normal certificate. It's also the way to go if your provider shares
one address between many homes (CGNAT), where port forwarding can't work.

## Backups

Everything lives in the folder that holds the `DB_PATH` file, which is `/data`
unless you changed `DB_PATH`. That folder has the database, the certificate, and
the signing key devices use to recognise the server, so back up the whole
folder and you've backed up the server.

`/data` is the path inside the container, not on your computer. The server
image has no shell or `sqlite3`, so the commands below run in a small helper
container. `--volumes-from openhabits` gives it the same storage as your server,
at the same paths, so you don't need to know what Docker named the volume. Use
your server's container name if it isn't `openhabits` (`docker ps -a` lists
them). The backup lands in the folder you run the command from.

The backup holds the server's signing key, so the commands make it readable only
by you. Keep it that way, and store it somewhere other people can't read.

Stop the server's container first, then copy the whole folder:

```sh
docker run --rm --volumes-from openhabits -v "$PWD":/backup \
  -e OWNER="$(id -u):$(id -g)" alpine sh -c 'umask 077 &&
  tar czf /backup/openhabits-backup.tgz -C /data . &&
  chown "$OWNER" /backup/openhabits-backup.tgz'
```

A copy taken while the server is writing can leave you with a damaged database.
If you can't stop it, you can copy just the database while it runs:

```sh
docker run --rm --volumes-from openhabits -v "$PWD":/backup \
  -e OWNER="$(id -u):$(id -g)" alpine sh -c 'umask 077 && apk add -q sqlite &&
  sqlite3 /data/data.sqlite ".backup /backup/backup.sqlite" &&
  chown "$OWNER" /backup/backup.sqlite'
```

If you changed `DB_PATH`, use that path in place of `/data/data.sqlite` (and in
the `tar` command, use the folder that holds it in place of `/data`). Check it
first: if the path is wrong, `sqlite3` makes a new empty database and backs that
up without any error. This copies only the database, so also keep a copy of the
certificate and signing key from that folder.

## Restoring a backup

Restoring uses the same helper container as the backup, run from the folder
that holds your backup file. Keep that folder outside the server's data folder,
because the restore clears the data folder first. If you're moving to a new machine, install the
server there first so the `openhabits` container exists, then follow these
steps. Whatever is in its data folder gets replaced.

Stop the server's container first:

```sh
docker stop openhabits
```

To restore a whole-folder backup, clear the data folder and unpack the archive
into it. The command reads the whole archive first and stops without touching
anything if it's missing or damaged:

```sh
docker run --rm --volumes-from openhabits -v "$PWD":/backup alpine \
  sh -c 'tar tzf /backup/openhabits-backup.tgz >/dev/null &&
  find /data -mindepth 1 -delete &&
  tar xzf /backup/openhabits-backup.tgz -C /data'
```

That brings back everything: the database (`data.sqlite`), the certificate
(`remote-cert.pem` and `remote-key.pem`), and the signing key
(`directory-key.pem`).

To restore a database-only backup made while the server was running, copy it
over the database and remove any leftover journal file. This keeps the
certificate and signing key that are already there, so only do it on the same
server, or after restoring those two from a whole-folder backup:

```sh
docker run --rm --volumes-from openhabits -v "$PWD":/backup alpine \
  sh -c 'cp /backup/backup.sqlite /data/data.sqlite &&
  rm -f /data/data.sqlite-journal'
```

If you changed `DB_PATH`, use that path in place of `/data/data.sqlite`, and its
folder in place of `/data`.

Then start the server again:

```sh
docker start openhabits
```

The server is now back to how it was when you made the backup, including who's
signed in. That has a few effects:

- A device that synced after the backup was made notices the server has gone
  back in time and sends it everything it has, which brings back changes made
  since the backup. Open the app first on the device you used most recently,
  then on the others one at a time, and check that your recent changes are
  there.
- A device that signed in after the backup was made will ask you to sign in
  again. That's expected.
- Any device signed out after the backup was made is signed in again. If that
  was because it was lost or someone else had it, change your password in the
  app's settings, which signs out all your other devices. For someone else's
  account, use "Sign out everywhere" in the People section of the setup page.

To check the restore worked, open the setup page at `http://<this-machine>:8080`
and sign in, then open the app on one of your devices and make sure your habits
are there and it syncs. If a device says "A different OpenHabits server
answered", the signing key wasn't restored: stop the container and restore it
from a whole-folder backup.

## Development

From the repository root:

```sh
docker compose up -d --build server   # builds this folder and runs it on :8080
cd apps/server && dart test
```

Releases: push a tag like `v1.0.0` and the `Server` workflow tests the code,
then publishes the image to `ghcr.io/<owner>/openhabits-server`.

## Licence

The server is licensed under the [GNU Affero General Public License v3.0 or
later](LICENSE). The rest of the repository is MIT; see the
[top-level README](../../README.md#licence).
