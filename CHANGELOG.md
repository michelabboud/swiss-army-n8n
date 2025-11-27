# Changelog

All notable changes to this project will be documented in this file.  
This project follows a loose semantic-style versioning for the **control script** and stack definition.

---
## [0.1.3] – 2025-11-27

### Added

- `N8N_SERVICES.md` cheatsheet describing how to address every stack service from n8n (host/port map, credentials, and example workflow chains per service).

## [0.1.2] – 2025-11-27

### Changed

- All persistent services now bind-mount into `./data/...` instead of Docker-managed named volumes to make state explicit and easy to back up.
- Queue and image services switched away from Bitnami/Docker Hub tags that failed to resolve; Kafka/ZooKeeper now use Confluent images and Thumbor moves to GHCR, Loki pinned to `grafana/loki:2.9.8`.
- Keycloak image pinned to `keycloak/keycloak:24.0.5` to avoid Quay pull issues.

### Removed

- Unused named volume declarations at the bottom of `docker-compose.yml` (replaced by host binds).

## [0.1.1] – 2025-11-27

### Changed

- **`stackctl.sh` now echoes the exact commands it runs**

  - Every `docker compose` invocation now prints a fully assembled command line before execution, for example:

    ```text
    [stackctl][CMD] docker compose -f docker-compose.yml -p swiss-army-stack --profile core --profile images up -d
    ```

  - This applies to all commands that use `docker compose`, including:
    - `start`
    - `restart`
    - `stop`
    - `rebuild`
    - `clean`
    - `logs`
    - `info`
    - `status`
    - `health`

  - This makes it easy to:
    - Copy/paste commands to debug manually.
    - See exactly which profiles and project name are being used.
    - Sanity-check behavior when you pass extra args via `--`.

- **`shell` command now prints the exact `docker exec` command**

  - Before dropping you into a container shell, `stackctl` prints the resolved `docker exec` invocation, e.g.:

    ```text
    [stackctl][CMD] docker exec -it <container-id> bash
    ```

  - The script now:
    - Probes for `bash` inside the container using `docker exec "$cid" bash -lc 'exit 0'`.
    - Falls back to `sh` automatically if `bash` is not present.
    - Logs which shell it chose with the `[stackctl][CMD]` line.

- **`SCRIPT_VERSION` bumped from `0.1.0` to `0.1.1`**

  - Reflects the behavioral change (user-visible output) without altering the command-line API.
  - Version is shown via `./stackctl.sh --version` and in `README.md`.

---

## [0.1.0] – 2025-11-27

Initial “Swiss Army Stack” creation.

### Added – Core orchestration and stack definition

- **Monster `docker-compose.yml`**

  Introduced a large, profile-driven Docker Compose stack designed as a backend lab with n8n at the center, including:

  - **Orchestrator**
    - `n8n`:
      - Uses Postgres as its primary DB.
      - Has timezone set to `Asia/Jerusalem`.
      - Basic auth enabled for UI access (`N8N_BASIC_AUTH_*`).
      - Telemetry & hiring banner disabled for a clean local dev experience.
      - Encryption key configured (`N8N_ENCRYPTION_KEY`) to ensure stored credentials are encrypted at rest.

  - **Databases**
    - `postgres`:
      - Primary relational DB (used by n8n and available to other tools).
      - Persistent storage via a named volume (`postgres_data`).
    - `mongo`:
      - General-purpose document store (for JSON / semi-structured data).
      - Uses `mongo_data` volume.
    - `redis`:
      - In-memory cache and state store.
      - Configured with `appendonly yes` to keep data across restarts.
      - Uses `redis_data` volume.

  - **Queues / messaging**
    - `zookeeper` + `kafka`:
      - Single-broker Kafka setup using Bitnami images.
      - `ALLOW_PLAINTEXT_LISTENER=yes` for low-friction local dev.
      - Intended as an event backbone for experimentation.

  - **Email / notifications**
    - `mailhog`:
      - SMTP sink for dev/testing (captured mail via web UI).
      - Exposed on:
        - SMTP: `1025`
        - UI: `8025`
    - `gotify`:
      - Self-hosted notification server.
      - Default user password set via `GOTIFY_DEFAULTUSER_PASS`.
      - Uses `gotify_data` volume.
    - `ntfy`:
      - HTTP-based push notification server.
      - Exposed on `8090`.
      - Uses `ntfy_data` volume.

  - **File & object storage**
    - `minio`:
      - S3-compatible object storage.
      - Exposes:
        - API: `9000`
        - Console: `9001`
      - Root credentials (`MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD`) for local dev (not suitable for production).
      - Uses `minio_data` volume.
    - `sftp`:
      - SFTP server via `atmoz/sftp`.
      - Single dev user `dev` with password `devpass`.
      - Home directory bind-mounted from `./data/sftp/dev`.
      - External port `2222` mapped to container’s `22`.

  - **Image processing**
    - `imagor`:
      - HTTP image transformation proxy.
      - Runs on internal port `8000`, mapped as `8001` on the host.
      - `IMAGOR_UNSAFE=1` for unsigned URL operation in local dev.
    - `imgproxy`:
      - High-performance image resizer/converter.
      - Container port `8080`, mapped as `8002`.
    - `thumbor`:
      - Classic image processing server.
      - Container port `8000`, mapped as `8003`.
    - `rembg`:
      - Background removal server.
      - Runs via `rembg s --host 0.0.0.0 --port 7000`.
      - Mapped as `8004:7000`.

  - **Video / audio**
    - `ffmpeg-api` (placeholder):
      - Build context: `./ffmpeg-api`.
      - Intended as a custom HTTP wrapper around `ffmpeg` for:
        - Transcoding
        - Thumbnail generation
        - Audio extraction
      - Exposed on `9002`.
    - `tdarr`:
      - Automated media transcoding & normalization.
      - Uses named volumes for:
        - `tdarr_server`
        - `tdarr_configs`
        - `tdarr_logs`
      - Host bind mounts for:
        - `./data/tdarr/media`
        - `./data/tdarr/temp`
      - Web UI on `8265`, server port `8266`.
    - `whisper-api` (placeholder):
      - Build context: `./whisper-api`.
      - Intended as an HTTP wrapper around Whisper STT.
      - Exposed on `9003`.

  - **Search / analytics**
    - `elasticsearch`:
      - Single-node dev mode with `xpack.security.enabled=false`.
      - JVM heap tuned via `ES_JAVA_OPTS=-Xms512m -Xmx512m`.
      - HTTP on `9200`.
      - Persistent data in `es_data` volume.
    - `meilisearch`:
      - Lightweight, fast search engine.
      - `MEILI_NO_ANALYTICS=true` for a clean local setup.
      - Port `7700`.
      - Uses `meili_data` volume.
    - `clickhouse`:
      - Columnar analytics database.
      - **Important design change**: only HTTP port `8123` exposed to avoid conflict with MinIO’s use of `9000`.
      - Persistent data in `clickhouse_data`.

  - **Auth / identity**
    - `keycloak`:
      - Running in `start-dev` mode.
      - Admin user set via:
        - `KEYCLOAK_ADMIN=admin`
        - `KEYCLOAK_ADMIN_PASSWORD=admin`
      - UI / HTTP on `8082`.

  - **Monitoring / observability**
    - `prometheus`:
      - Exposed on `9090`.
      - Started with default config; expecting a future `prometheus.yml` mount to define scrape targets.
    - `grafana`:
      - Exposed on `3000`.
      - Uses `grafana_data` volume for dashboards, data sources, etc.
    - `loki`:
      - Log aggregation backend using `local-config.yaml`.
      - Exposed on `3100`.
    - `uptime-kuma`:
      - Uptime/health monitoring dashboard.
      - Exposed on `3001`.
      - Uses `uptime_kuma_data` volume.
      - Docker socket mounted (`/var/run/docker.sock`) to allow container-level monitoring and auto-discovery.

  - **AI / LLM helpers**
    - `ollama`:
      - Local LLM server.
      - Exposed on `11434`.
      - Data in `ollama_data` volume.
    - `qdrant`:
      - Vector DB for embeddings.
      - Exposed on `6333`.
      - Storage in `qdrant_data`.
    - `weaviate`:
      - Semantic vector store / knowledge graph.
      - Anonymous auth enabled for fast experimentation.
      - HTTP on `8081`, gRPC on `50051`.
      - Data in `weaviate_data`.

### Added – Profiles for selective startup

- Introduced **Compose profiles** to avoid running everything at once:

  - `core` – n8n, Postgres, MongoDB, Redis.
  - `queue` – Kafka + ZooKeeper.
  - `email` – MailHog, Gotify, ntfy.
  - `storage` – MinIO, SFTP.
  - `images` – Imagor, imgproxy, Thumbor, rembg.
  - `video` – ffmpeg-api, Tdarr, whisper-api.
  - `search` – Elasticsearch, Meilisearch, ClickHouse.
  - `auth` – Keycloak.
  - `monitoring` – Prometheus, Grafana, Loki, Uptime Kuma.
  - `ai` – Ollama, Qdrant, Weaviate.

- This enables commands like:

  - `./stackctl.sh start --profile core`
  - `./stackctl.sh start --profile core --profile ai`
  - `./stackctl.sh start --profile core --profile images --profile storage`

### Added – `stackctl.sh` control script (v0.1.0)

Initial implementation of a **Swiss-army control script** for Docker Compose, with:

- Supported commands:
  - `start`   – `docker compose up -d` with optional services/profiles.
  - `restart` – `docker compose restart`.
  - `stop`    – `docker compose stop`.
  - `rebuild` – `docker compose up --build -d`.
  - `clean`   – safe tear-down, with prompts:
    - In `--service` mode: runs `docker compose rm -f` for selected services.
    - In `--all` mode: `docker compose down --remove-orphans`, optionally `--volumes` after explicit confirmation.
  - `logs`    – `docker compose logs` with optional extra flags.
  - `shell`   – interactive shell into a single service container.
  - `info`    – shows project metadata, services list (`docker compose config --services`), and current `ps`.
  - `status`  – `docker compose ps` wrapper.
  - `health`  – per-container:
    - State (`running`, `exited`, etc.)
    - Health status (if defined)
    - Mounts (source → destination, including volumes & bind mounts).

- Target selection:
  - `--all` (default) – all services in the selected compose file.
  - `--profile NAME` – restrict to services in specific profiles.
    - Accepts multiple flags or CSV: `--profile core --profile images`, `--profile core,images`.
  - `--service NAME` / `--services NAME` – restrict to specific services by name.
    - Accepts multiple flags or CSV: `--service n8n,postgres`.

- Global options:
  - `-f, --file` – custom compose file (defaults to `docker-compose.yml`).
  - `-p, --project-name` – custom Docker Compose project name (defaults to `swiss-army-stack`).
  - `--version` – prints script version.
  - `-h, --help` – detailed usage help.

- Safety & robustness:
  - Uses `set -Eeuo pipefail` to fail fast on errors.
  - Global `trap` prints an informative error with line number.
  - Validates:
    - Exactly one command given.
    - No mixing `--all` with `--profile`/`--service`.
    - `shell` requires exactly one `--service`.
  - Uses colorized output for logs, warnings, and errors (if TTY).

- Extra docker-compose args:
  - Any arguments after `--` are forwarded to `docker compose`.
  - This enables patterns like:
    - `./stackctl.sh logs --profile ai -- -f`
    - `./stackctl.sh logs --service n8n -- --since 10m -f`

- Compose detection:
  - Prefers `docker compose` if available.
  - Falls back to legacy `docker-compose` if necessary.
  - Fails clearly if neither is present.

### Added – Documentation set

- **`README.md`**
  - High-level description of the stack.
  - Quick-start instructions:
    - Cloning, `chmod +x stackctl.sh`, initial directory structure.
    - Example first-run profiles: `core`, `email`, `storage`, `monitoring`.
  - Command table for `stackctl.sh`.
  - Brief versioning concept for the script.

- **`INSTALL.md`**
  - Detailed install instructions:
    - Prerequisites (Docker, Compose).
    - Repo clone and script permissions.
    - Initial `mkdir -p` for `data/sftp/dev`, `data/tdarr/media`, `data/tdarr/temp`.
  - Example:
    - Minimal stack startup:
      - `./stackctl.sh start --profile core --profile email --profile storage --profile monitoring`
  - Lifecycle:
    - Starting, stopping, cleaning.
    - Shell access and logs.

- **`STACK.md`**
  - Breakdown of each profile:
    - Purpose
    - Included services
    - Typical n8n integration patterns
  - Treats the stack as a capability catalogue:
    - Data, events, files, media, search, auth, monitoring, AI.

- **`ARCHITECTURE.md`**
  - Conceptual model of the stack:
    - Orchestration layer (n8n).
    - Capability layer (services).
    - Control plane (`stackctl.sh` + Docker Compose).
  - Explains how profiles give “slices” of the system:
    - e.g. `core + storage`, `core + ai`, `core + images + search`.
  - Clarifies the role of `health`, `info`, `status` commands as lightweight introspection tools.
  - Encourages evolution:
    - Adding services.
    - Updating profiles.
    - Bumping `SCRIPT_VERSION` and documenting changes.

---

## Unreleased

- No pending changes yet.  
  Future changes should:
  - Bump `SCRIPT_VERSION` in `stackctl.sh`.
  - Add a new section above this line with the new version and date.
