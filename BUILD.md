# lightdash-el9 — build & deploy

Prebuilt Lightdash for AlmaLinux 9 / RHEL 9.

Lab cuts a release tarball; on-prem rebuilds the runtime image against a
**bare RHEL UBI 9** image, pulling the same tarball from the GitHub release.
`Dockerfile.runtime` installs Node 20 itself from the EL9 AppStream module —
the base image does NOT need Node preinstalled.

> **Pinned to Lightdash `0.2540.0` + Node `20`.**
> Upstream uses Node 20.x. Newer Lightdash versions (≥ 0.2550) bundle
> duckdb 1.x which requires `GLIBCXX_3.4.30`+; EL9 ships glibc 2.34 with
> `GLIBCXX_3.4.29` so they will not boot. Node 22 also breaks the bundled
> `lz4` native bindings. Do not change either knob without re-running the
> smoke test.

## Prereqs

**Lab** (this repo's working tree, AlmaLinux 9 + internet):
- `docker`, `pigz`, `gh` (`dnf -y install gh` if missing)
- `GITHUB_API_TOKEN` (or `GH_TOKEN`) with `repo` scope
- `docker login docker.butterflycluster.com`

**On-prem** (RHEL 9):
- `docker compose`
- Reachability to GitHub releases (the runtime image is built locally)
- Pull access to a bare **RHEL UBI 9** image in your on-prem registry
  (e.g. `registry.onprem.example.com/ubi9/ubi:latest`) — Node 20 is
  installed during build from the EL9 AppStream module
- A Postgres reachable from the docker host for Lightdash's metadata DB

## Lab — cut a release

```bash
cd <this repo>
LIGHTDASH_VERSION=0.2540.0 ./build/build-release.sh
```

Takes ~5–10 min. Produces:
- GH release `lightdash-0.2540.0-el9` on `kingfadzi/lightdash-el9` with `lightdash-runtime-*.tar.gz`, `SHA256SUMS` — **this is what on-prem consumes**.
- Image `docker.butterflycluster.com/lightdash/lightdash:0.2540.0-el9` pushed to your registry — lab convenience only (AlmaLinux 9 base; not for on-prem).

Useful flags:
```bash
SKIP_PUSH=1     LIGHTDASH_VERSION=0.2540.0 ./build/build-release.sh   # build, no registry push
SKIP_RELEASE=1  LIGHTDASH_VERSION=0.2540.0 ./build/build-release.sh   # build, no GH upload
```

## On-prem — first-time setup

```bash
git clone https://github.com/kingfadzi/lightdash-el9.git
cd lightdash-el9
cp .env.example .env
$EDITOR .env
```

Edit `.env`:
```ini
RUNTIME_BASE_IMAGE=registry.onprem.example.com/ubi9/ubi:latest
LIGHTDASH_VERSION=0.2540.0
RELEASE_BASE_URL=https://github.com/kingfadzi/lightdash-el9/releases/download

SITE_URL=https://lightdash.onprem.example.com
PORT=8080
NODE_ENV=production
LIGHTDASH_SECRET=$(openssl rand -hex 32)   # paste real value

# Lightdash's own metadata DB (separate from your data warehouses)
PGHOST=db.onprem.internal
PGPORT=5432
PGDATABASE=lightdash
PGUSER=lightdash
PGPASSWORD=...
```

Create the metadata DB once on your Postgres:
```bash
psql -h db.onprem.internal -U postgres -c "CREATE DATABASE lightdash;"
```

## On-prem — start lightdash

Build the runtime image against bare RHEL UBI 9 (installs Node 20 from EL9
AppStream, curls the release tarball from GitHub, sha-verifies, extracts to
`/usr/app`, `/usr/bin/prod-entrypoint.sh`, `/usr/bin/dumb-init`), then
bring it up:
```bash
docker compose build lightdash
docker compose up -d lightdash
```

`prod-entrypoint.sh` runs `pnpm -F backend migrate-production` on every start
(idempotent — knex tracks applied migrations in the metadata DB).

**Verify**:
```bash
docker compose ps
docker compose logs --tail=40 lightdash
curl -sI http://localhost:8080/        # 200 (or 302 to login)
curl -s  http://localhost:8080/api/v1/health
```

Open the playground at the configured `SITE_URL`.

## Bump lightdash version

**Read the pin note at the top first.** `0.2540.0` is the highest version
that boots on EL9 today. Bumping past it requires either a newer libstdc++
on EL9 (not currently available) or a libstdc++ shim baked into the runtime
image. Smoke-test any candidate version against EL9 + Node 20 before pinning.

Lab:
```bash
LIGHTDASH_VERSION=<new-version> ./build/build-release.sh
```

On-prem:
```bash
sed -i "s/^LIGHTDASH_VERSION=.*/LIGHTDASH_VERSION=<new-version>/" .env
docker compose build lightdash && docker compose up -d lightdash
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| Container crashloop with `knex` migration errors | Check `PGHOST/PGUSER/PGPASSWORD/PGDATABASE` and that the DB exists. Migrations need write access. |
| `pull access denied for local/lightdash` warning | Cosmetic. `docker compose up` tries pull before falling back to build. Run `docker compose build lightdash` first to silence it. |
| `Repository is empty` from `gh release create` | Script auto-seeds with a README if `AUTO_INIT_REPO=1` (default). Re-run. |
| Runtime image build hits HTTP 404 on tarball | Release didn't publish — check `gh release view lightdash-${LIGHTDASH_VERSION}-el9 --repo kingfadzi/lightdash-el9`. |
| `pnpm: command not found` at startup | `npm install -g pnpm@${PNPM_VERSION}` failed at image-build time. Check that the build had network access to npmjs.org (or set `HTTPS_PROXY` build-arg). |

## File map

| Path | Used by | Notes |
|---|---|---|
| `Dockerfile` | lab | Passthrough from `lightdash/lightdash:${LIGHTDASH_VERSION}` — exposes the upstream image for `build-release.sh` to extract. |
| `Dockerfile.runtime` | lab + on-prem | bare EL9 base + dnf install nodejs:20 + npm-install pnpm + curl tarball from GH release + sha-verify. |
| `build/build-release.sh` | lab | Orchestrates build → GH release → registry push. |
| `docker-compose.yml` | lab + on-prem | Service definition. |
| `.env.example` | each environment | Template; `.env` is per-environment and not committed. |
| `vendor/` | optional offline | Reserved for future offline-tarball support. |
