# OpenHabits server

The server keeps everyone's devices in sync. It's one small container with a
SQLite database, and it serves a setup page where the owner creates accounts,
turns on remote access and adds devices.

## Install

| Where | How |
| --- | --- |
| TrueNAS | Apps → Discover Apps → search for OpenHabits. Before it's in the catalog: ⋮ → *Install via YAML* with [`deploy/truenas/openhabits.yaml`](../../deploy/truenas/openhabits.yaml). |
| Anything with Docker | Download [`deploy/docker-compose.yml`](../../deploy/docker-compose.yml) and run `docker compose up -d`. Works on Linux, Unraid, Synology, a Raspberry Pi and Portainer. |
| Just Docker | `docker run -d --network host -v openhabits-data:/data ghcr.io/veggies/openhabits-server:1` |

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
| `PUBLIC_URL` | | Only for a reverse proxy or tunnel that has its own certificate (e.g. Tailscale Funnel, Caddy), e.g. `https://habits.example.com`. Setting it turns remote access on. |
| `TRUST_PROXY` | `false` | Set to `true` behind a reverse proxy so the server sees visitors' real addresses. |
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
plex.tv. Devices still check the server's certificate, so the directory never
has to be trusted. Nothing to set up.

### Your own domain

If you already run a reverse proxy (Caddy, Traefik, Nginx Proxy Manager) or a
tunnel like Tailscale Funnel, put its address under *Advanced → Reverse
proxy address* on the setup page, or set `PUBLIC_URL`. Devices then use it,
with its normal certificate. It's also the way to go if your provider shares
one address between many homes (CGNAT), where port forwarding can't work.

## Backups

Everything lives in the `/data` folder: back it up and you've backed up the
server. Stop the container first, or copy `data.sqlite` with
`sqlite3 data.sqlite ".backup backup.sqlite"` while it runs.

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
