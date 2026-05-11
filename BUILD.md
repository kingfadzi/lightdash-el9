# lightdash-el9 — build & deploy

Prebuilt Lightdash for AlmaLinux 9 / RHEL 9.

Lab cuts a release tarball; on-prem rebuilds the runtime image against the
blessed RHEL UBI 9 + Node 20 base, pulling the same tarball from the GitHub
release.

## Prereqs

**Lab** (this repo's working tree, AlmaLinux 9 + Node 20 + internet):
- `docker`, `pigz`, `gh` (`dnf -y install gh` if missing)
- `GITHUB_API_TOKEN` (or `GH_TOKEN`) with `repo` scope
- `docker login docker.butterflycluster.com`

**On-prem** (RHEL 9):
- `docker compose`
- Reachability to GitHub releases (the runtime image is built locally against the blessed RHEL UBI 9 base — the lab's AlmaLinux-based image is **not** consumed on-prem)
- Pull access to your on-prem registry for the RHEL UBI 9 + Node 20 base image
- A Postgres reachable from the docker host for Lightdash's metadata DB

## Lab — cut a release

```bash
cd <this repo>
LIGHTDASH_VERSION=0.2904.0 ./build/build-release.sh
```

Takes ~5–10 min. Produces:
- GH release `lightdash-0.2904.0-el9` on `kingfadzi/lightdash-el9` with `lightdash-runtime-*.tar.gz`, `SHA256SUMS` — **this is what on-prem consumes**.
- Image `docker.butterflycluster.com/lightdash/lightdash:0.2904.0-el9` pushed to your registry — lab convenience only (AlmaLinux 9 base; not for on-prem).

Useful flags:
```bash
SKIP_PUSH=1     LIGHTDASH_VERSION=0.2904.0 ./build/build-release.sh   # build, no registry push
SKIP_RELEASE=1  LIGHTDASH_VERSION=0.2904.0 ./build/build-release.sh   # build, no GH upload
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
RUNTIME_BASE_IMAGE=registry.onprem.example.com/builder-images/rhel9-node:20
LIGHTDASH_VERSION=0.2904.0
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

Build the runtime image against the blessed RHEL UBI 9 base (curls the
release tarball from GitHub, sha-verifies, extracts to `/usr/app`,
`/usr/bin/prod-entrypoint.sh`, `/usr/bin/dumb-init`), then bring it up:
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

Lab:
```bash
LIGHTDASH_VERSION=0.2905.0 ./build/build-release.sh
```

On-prem:
```bash
sed -i 's/^LIGHTDASH_VERSION=.*/LIGHTDASH_VERSION=0.2905.0/' .env
docker compose build lightdash && docker compose up -d lightdash
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| Container crashloop with `knex` migration errors | Check `PGHOST/PGUSER/PGPASSWORD/PGDATABASE` and that the DB exists. Migrations need write access. |
| `pull access denied for local/lightdash` warning | Cosmetic. `docker compose up` tries pull before falling back to build. Run `docker compose build lightdash` first to silence it. |
| `Repository is empty` from `gh release create` | Script auto-seeds with a README if `AUTO_INIT_REPO=1` (default). Re-run. |
| Runtime image build hits HTTP 404 on tarball | Release didn't publish — check `gh release view lightdash-${LIGHTDASH_VERSION}-el9 --repo kingfadzi/lightdash-el9`. |
| `pnpm: command not found` at startup | `corepack enable && corepack prepare pnpm@${PNPM_VERSION} --activate` failed at image-build time. Most likely your RHEL UBI 9 + Node 20 base lacks corepack — pin a base that has Node 20.x with corepack, or `npm i -g pnpm@${PNPM_VERSION}` instead. |

## File map

| Path | Used by | Notes |
|---|---|---|
| `Dockerfile` | lab | Passthrough from `lightdash/lightdash:${LIGHTDASH_VERSION}` — exposes the upstream image for `build-release.sh` to extract. |
| `Dockerfile.runtime` | lab + on-prem | EL9 base + dnf runtime libs + corepack pnpm + curl tarball from GH release + sha-verify. |
| `build/build-release.sh` | lab | Orchestrates build → GH release → registry push. |
| `docker-compose.yml` | lab + on-prem | Service definition. |
| `.env.example` | each environment | Template; `.env` is per-environment and not committed. |
| `vendor/` | optional offline | Reserved for future offline-tarball support. |
