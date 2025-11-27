# Repository Guidelines

## Project Structure & Module Organization
- Root contains `docker-compose.yml` (service zoo), `stackctl.sh` (control script), and `metadata.json` (source of truth for stack name/version/default compose settings). Docs live in `README.md`, `INSTALL.md`, `STACK.md`, `ARCHITECTURE.md`.
- User data mounts belong under `data/` (e.g., `data/sftp/dev`, `data/tdarr/...`). Keep custom compose overrides as `docker-compose.override.yml` or `compose.*.yml`.
- Add service-specific assets beside their build contexts (e.g., `ffmpeg-api/`, `whisper-api/`) to keep profiles self-contained.

## Build, Test, and Development Commands
- `chmod +x stackctl.sh` once after cloning.
- `./stackctl.sh start --profile core` brings up n8n + databases; add profiles (`--profile storage --profile monitoring`) as needed.
- `./stackctl.sh logs --profile ai -- -f` tails grouped logs; `./stackctl.sh status` mirrors `docker compose ps`.
- `./stackctl.sh health` prints status/health/mounts for running containers.
- `./stackctl.sh clean --all` tears down containers; answer the volume prompt carefully.
- Fallback: `docker compose -f docker-compose.yml config -q` validates compose syntax.

## Coding Style & Naming Conventions
- Bash: keep `set -Eeuo pipefail`, prefer functions, quote variables, use `local` in functions, two-space indents.
- Compose: use kebab-case service names matching profile intent (`ffmpeg-api`, `whisper-api`); keep environment variables in `.env` or compose `env_file` entries, not hard-coded.
- Scripts: keep log helpers consistent with `log/warn/error` patterns already in `stackctl.sh`.

## Testing & Validation
- No formal test suite; validate changes with `docker compose config -q` and a targeted start/stop cycle (`./stackctl.sh start --profile X && ./stackctl.sh clean --profile X`).
- Run `shellcheck stackctl.sh` for script edits; keep output warning-free.
- When adding services, verify container healthchecks where possible and document endpoints in `STACK.md`.

## Commit & Pull Request Guidelines
- Commits: present-tense, imperative subject lines (`Add ai profile defaults`, `Fix health command output`). Group related compose and script edits together.
- PRs: include a short summary of the profiles/services touched, key commands to reproduce, and any new env vars. Link issues when applicable and attach screenshots/log snippets for UI- or health-related fixes.
- Update docs (`README.md`, `STACK.md`, `ARCHITECTURE.md`, `INSTALL.md`) when behaviour, profiles, or defaults change.

## Security & Configuration Tips
- Keep credentials and tokens in `.env` (not committed). Rotate test credentials used in examples.
- Map persistent volumes under `./data` by default and avoid reusing host paths that could shadow system directories.
- If exposing services beyond localhost, review each container’s default credentials and tighten them before deployment.
