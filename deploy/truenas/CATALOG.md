# Getting Tasks into the TrueNAS catalog

Plan for when the project is public. Until then, `tasks.yaml` in this
folder installs it with *Install via YAML*.

TrueNAS apps live in the [truenas/apps](https://github.com/truenas/apps)
repository. Community apps go under `ix-dev/community/<app>/` and are
contributed by pull request.

## Before submitting

1. Publish the repository (GitHub, GitLab or Codeberg) and tag a release so
   `.github/workflows/release.yml` pushes `linux/amd64` and `linux/arm64`
   images. Replace `OWNER` in `tasks.yaml` and below.
2. Pick the app's final name and icon (the catalog needs a square icon and
   screenshots).
3. Test a fresh install on TrueNAS with *Install via YAML*: setup page,
   remote access through a real router, a phone on mobile data.

## The catalog entry

Copy an existing community app with a similar shape (one container, a
storage volume, host networking) as the starting point, then:

- `app.yaml`: name, description, home page, icon, screenshots, maintainers,
  `run_as_context` (user 568), and the image tag.
- `ix_values.yaml`: `ghcr.io/OWNER/tasks-server` and the release tag.
- `questions.yaml`, the install form. Keep it short:
  - Storage for `/data` (ixVolume by default, or a host path).
  - Host networking on by default, with a note that it's needed for
    automatic remote access.
  - Ports for when host networking is off: 8080 (web/setup) and 8443
    (remote HTTPS).
  - Optional: a custom public address (`PUBLIC_URL`) for people using a
    reverse proxy or Tailscale Funnel.
- `templates/docker-compose.yaml`, rendered with the shared library: the
  service, its volume, `network_mode`, the health check
  (`/app/bin/server --healthcheck`), and the "Web UI" portal link to port
  8080.
- `README.md`: one paragraph and a link to the docs.

Run the repository's own validation and CI before opening the pull request,
and expect review feedback on naming and defaults.
