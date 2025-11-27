# INSTALL

How to install and run the Swiss Army Stack locally.

## 1) Prerequisites

- Linux / macOS / WSL
- Docker Engine
- Docker Compose (`docker compose` v2+ or legacy `docker-compose`)

Sanity checks:

```bash
docker version
docker compose version   # or: docker-compose version
```

## 2) Clone the repo

```bash
git clone <your-repo-url> swiss-army-stack
cd swiss-army-stack
```

(The folder name is arbitrary.)

## 3) Make the control script executable

```bash
chmod +x stackctl.sh
```

Optional: symlink it onto your PATH to run it from anywhere inside the repo:

```bash
ln -s "$(pwd)/stackctl.sh" ~/bin/stackctl
```

## 4) Prepare local directories

The compose file mounts a few host paths:

- `./data/sftp/dev` – home for the SFTP user
- `./data/tdarr/media` – media library for Tdarr
- `./data/tdarr/temp` – temp scratch space for Tdarr
- `./ffmpeg-api` – build context for your custom ffmpeg HTTP wrapper
- `./whisper-api` – build context for your custom Whisper HTTP wrapper

Create the basics now:

```bash
mkdir -p data/sftp/dev
mkdir -p data/tdarr/media
mkdir -p data/tdarr/temp
```

(You can create `ffmpeg-api` and `whisper-api` later or comment them out in the compose file until then.)

## 5) First run: minimal stack

Start with a lean set of profiles:

```bash
./stackctl.sh start --profile core --profile email --profile storage --profile monitoring
```

This brings up:

- Core: n8n, Postgres, MongoDB, Redis
- Email: MailHog, Gotify, ntfy
- Storage: MinIO, SFTP
- Monitoring: Prometheus, Grafana, Loki, Uptime Kuma

## 6) Check it’s working

- n8n → http://localhost:5678
- MailHog → http://localhost:8025
- MinIO console → http://localhost:9001
- Uptime Kuma → http://localhost:3001
- Grafana → http://localhost:3000
- Prometheus → http://localhost:9090

From n8n, services are reachable by service name inside the Docker network (for example `postgres:5432`, `redis:6379`, `minio:9000`, `mailhog:1025`).

## 7) Controlling the stack

```bash
# Start / restart / stop everything
./stackctl.sh start
./stackctl.sh restart
./stackctl.sh stop

# Start only core + AI profiles
./stackctl.sh start --profile core --profile ai

# Restart a couple of services
./stackctl.sh restart --service n8n,postgres

# Logs for a specific service
./stackctl.sh logs --service n8n -- -f

# Shell into a container
./stackctl.sh shell --service n8n

# Health report
./stackctl.sh health --all
```

## 8) Tearing down

To stop everything and remove containers and networks (with a safety prompt):

```bash
./stackctl.sh clean --all
```

You’ll be asked whether to remove named volumes; answering “yes” is destructive.

## 9) Customization

Change project name:

```bash
./stackctl.sh start -p my-swiss-stack --profile core
```

Use a different compose file:

```bash
./stackctl.sh start -f docker-compose.override.yml --profile core
```

Change defaults permanently: edit `PROJECT_NAME_DEFAULT` and/or `COMPOSE_FILE_DEFAULT` near the top of `stackctl.sh`.
