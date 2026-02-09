#!/usr/bin/env python3
"""Resetter — Docker volume reset/bake utility."""

import logging
import os
import re
import signal
import sys
import threading
import time
from datetime import datetime, timezone

import docker
from croniter import croniter

# ---------------------------------------------------------------------------
# Configuration from environment
# ---------------------------------------------------------------------------
VOLUME_PAIRS = os.environ.get("VOLUME_PAIRS", "")
SERVICES = os.environ.get("SERVICES", "")
CRON_SCHEDULE = os.environ.get("CRON_SCHEDULE", "")
CRON_COMMAND = os.environ.get("CRON_COMMAND", "reset")
LOG_FILE = os.environ.get("LOG_FILE", "/var/log/resetter.log")

ALPINE_IMAGE = "alpine:3.20"

log = logging.getLogger("resetter")


def setup_logging():
    """Configure dual logging: stdout + file."""
    os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
    fmt = logging.Formatter("%(message)s")
    log.setLevel(logging.DEBUG)

    sh = logging.StreamHandler(sys.stdout)
    sh.setFormatter(fmt)
    log.addHandler(sh)

    fh = logging.FileHandler(LOG_FILE)
    fh.setFormatter(fmt)
    log.addHandler(fh)


# ---------------------------------------------------------------------------
# Docker helpers
# ---------------------------------------------------------------------------
client: docker.DockerClient


def _run_alpine(volumes: dict, command: str) -> str:
    """Run a throwaway Alpine container and return stdout."""
    return client.containers.run(
        ALPINE_IMAGE,
        command=["sh", "-lc", command],
        volumes=volumes,
        remove=True,
    ).decode().strip()


def _ensure_volume(name: str):
    """Create volume if it doesn't exist."""
    try:
        client.volumes.get(name)
    except docker.errors.NotFound:
        client.volumes.create(name)


# ---------------------------------------------------------------------------
# Volume prefix auto-detection
# ---------------------------------------------------------------------------
def detect_volume_prefix(first_pair: str) -> tuple[str, str]:
    """Detect volume name prefix (e.g. from Coolify).

    Returns (prefix, separator).  If no prefix found returns ("", "_").
    """
    live_vol = first_pair.split(":")[1]
    live_hyphen = live_vol.replace("_", "-")

    all_volumes = [v.name for v in client.volumes.list()]
    log.debug("[DEBUG] Looking for volume matching: *%s or *%s", live_vol, live_hyphen)
    log.debug("[DEBUG] Searching in volumes: %s", all_volumes[:10])

    found = None
    for pattern in (live_hyphen, live_vol):
        for v in all_volumes:
            if re.search(rf"[_-]{re.escape(pattern)}$", v):
                found = v
                break
        if found:
            break

    if found:
        log.debug("[DEBUG] Found matching volume: %s", found)
        m = re.match(
            r"^(.+)([-_])(postgres-data|postgres_data|tmp-data|tmp_data)$", found
        )
        if m:
            prefix = m.group(1)
            separator = m.group(2)
            log.debug("[DEBUG] Detected prefix: '%s', separator: '%s'", prefix, separator)
            return prefix, separator
        log.debug("[DEBUG] Could not parse prefix from: %s", found)
    else:
        log.debug("[DEBUG] No matching volume found, using volumes as-is")
    return "", "_"


# ---------------------------------------------------------------------------
# Core helpers
# ---------------------------------------------------------------------------
class Resetter:
    def __init__(self, pairs: list[str], services: list[str]):
        self.pairs = pairs
        self.services = services
        prefix_info = detect_volume_prefix(pairs[0])
        self.prefix = prefix_info[0]
        self.separator = prefix_info[1]

    def _vol(self, name: str) -> str:
        """Get full volume name with detected prefix."""
        if self.prefix:
            return f"{self.prefix}_{name.replace('_', '-')}"
        return name

    # -- volume operations --------------------------------------------------

    def volume_is_empty(self, vol: str) -> bool:
        log.debug("[DEBUG] Checking if volume '%s' is empty...", vol)
        try:
            client.volumes.get(vol)
        except docker.errors.NotFound:
            log.debug("[DEBUG]   → Volume does not exist yet, treating as empty")
            return True

        contents = _run_alpine({vol: {"bind": "/v", "mode": "rw"}}, "ls -A /v | head -20")
        log.debug("[DEBUG]   → Contents: %s", contents or "<empty>")
        return contents == ""

    def sync_volume_from_seed(self, seed: str, live: str):
        log.info(">>> RESET: %s ← %s", live, seed)
        _ensure_volume(seed)
        _ensure_volume(live)
        log.debug("[DEBUG] Before sync:")
        log.debug("[DEBUG]   seed (%s): %s", seed, _run_alpine({seed: {"bind": "/v", "mode": "ro"}}, "ls -A /v | head -10"))
        log.debug("[DEBUG]   live (%s): %s", live, _run_alpine({live: {"bind": "/v", "mode": "ro"}}, "ls -A /v | head -10"))

        _run_alpine(
            {seed: {"bind": "/src", "mode": "ro"}, live: {"bind": "/dst", "mode": "rw"}},
            "rm -rf /dst/* /dst/.[!.]* /dst/..?* 2>/dev/null || true; cp -a /src/. /dst/",
        )

        log.debug("[DEBUG] After sync:")
        log.debug("[DEBUG]   live (%s): %s", live, _run_alpine({live: {"bind": "/v", "mode": "ro"}}, "ls -A /v | head -10"))

    def bake_volume_from_live(self, seed: str, live: str):
        log.info(">>> BAKE: %s ← %s", seed, live)
        _ensure_volume(seed)
        _ensure_volume(live)
        log.debug("[DEBUG] Before bake:")
        log.debug("[DEBUG]   live (%s): %s", live, _run_alpine({live: {"bind": "/v", "mode": "ro"}}, "ls -A /v | head -10"))
        log.debug("[DEBUG]   seed (%s): %s", seed, _run_alpine({seed: {"bind": "/v", "mode": "ro"}}, "ls -A /v | head -10"))

        _run_alpine(
            {live: {"bind": "/src", "mode": "ro"}, seed: {"bind": "/dst", "mode": "rw"}},
            "rm -rf /dst/* /dst/.[!.]* /dst/..?* 2>/dev/null || true; cp -a /src/. /dst/",
        )

        log.debug("[DEBUG] After bake:")
        log.debug("[DEBUG]   seed (%s): %s", seed, _run_alpine({seed: {"bind": "/v", "mode": "ro"}}, "ls -A /v | head -10"))

    def ensure_seed_initialized(self, seed: str, live: str):
        log.debug("[DEBUG] Ensuring seed '%s' is initialized...", seed)
        if self.volume_is_empty(seed):
            log.info(">>> SEED EMPTY: %s, baking from %s", seed, live)
            self.bake_volume_from_live(seed, live)
        else:
            log.debug("[DEBUG] Seed '%s' already has data, skipping initialization", seed)

    # -- service management -------------------------------------------------

    def _find_container(self, name: str, include_stopped: bool = False):
        """Find container by exact name or pattern match."""
        filters = {} if include_stopped else {"status": "running"}
        containers = client.containers.list(all=include_stopped, filters=filters)

        # exact match first
        for c in containers:
            if c.name == name:
                return c

        # pattern match
        for c in containers:
            if re.search(name, c.name):
                return c
        return None

    def stop_services(self):
        if not self.services:
            return
        log.info(">>> stopping: %s", " ".join(self.services))
        log.debug("[DEBUG] All running containers:")
        for c in client.containers.list():
            log.debug("  %s", c.name)

        for s in self.services:
            log.debug("[DEBUG] Trying to stop: %s", s)
            container = self._find_container(s, include_stopped=False)
            if container:
                try:
                    container.stop()
                    log.debug("[DEBUG] Stopped container: %s", container.name)
                except Exception as e:
                    log.debug("[DEBUG] Failed to stop %s: %s", container.name, e)
            else:
                log.debug("[DEBUG] No running container found matching: %s", s)

    def start_services(self):
        if not self.services:
            return
        log.info(">>> starting: %s", " ".join(self.services))
        log.debug("[DEBUG] All containers (including stopped):")
        for c in client.containers.list(all=True):
            log.debug("  %s (%s)", c.name, c.status)

        for s in self.services:
            log.debug("[DEBUG] Trying to start: %s", s)
            container = self._find_container(s, include_stopped=True)
            if container:
                try:
                    container.start()
                    log.debug("[DEBUG] Started container: %s", container.name)
                except Exception as e:
                    log.debug("[DEBUG] Failed to start %s: %s", container.name, e)
            else:
                log.debug("[DEBUG] No container found matching: %s", s)

        log.debug("[DEBUG] Final container status:")
        for c in client.containers.list():
            log.debug("  %s (%s)", c.name, c.status)

    def check_and_start_services(self):
        if not self.services:
            return
        log.info(">>> checking services health: %s", " ".join(self.services))
        restarted = 0
        for s in self.services:
            container = self._find_container(s, include_stopped=True)
            if container:
                status = container.status
                log.debug("[DEBUG] Container %s status: %s", container.name, status)
                if status != "running":
                    log.warning("[WARN] Container %s is not running, starting it...", container.name)
                    try:
                        container.start()
                        log.info("[INFO] Successfully started: %s", container.name)
                        restarted += 1
                    except Exception as e:
                        log.error("[ERROR] Failed to start: %s — %s", container.name, e)
            else:
                log.debug("[DEBUG] Container not found for service: %s", s)

        if restarted:
            log.info("[INFO] Restarted %d service(s)", restarted)
        else:
            log.info("[INFO] All services are running")

    # -- main operations ----------------------------------------------------

    def reset_once(self):
        now = datetime.now(timezone.utc).isoformat()
        log.info("=== RESET at %s ===", now)
        log.info("[INFO] Log file: %s", LOG_FILE)

        self.check_and_start_services()

        log.debug("[DEBUG] VOLUME_PAIRS: %s", VOLUME_PAIRS)
        log.debug("[DEBUG] Detected prefix: '%s'", self.prefix or "<none>")
        log.debug("[DEBUG] Parsed pairs:")
        for pair in self.pairs:
            seed_name, live_name = pair.split(":")
            seed = self._vol(seed_name)
            live = self._vol(live_name)
            log.debug("[DEBUG]   - seed: %s → %s", seed_name, seed)
            log.debug("[DEBUG]   - live: %s → %s", live_name, live)

        log.debug("[DEBUG] All Docker volumes:")
        for v in client.volumes.list():
            log.debug("  %s", v.name)

        self.stop_services()

        for pair in self.pairs:
            seed_name, live_name = pair.split(":")
            seed = self._vol(seed_name)
            live = self._vol(live_name)
            self.ensure_seed_initialized(seed, live)
            self.sync_volume_from_seed(seed, live)

        self.start_services()
        log.info("=== done ===")

    def bake_once(self):
        now = datetime.now(timezone.utc).isoformat()
        log.info("=== BAKE at %s ===", now)
        log.info("[INFO] Log file: %s", LOG_FILE)
        log.debug("[DEBUG] Detected prefix: '%s'", self.prefix or "<none>")

        self.stop_services()

        for pair in self.pairs:
            seed_name, live_name = pair.split(":")
            seed = self._vol(seed_name)
            live = self._vol(live_name)
            self.bake_volume_from_live(seed, live)

        self.start_services()
        log.info("=== done ===")


# ---------------------------------------------------------------------------
# Cron scheduler
# ---------------------------------------------------------------------------
_stop_event = threading.Event()


def start_cron(resetter: Resetter):
    """Run the scheduled command using croniter for timing."""
    if not CRON_SCHEDULE:
        log.error("CRON_SCHEDULE is empty")
        sys.exit(1)
    if CRON_COMMAND not in ("reset", "bake"):
        log.error("CRON_COMMAND must be 'reset' or 'bake'")
        sys.exit(1)

    log.info(">>> cron schedule: %s (%s)", CRON_SCHEDULE, CRON_COMMAND)

    job = resetter.reset_once if CRON_COMMAND == "reset" else resetter.bake_once
    cron = croniter(CRON_SCHEDULE)

    def heartbeat():
        while not _stop_event.is_set():
            log.info("[HEARTBEAT] Cron is alive at %s", datetime.now(timezone.utc).isoformat())
            _stop_event.wait(300)  # every 5 minutes

    hb = threading.Thread(target=heartbeat, daemon=True)
    hb.start()

    while not _stop_event.is_set():
        next_run = cron.get_next(float)
        wait = max(0, next_run - time.time())
        log.debug("[DEBUG] Next run in %.0f seconds", wait)
        if _stop_event.wait(wait):
            break
        try:
            job()
        except Exception:
            log.exception("[ERROR] Job failed")

    log.info("Scheduler stopped")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
def main():
    setup_logging()

    if not VOLUME_PAIRS:
        log.error("VOLUME_PAIRS is empty")
        sys.exit(1)

    global client
    client = docker.from_env()

    pairs = [p.strip() for p in VOLUME_PAIRS.split(";") if p.strip()]
    services = SERVICES.split() if SERVICES else []

    resetter = Resetter(pairs, services)

    def handle_signal(sig, _frame):
        log.info("Received signal %s, shutting down...", sig)
        _stop_event.set()

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    cmd = sys.argv[1] if len(sys.argv) > 1 else ""

    if cmd == "reset":
        resetter.reset_once()
    elif cmd == "bake":
        resetter.bake_once()
    elif cmd == "cron":
        start_cron(resetter)
    elif cmd == "":
        if CRON_SCHEDULE:
            start_cron(resetter)
        else:
            print("Usage:")
            print("  reset  # restore seed → live")
            print("  bake   # save live → seed")
            print("  cron   # run on CRON_SCHEDULE")
            sys.exit(1)
    else:
        # Pass through to exec like original bash version
        os.execvp(sys.argv[1], sys.argv[1:])


if __name__ == "__main__":
    main()
