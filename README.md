# Swiss Army Stack

> A local, batteries-included backend lab: n8n as the conductor, a zoo of services as the orchestra, all controlled by `stackctl.sh`.

This repo contains:

- A **monster `docker-compose.yml`** with:
  - n8n orchestrator
  - Postgres, MongoDB, Redis
  - Kafka
  - MailHog, Gotify, ntfy
  - MinIO, SFTP
  - Imagor, imgproxy, Thumbor, rembg
  - ffmpeg/Whisper wrappers (placeholders), Tdarr
  - Elasticsearch, Meilisearch, ClickHouse
  - Keycloak
  - Prometheus, Grafana, Loki, Uptime Kuma, node-exporter, cAdvisor, Promtail
  - Ollama, Qdrant, Weaviate
  - LiteLLM proxy, Flowise agents, (commented) vLLM, (commented) TGI, Embeddings API
- A **Swiss-army control script**: `stackctl.sh`
- Supporting docs:
  - `INSTALL.md` – how to get it running
  - `STACK.md` – services and profiles
  - `ARCHITECTURE.md` – how the pieces fit together

Script version: **v0.1.6**

---

## Quick start

```bash
# 1. Clone repo and cd into it
git clone <your-repo-url> swiss-army-stack
cd swiss-army-stack

# 2. Make the control script executable
chmod +x stackctl.sh

# 3. (Recommended) create data folders for mounted paths
mkdir -p data/sftp/dev data/tdarr/media data/tdarr/temp

# 4. Bring up a minimal useful stack: core + email + storage + monitoring
./stackctl.sh start --profile core --profile email --profile storage --profile monitoring

# Then:
    - n8n → http://localhost:5678
    - MailHog → http://localhost:8025
    - MinIO console → http://localhost:9001
    - Uptime Kuma → http://localhost:3001
    - Grafana → http://localhost:3000
```

## Reusing the control script in other Compose projects

The script is generic: drop `stackctl.sh` into another repo and point it at your compose file and metadata.

- Configure defaults via metadata (default `metadata.json`):
  - `compose.file`
  - `compose.project_name_default`
  - `compose.default_restart_policy` (`inherit|manual|auto|always|on-failure`)
  - `stack.name`, `stack.slug`, `stack.version` (display only)
- Override via environment:
  - `STACKCTL_METADATA_FILE` to point to a different metadata file
  - `STACKCTL_DEFAULT_RESTART_POLICY` to set the baseline restart policy
  - `STACKCTL_RESTART_POLICY` (or `--restart-policy`) to override per run/target
  - `COMPOSE_FILE_DEFAULT`, `PROJECT_NAME_DEFAULT` if you skip metadata
- Run with flags instead of metadata if you prefer:
  - `./stackctl.sh --file my-compose.yml --project-name myproj start --profile core`
  - `./stackctl.sh --metadata mymeta.json start --restart-policy on-failure`
