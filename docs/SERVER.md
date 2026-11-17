# Setting up the OpenHabits server

The image is `ghcr.io/veggies/openhabits-server` (Intel and ARM). Pick whichever fits what you run:

- **TrueNAS:** until OpenHabits is in the catalog, go to *Apps → Discover Apps → ⋮ → Install via YAML* and paste [`deploy/truenas/openhabits.yaml`](../deploy/truenas/openhabits.yaml). It creates its data folder and sets its permissions itself; change the folder at the top if you like.
- **Unraid:** add [`deploy/unraid/openhabits.xml`](../deploy/unraid/openhabits.xml) as a template (*Docker → Add Container → Template*), or wait for it in Community Apps.
- **Synology, QNAP, Portainer, or any machine with Docker:** download [`deploy/docker-compose.yml`](../deploy/docker-compose.yml) and run `docker compose up -d` (or paste it into your NAS's "Project" or "Stack" page). It pulls the ready-made image, so there's nothing to build.
- **From source:** `docker compose up -d --build` in the repository's top folder.

[`apps/server/README.md`](../apps/server/README.md) lists every setting.

Then open `http://<your-server>:8080` in a browser. The setup page asks you to create your account, and afterwards is where the owner manages the server.

**Remote access.** On the setup page, turn on *Remote access*. The server asks your router to open a port (UPnP), checks it can be reached, and secures the connection with its own certificate, which devices learn to trust when they're signed in. Nothing extra is installed on phones or computers. If your home's internet address changes, devices find the new one through the OpenHabits directory.

- If your router doesn't respond, the page explains how to forward the port by hand.
- If your internet provider shares one address between customers (CGNAT), nothing outside can connect in directly. The page says so and points you to a relay such as Tailscale Funnel, installed on the server only.
- Already have a domain or reverse proxy? Enter it as the reverse proxy address.

**Signing in.** Each person has their own account and private data; the owner adds people on the setup page. A new device signs in with the server address and a password, or by scanning the QR code from *Add a device* (on the setup page or in the app's Settings), which also teaches it the remote address.
