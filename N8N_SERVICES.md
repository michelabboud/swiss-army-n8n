N8N Services Cheatsheet for swiss-army-n8n
==========================================

This file shows how to connect each service from inside n8n (running in the same compose network) and gives example chains you can build. Use the service names as hosts; you do not need host ports from other containers.

Quick reference table
---------------------

| Category   | Service        | Host:Port (internal)   | Credentials / notes                                    |
|------------|----------------|------------------------|--------------------------------------------------------|
| Orchestrator | n8n          | `n8n:5678`             | UI exposed via host port 5678.                         |
| Databases  | Postgres       | `postgres:5432`        | DB/user/pass: `n8n`/`n8n`/`n8n`.                       |
|            | Mongo          | `mongo:27017`          | No auth configured.                                    |
|            | Redis          | `redis:6379`           | No password set.                                       |
| Queue      | Kafka          | `kafka:9092`           | PLAINTEXT only.                                        |
| Email/Notify | MailHog      | `mailhog:1025` SMTP    | No auth. UI on host 8025.                              |
|            | Gotify         | `gotify:80`            | Create app token in Gotify UI.                         |
|            | ntfy           | `ntfy:80`              | Uses topics; no auth by default.                       |
| Storage    | MinIO          | `minio:9000`           | Access/secret: `minio`/`minio123`. S3-compatible.      |
|            | SFTP           | `sftp:22`              | User: `dev`, pass: `devpass`.                          |
| Images/Video | Imagor       | `imagor:8000`          | Unsafe mode enabled.                                   |
|            | imgproxy       | `imgproxy:8080`        | Signatures disabled by default.                        |
|            | Thumbor        | `thumbor:8000`         | No key configured.                                     |
|            | rembg          | `rembg:7000`           | REST server mode.                                      |
|            | ffmpeg-api     | `ffmpeg-api:8080`      | Custom wrapper (sleeping until used).                  |
|            | Tdarr          | `tdarr:8266` API       | UI on host 8265; API key optional depending on config. |
| AI         | Ollama         | `ollama:11434`         | Use `/api/chat` or `/api/generate`.                    |
|            | Qdrant         | `qdrant:6333`          | REST + gRPC; no API key set.                           |
|            | Weaviate       | `weaviate:8080`        | Anonymous access enabled.                              |
|            | Whisper API    | `whisper-api:8080`     | Custom wrapper (sleeping until used).                  |
| Search     | Elasticsearch  | `elasticsearch:9200`   | Security disabled.                                     |
|            | Meilisearch    | `meilisearch:7700`     | Analytics disabled; no master key set.                 |
|            | ClickHouse     | `clickhouse:8123`      | HTTP API; no auth.                                     |
| Auth/Monitor | Keycloak     | `keycloak:8080`        | Admin: `admin` / `admin`.                              |
|            | Prometheus     | `prometheus:9090`      | Default config only.                                   |
|            | Grafana        | `grafana:3000`         | Default admin creds unless changed.                    |
|            | Loki           | `loki:3100`            | No auth.                                               |
| Uptime     | Uptime Kuma    | `uptime-kuma:3001`     | UI only.                                               |

How to connect from n8n
-----------------------

- Use the service name as host (e.g., `minio`, `kafka`, `ntfy`), not `localhost`.
- Create n8n Credentials:
  - HTTP: base URL `http://service:port`, add headers/tokens as needed.
  - Postgres/Mongo/Redis/Kafka: use their native nodes with host/port above.
  - S3: set endpoint to `http://minio:9000`, access/secret from table, disable SSL, force path-style.
  - SFTP: host `sftp`, port `22`, user/pass `dev`/`devpass`.

Example chains (one per service)
--------------------------------

Databases
- Postgres ingest: Webhook → Function (transform JSON) → Postgres node (host `postgres`, db `n8n`) → ntfy HTTP to confirm.
- Mongo write/read: Cron → HTTP Request fetch data → Mongo node (Insert) → Redis (Set) for cache → n8n responds.
- Redis cache aside: Webhook → Redis (Get) → IF miss → HTTP fetch → Redis (Set, TTL) → Respond.

Queue
- Kafka consume to notification: Kafka Trigger (broker `kafka:9092`, topic `alerts`) → Switch by payload → ntfy HTTP post → Gotify message.
- Kafka produce: Webhook → Function → Kafka node (Produce) to `events` topic → downstream flow consumes.

Email/Notifications
- MailHog test mail: Cron → Email node (SMTP host `mailhog`, port `1025`) send to a dummy inbox → HTTP Request to `http://mailhog:8025/api/v2/messages` to verify.
- Gotify push: Webhook → HTTP Request POST `http://gotify/message` with header `X-Gotify-Key: <token>` and JSON `{"title":"Hi","message":"Body"}`.
- ntfy push: Webhook → HTTP Request POST `http://ntfy/<topic>` with form/body text; set `X-Title`/`X-Priority` headers as needed.

Storage
- SFTP move: Webhook (file URL) → HTTP download file → SFTP node Upload (host `sftp`, path `/home/dev/incoming`) → ntfy notify with link.
- MinIO pipeline: Webhook → Function (base64 file) → S3 node Upload (endpoint `http://minio:9000`, bucket `uploads`) → Postgres insert metadata → Gotify alert.

Images/Video
- Background removal: Webhook (image URL) → HTTP Request to `http://rembg:7000/remove` with file → S3 upload to MinIO → ntfy push with result URL.
- Resize via imgproxy: Webhook (image URL) → Construct imgproxy URL `http://imgproxy:8080/insecure/width:800/plain/<url>` → HTTP Request → respond with transformed image.
- Imagor chain: Webhook → HTTP to `http://imagor:8000/unsafe/fit-in/800x800/<url>` → store to MinIO.
- Thumbor: Webhook → HTTP `http://thumbor:8000/unsafe/800x800/smart/<url>` → return image.
- ffmpeg-api example: Webhook (video URL) → HTTP POST `http://ffmpeg-api:8080/transcode` (payload per API) → store output to MinIO.
- Tdarr automate: Cron → HTTP POST `http://tdarr:8266/api/v2/queue` with library scan payload → ntfy on completion.

AI
- Ollama chat: Webhook → HTTP POST `http://ollama:11434/api/chat` with `{"model":"llama3","messages":[...]"}` → return content → ntfy/Gotify.
- Whisper transcription: Webhook (audio file) → HTTP POST multipart to `http://whisper-api:8080/transcribe` → store transcript in Postgres and Qdrant.
- Qdrant upsert/search: Webhook → HTTP PUT `http://qdrant:6333/collections/demo/points` with vectors → later HTTP POST search same host → use in workflow.
- Weaviate semantic search: HTTP POST `http://weaviate:8080/v1/graphql` with query → merge results back to caller.

Search/Analytics
- Elasticsearch index: Webhook → HTTP PUT `http://elasticsearch:9200/logs/_doc` with JSON → respond.
- Meilisearch index/search: Webhook → HTTP POST `http://meilisearch:7700/indexes/docs/documents` → later search with GET `.../search?q=term`.
- ClickHouse insert/query: HTTP POST `http://clickhouse:8123/` with `query=INSERT ...` or `SELECT ...` and parse CSV/JSON.

Auth/Monitoring
- Keycloak user create: Webhook → HTTP POST to `http://keycloak:8080/realms/master/protocol/openid-connect/token` (client admin creds) → use token to call admin API for user provisioning.
- Prometheus scrape data: HTTP GET `http://prometheus:9090/api/v1/query?query=up` → branch on results → ntfy/Gotify.
- Grafana annotations: HTTP POST `http://grafana:3000/api/annotations` with token to mark events triggered by n8n flows.
- Loki logging: HTTP POST `http://loki:3100/loki/api/v1/push` to emit logs from n8n workflows for later dashboarding.
- Uptime Kuma: HTTP GET/POST to `http://uptime-kuma:3001/api` (after login token) to add monitors from n8n.

Uptime/Housekeeping
- Health checks: Cron → HTTP GET each service health endpoint (e.g., ntfy `/v1/health`, grafana `/api/health`, elasticsearch `/_cluster/health`) → aggregate → ntfy summary.

Tips
----
- Use environment variables in n8n Credentials for hostnames/ports if you plan to change them.
- Keep secrets (tokens, keys) in n8n credentials, not hard-coded in nodes.
- Prefer HTTP nodes with a shared credential for services that need auth (Gotify token, MinIO S3, Keycloak admin, Grafana API token).
- Internal service DNS works only from inside compose; if you test from host, use the mapped host ports instead.

