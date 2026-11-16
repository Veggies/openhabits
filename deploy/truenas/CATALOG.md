# Getting OpenHabits into the TrueNAS catalog

TrueNAS apps live in [truenas/apps](https://github.com/truenas/apps).
Community apps go under `ix-dev/community/<app>/` and are added by pull
request. The entry is ready in [`catalog/openhabits`](catalog/openhabits);
it follows the same layout as other community apps (Memos was the model).

Until it's accepted, people can install with *Install via YAML* using
[`openhabits.yaml`](openhabits.yaml).

## What's in the entry

| File | Purpose |
| --- | --- |
| `app.yaml` | Name, description, links, icon, version, which user it runs as. |
| `item.yaml` | Category, icon and tags for the Discover page. |
| `ix_values.yaml` | The image to pull, and fixed values the template uses. |
| `questions.yaml` | The install form: timezone, optional public address, reverse proxy switch, user, host networking (on by default), the two ports, storage, labels, resources. |
| `templates/docker-compose.yaml` | Turns the form into a container, using TrueNAS's shared library. The image is built from `scratch`, so it uses the image's own health check. |
| `templates/test_values/` | Two installs the TrueNAS CI renders and starts: host networking, and bridge networking with published ports. |
| `icon.png` | 512×512 app icon. |

## Before opening the pull request

1. **Make the repository public** and, ideally, rename it to `openhabits`.
   The links in `app.yaml`, `item.yaml` and `README.md` assume
   `github.com/Veggies/openhabits`.
2. **Publish a release:** push a tag like `v0.1.0`. The `Server` workflow
   tests the code and pushes `ghcr.io/veggies/openhabits-server` for amd64
   and arm64. On GitHub, open the package's settings and make it public.
3. **Pin the image** in `ix_values.yaml` to the version and its digest:
   `docker buildx imagetools inspect ghcr.io/veggies/openhabits-server:0.1.0`
   prints the digest; the tag becomes `"0.1.0@sha256:…"`. Make `app_version`
   in `app.yaml` match.
4. **Test a real install** on TrueNAS with *Install via YAML*: setup page,
   remote access through a real router, a phone on mobile data.

## Submitting

```sh
git clone https://github.com/<you>/apps.git && cd apps   # your fork of truenas/apps
cp -r <this repo>/deploy/truenas/catalog/openhabits ix-dev/community/
python3 .github/scripts/ci.py --app openhabits --train community --test-file basic-values.yaml
python3 .github/scripts/ci.py --app openhabits --train community --test-file bridge-values.yaml
```

The CI script renders the template and starts the container, so it catches
form or template mistakes before reviewers do. The icon is moved to
TrueNAS's media host during review; the `icon` links then change to theirs.
Expect feedback on naming and defaults. Note there's already an unrelated
`openhabittracker` app in the catalog, so the description should make the
difference clear.

## After it's in

New server releases need a pull request to bump the image tag, `app_version`
and `version` in the catalog entry. TrueNAS's bot (Renovate) often opens these
automatically once the app is listed.
