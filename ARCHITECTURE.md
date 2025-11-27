# ARCHITECTURE

This document describes the high-level architecture of the Swiss Army Stack and how `stackctl.sh` fits into it.

---

## Mental model

Think of the stack as three layers:

1. **Orchestration layer** – n8n  
2. **Capability layer** – databases, queues, search engines, storage, ML, etc.  
3. **Control plane** – `stackctl.sh` + Docker Compose

Your own apps (FastAPI, Next.js, WordPress, etc.) can be dropped into this universe as additional services; n8n and the rest of the stack give you “batteries included” integrations.

---

## 1. Orchestration layer: n8n

- n8n is the central “brain” of the stack.
- It connects to everything else using:
  - Native nodes (Postgres, Redis, etc.)
  - HTTP Request nodes (for imagor, imgproxy, rembg, Ollama, Keycloak, etc.)
  - Webhook nodes (so other services can trigger workflows)
- Primary DB: Postgres (`postgres` service)
- Additional storage: MongoDB, Redis, MinIO

Example orchestrated flow:

1. Webhook in n8n receives a request.
2. Validate payload in Function / Code nodes.
3. Write metadata to Postgres.
4. Write raw file to MinIO.
5. Call Imagor to generate image variants.
6. Index document in Meilisearch.
7. Send confirmation email via MailHog.
8. Push a Gotify / ntfy notification to your phone.
9. Record a summary event in ClickHouse.

All without writing a new backend service.

---

## 2. Capability layer: the service zoo

Everything below n8n is an implementation detail providing capabilities.

- **Data:** Postgres, MongoDB, Redis
- **Events:** Kafka
- **Files:** MinIO, SFTP
- **Images:** Imagor, imgproxy, Thumbor, rembg
- **Video/audio:** ffmpeg-api, Tdarr, whisper-api
- **Search & analytics:** Elasticsearch, Meilisearch, ClickHouse
- **Auth:** Keycloak
- **AI:** Ollama, Qdrant, Weaviate
- **Monitoring:** Prometheus, Grafana, Loki, Uptime Kuma

n8n interacts with them strictly via protocols:

- HTTP(S)
- Database drivers
- SMTP / IMAP
- Optional custom APIs you provide (ffmpeg-api, whisper-api)

This keeps the mental model clean:

> “Each service is a tool; n8n wires tools together; `stackctl.sh` keeps the lab running.”

---

## 3. Control plane: `stackctl.sh` + Docker Compose

`stackctl.sh` is a thin, safety-oriented wrapper around Docker Compose.

Responsibilities:

- Encapsulate the correct `docker compose` invocation:
  - Compose file
  - Project name
  - Profiles
- Provide a human-friendly CLI for common actions:
  - `start`, `restart`, `stop`, `rebuild`
  - `clean` (with prompts)
  - `logs`
  - `shell`
  - `info`
  - `status`
  - `health`
- Enforce “play safe” defaults:
  - `clean` asks before `down`
  - Another prompt before volume removal
  - Explicit requirement for `shell --service NAME`

This lets you treat the entire multi-service stack as one manageable unit.

---

## 4. Profiles as slices of the system

Compose profiles give you **slices** of the architecture:

- `core` – minimal orchestrator + DB
- `core + storage` – add MinIO and SFTP to test file flows
- `core + email + monitoring` – add mail + dashboards
- `core + images + ai` – build image + LLM flows
- `core + queue + search` – event and analytics flows

Instead of running **everything** all the time, you turn on only the slices you need for the current experiment.

---

## 5. Health & introspection

The `health` command in `stackctl.sh` gives a quick view of:

- Container state (running, exited, etc.)
- Health status (if the image defines a Docker HEALTHCHECK)
- Mounts (binds + named volumes) for each container

This helps answer questions like:

- Is this container healthy?
- Where is this service’s data actually stored?
- Which bind mounts did I configure for this service?

Combined with `info` and `status`, you get a pragmatic observability layer before you even touch Prometheus/Grafana.

---

## 6. Evolving the architecture

This setup is intentionally **opinionated but not locked-in**:

- You can:
  - Add/remove services
  - Change images or versions
  - Introduce your own apps and APIs
- `stackctl.sh` doesn’t hardcode service names; it just forwards them to Docker Compose.
- As you add new profiles or services:
  - Update `STACK.md`
  - Bump `SCRIPT_VERSION` when changing behavior
  - Optionally extend `ARCHITECTURE.md` with more flows

The stack is meant as a **sandbox** for designing and testing backend patterns – not as a rigid production platform – but the same concepts carry over cleanly to production-grade deployments.

