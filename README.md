# Resetter

A small Docker utility that resets live volumes from seed volumes (or bakes seeds from live data)
and optionally stops/starts services around the operation. It runs as a container and talks to
the Docker daemon via the Docker socket.

## Features

- Reset one or more volumes from seeded snapshots.
- Bake (snapshot) live volumes back into seed volumes.
- Stop/start named containers to keep data consistent.
- Creates volumes if they do not exist.

## Requirements

- Docker Engine available on the host.
- Access to `/var/run/docker.sock` for the container.

## Usage

### Environment variables

- `VOLUME_PAIRS` (required): `seed:live;seed2:live2`
- `SERVICES` (optional): space-separated container names to stop/start.
- `CRON_SCHEDULE` (optional): cron schedule, enables periodic runs.
- `CRON_COMMAND` (optional): `reset` or `bake` (default: `reset`).

### Commands

- `reset` — restore seed → live
- `bake` — save live → seed
- `cron` — run on `CRON_SCHEDULE`

### Examples

Run once with `docker run`:

```bash
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e VOLUME_PAIRS="postgres_seed:postgres_data;modules_seed:modules_data" \
  -e SERVICES="restoapp postgres" \
  ghcr.io/<owner>/<repo> reset
```

Bake seeds from live data:

```bash
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e VOLUME_PAIRS="postgres_seed:postgres_data" \
  ghcr.io/<owner>/<repo> bake
```

Using `docker-compose` (see `docker-compose.yml`):

```bash
docker compose up -d
docker compose run --rm resetter reset
```

Scheduled runs with cron (example: every day at 04:00):

```bash
docker run -d \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e VOLUME_PAIRS="postgres_seed:postgres_data" \
  -e CRON_SCHEDULE="0 4 * * *" \
  ghcr.io/<owner>/<repo>
```

## Local build

```bash
docker build -t resetter ./resetter
```

## Image publishing

The GitHub Action publishes images to `ghcr.io/<owner>/<repo>` on pushes to the default branch
and on tags.
