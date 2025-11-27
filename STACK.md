
---

## `STACK.md`

```md
# STACK

This document describes the services and logical profiles defined in the monster `docker-compose.yml`.

Each profile is an activation group you can use with `--profile NAME` in `stackctl.sh`.

---

## Profiles overview

- `core` – n8n + main databases
- `queue` – Kafka + ZooKeeper
- `email` – email & notification services
- `storage` – file and object storage
- `images` – image processing services
- `video` – video/audio helpers
- `search` – search & analytics engines
- `auth` – identity & access management
- `monitoring` – metrics, logs, uptime
- `ai` – LLMs & vector stores

---

## core

**Goal:** core orchestration + generic data layer.

Services:

- `n8n` – workflow/orchestration engine
- `postgres` – relational DB, used as n8n’s primary database
- `mongo` – document store, general JSON / unstructured data
- `redis` – cache, ephemeral state, rate limiting, locks

Typical n8n connections:

- Postgres node → `postgres:5432`
- MongoDB / HTTP / custom functions as needed
- Redis nodes or HTTP wrappers depending on your usage

---

## queue

**Goal:** event backbone / messaging.

Services:

- `zookeeper` – coordination backend for Kafka (local single-node)
- `kafka` – message broker, topics for events and streams

Typical patterns:

- Services produce events to `kafka:9092`
- n8n consumes events via Kafka-compatible integration or via a sidecar service that pushes Kafka events into n8n webhooks.

---

## email

**Goal:** play with email and notifications without spamming real users.

Services:

- `mailhog` – dev SMTP sink + web UI (capture all mail)
- `gotify` – self-hosted push notification server
- `ntfy` – simple HTTP → push notifications

Examples:

- n8n Email node:
  - SMTP host: `mailhog`
  - port: `1025`
- HTTP nodes to:
  - `http://gotify/` (internal)
  - `http://ntfy/` (internal)

---

## storage

**Goal:** local S3 plus classic SFTP for file workflows.

Services:

- `minio` – S3-compatible object storage
  - API: `minio:9000` (internal), `localhost:9000` from host
  - Console: `localhost:9001`
- `sftp` – SFTP server with a single user `dev` / `devpass`

Example flows:

- n8n receives file → uploads to MinIO → stores metadata in Postgres
- n8n moves files to/from SFTP (`sftp:22`)

---

## images

**Goal:** image conversion, resizing, background removal.

Services:

- `imagor` – HTTP image processing server
- `imgproxy` – fast image resizer/converter
- `thumbor` – classic image transformation proxy
- `rembg` – background removal over HTTP

Typical usage:

- n8n `HTTP Request` node to:
  - `http://imagor:8000/...`
  - `http://imgproxy:8080/...`
  - `http://thumbor:8000/...`
  - `http://rembg:7000/...`

Combined with MinIO or other sources to build image pipelines.

---

## video

**Goal:** experiment with media pipelines.

Services:

- `ffmpeg-api` – **your** HTTP wrapper around ffmpeg
  - Build context: `./ffmpeg-api`
- `tdarr` – media transcoding/normalizing service
- `whisper-api` – **your** HTTP wrapper around Whisper STT
  - Build context: `./whisper-api`

You implement the API containers to expose simple HTTP endpoints like:

- `POST /transcode`
- `POST /extract-audio`
- `POST /transcribe`

n8n orchestrates calls to these endpoints and stores results.

---

## search

**Goal:** search engines and analytics playground.

Services:

- `elasticsearch` – full-text search / logs backend
- `meilisearch` – lightweight, fast search engine
- `clickhouse` – columnar DB for analytics / events

Patterns:

- n8n ingests events from webhooks / Kafka → enriches → writes to:
  - `elasticsearch:9200`
  - `meilisearch:7700`
  - `clickhouse:8123`

---

## auth

**Goal:** identity provider (IDP) for experimenting with auth flows.

Services:

- `keycloak` – IAM + OIDC/SAML

Usage:

- Configure realms and clients in Keycloak UI.
- Have n8n call Keycloak’s REST API for user provisioning, group management, etc.
- Use Keycloak as the authentication layer for other services you add later.

---

## monitoring

**Goal:** see what your zoo is doing.

Services:

- `prometheus` – metrics collection
- `grafana` – dashboards
- `loki` – log aggregation backend
- `uptime-kuma` – synthetic monitoring / uptime checks

Notes:

- Prometheus is currently started with default config; you should mount a `prometheus.yml` to scrape n8n and friends.
- Loki uses the built-in local config; wire log shippers later (e.g., Promtail).
- Uptime Kuma can monitor:
  - HTTP endpoints
  - TCP ports
  - Docker containers (via mounted `docker.sock`)

---

## ai

**Goal:** LLM and vector playground.

Services:

- `ollama` – local LLM server (`ollama:11434`)
- `qdrant` – vector database for embeddings
- `weaviate` – vector DB / semantic graph DB
- `litellm` *(profile: ai-gateway)* – OpenAI-compatible proxy pointing to Ollama (`litellm:4000`)
- `flowise` *(profile: agents)* – visual agent/orchestration builder (`flowise:3002`)
- `vllm` *(profile: vllm)* – OpenAI-compatible server running `facebook/opt-125m` on CPU (`vllm:8008`)
- `tgi` *(profile: tgi)* – Hugging Face text-generation-inference with `sshleifer/tiny-gpt2` (`tgi:8085`)
- `embeddings-api` *(profile: embeddings)* – text-embeddings-inference with `sentence-transformers/all-MiniLM-L6-v2` (`embeddings-api:8086`)

Patterns:

- n8n fetches data → calls an embedding model (local or remote) → stores vectors in Qdrant/Weaviate.
- n8n uses Ollama via HTTP:
  - Summarization
  - Classification
  - Small automations
- n8n uses LiteLLM as an OpenAI drop-in:
  - Base URL: `http://litellm:4000`
  - Model name in requests: `ollama-llama3`
  - Add header `Authorization: Bearer dev-master-key`
- Optional alternates:
  - Call `http://vllm:8008/v1/chat/completions` (OpenAI style) for small CPU-friendly model.
  - Call `http://tgi:8085/generate` for TGI (tiny GPT-2) text generation.
  - Call `http://embeddings-api:8086/embed` (TEI) for embeddings.

This forms the base for RAG-style flows, with n8n as the orchestrator.
