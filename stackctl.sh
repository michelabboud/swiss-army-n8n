#!/usr/bin/env bash
set -Eeuo pipefail

#############################################
# stackctl.sh - Swiss-army Docker Compose control script
#
# Orchestrates a multi-service "lab" stack using docker compose.
# Uses metadata.json as the source of truth for:
#   - stack name
#   - stack version
#   - default compose file
#   - default project name
#   - last changelog entry (for info display)
#############################################

# --- Defaults (overridden by metadata.json when possible) ---
STACK_NAME_DEFAULT="Swiss Army Stack"
STACK_SLUG_DEFAULT="swiss-army-stack"
STACK_VERSION_DEFAULT="0.1.31"

COMPOSE_FILE_DEFAULT="${COMPOSE_FILE_DEFAULT:-docker-compose.yml}"
PROJECT_NAME_DEFAULT="${PROJECT_NAME_DEFAULT:-swiss-army-stack}"

METADATA_FILE_DEFAULT="${METADATA_FILE_DEFAULT:-metadata.json}"

# Live values (will be adjusted by metadata)
STACK_NAME="$STACK_NAME_DEFAULT"
STACK_SLUG="$STACK_SLUG_DEFAULT"
STACK_VERSION="$STACK_VERSION_DEFAULT"
COMPOSE_FILE="$COMPOSE_FILE_DEFAULT"
PROJECT_NAME="$PROJECT_NAME_DEFAULT"
METADATA_FILE="$METADATA_FILE_DEFAULT"

# Target selection
TARGET_MODE="all"   # all | profile | service
PROFILES=()
SERVICES=()
FORWARDED_ARGS=()
COMPOSE_OVERRIDES=()
RESTART_OVERRIDE_FILE=""
RESTART_POLICY_DEFAULT="inherit"
RESTART_POLICY_MODE="inherit"

# Colors (only if stdout is a TTY)
if [[ -t 1 ]]; then
  RED=$(tput setaf 1 || true)
  GREEN=$(tput setaf 2 || true)
  YELLOW=$(tput setaf 3 || true)
  BLUE=$(tput setaf 4 || true)
  BOLD=$(tput bold || true)
  RESET=$(tput sgr0 || true)
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; RESET=""
fi

log()   { printf '%b\n' "${BLUE}[stackctl]${RESET} $*"; }
warn()  { printf '%b\n' "${YELLOW}[stackctl][WARN]${RESET} $*" >&2; }
error() { printf '%b\n' "${RED}[stackctl][ERROR]${RESET} $*" >&2; exit 1; }

trap 'error "Command failed (exit $?) at line $LINENO."' ERR
cleanup() {
  if [[ -n "$RESTART_OVERRIDE_FILE" && -f "$RESTART_OVERRIDE_FILE" ]]; then
    rm -f "$RESTART_OVERRIDE_FILE"
  fi
}
trap cleanup EXIT

#############################################
# metadata.json handling
#############################################

load_metadata() {
  if [[ ! -f "$METADATA_FILE" ]]; then
    # No metadata.json, use built-in defaults silently
    return
  fi

  if ! command -v jq >/dev/null 2>&1; then
    warn "metadata.json found but 'jq' is not installed; using built-in defaults."
    return
  fi

  # Stack name
  local v
  v=$(jq -r '.stack.name // empty' "$METADATA_FILE" 2>/dev/null || true)
  if [[ -n "$v" && "$v" != "null" ]]; then
    STACK_NAME="$v"
  fi

  v=$(jq -r '.stack.slug // empty' "$METADATA_FILE" 2>/dev/null || true)
  if [[ -n "$v" && "$v" != "null" ]]; then
    STACK_SLUG="$v"
  fi

  v=$(jq -r '.stack.version // empty' "$METADATA_FILE" 2>/dev/null || true)
  if [[ -n "$v" && "$v" != "null" ]]; then
    STACK_VERSION="$v"
  fi

  v=$(jq -r '.compose.file // empty' "$METADATA_FILE" 2>/dev/null || true)
  if [[ -n "$v" && "$v" != "null" ]]; then
    COMPOSE_FILE_DEFAULT="$v"
    COMPOSE_FILE="$COMPOSE_FILE_DEFAULT"
  fi

  v=$(jq -r '.compose.project_name_default // empty' "$METADATA_FILE" 2>/dev/null || true)
  if [[ -n "$v" && "$v" != "null" ]]; then
    PROJECT_NAME_DEFAULT="$v"
    PROJECT_NAME="$PROJECT_NAME_DEFAULT"
  fi

  v=$(jq -r '.compose.default_restart_policy // empty' "$METADATA_FILE" 2>/dev/null || true)
  if [[ -n "$v" && "$v" != "null" ]]; then
    set_restart_policy_mode "$v"
    RESTART_POLICY_DEFAULT="$RESTART_POLICY_MODE"
  fi
}

#############################################
# Usage & compose helpers
#############################################

usage() {
  cat <<EOF
${BOLD}${STACK_NAME}${RESET} (${STACK_SLUG})
stackctl.sh v${STACK_VERSION}
Using metadata: ${METADATA_FILE}

Usage:
  stackctl.sh <command> [options] [-- <extra docker compose args>]

Commands:
  start       Bring up services (docker compose up -d)
  restart     Restart running services
  stop        Stop services (docker compose stop)
  rebuild     Rebuild images and restart (docker compose up --build -d)
  clean       Tear down containers (and optionally volumes)
  logs        Show logs (docker compose logs)
  shell       Open an interactive shell in a single service container
  info        Show stack and docker compose information
  status      Show docker compose ps
  health      Inspect containers: status, health, mounts
  endpoints   Summarize externally mapped service ports (host -> container)

Target selection:
  --all               Operate on all services (default)
  --profile NAME      Limit to services in profiles (can repeat or CSV)
  --service NAME      Limit to specific services (can repeat or CSV)

Global options:
  -f, --file FILE         Compose file (default: ${COMPOSE_FILE_DEFAULT})
  -p, --project-name NAME Project name (default: ${PROJECT_NAME_DEFAULT})
  --metadata FILE         Metadata file (default: ${METADATA_FILE_DEFAULT}, env: STACKCTL_METADATA_FILE)
  --restart-policy MODE   Override restart policy: inherit|auto|manual|always|on-failure
                          (env: STACKCTL_RESTART_POLICY; default from metadata compose.default_restart_policy or STACKCTL_DEFAULT_RESTART_POLICY)
  --version               Show stack version (from metadata.json)
  -h, --help              Show this help

Examples:
  # Start core stack (assuming profiles defined in compose)
  stackctl.sh start --profile core

  # Start core + images profiles
  stackctl.sh start --profile core --profile images

  # Disable auto-restart for the core profile
  stackctl.sh start --profile core --restart-policy manual

  # Restart only n8n and postgres
  stackctl.sh restart --service n8n,postgres

  # View logs for AI-related services with follow
  stackctl.sh logs --profile ai -- -f

  # Interactive shell into the n8n container
  stackctl.sh shell --service n8n

  # Full health report for all running containers
  stackctl.sh health --all

  # Tear down everything (with a prompt about volumes)
  stackctl.sh clean --all

Any arguments after "--" are passed directly to docker compose.
If your compose file uses profiles and you don't specify any, stackctl enables all profiles by default.
EOF
}

DOCKER_COMPOSE_CMD=()

detect_compose() {
  if command -v docker >/dev/null 2>&1; then
    if docker compose version >/dev/null 2>&1; then
      DOCKER_COMPOSE_CMD=(docker compose)
      return
    fi
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    DOCKER_COMPOSE_CMD=(docker-compose)
    return
  fi
  error "Neither 'docker compose' nor 'docker-compose' found."
}

available_profiles() {
  detect_compose
  local -a _profiles=()
  mapfile -t _profiles < <("${DOCKER_COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" -p "$PROJECT_NAME" config --profiles 2>/dev/null || true)
  printf '%s\n' "${_profiles[@]}"
}

set_restart_policy_mode() {
  local raw="${1,,}"
  case "$raw" in
    ""|inherit|keep|default)
      RESTART_POLICY_MODE="inherit"
      ;;
    manual|off|no|disabled)
      RESTART_POLICY_MODE="no"
      ;;
    auto|unless-stopped)
      RESTART_POLICY_MODE="unless-stopped"
      ;;
    always)
      RESTART_POLICY_MODE="always"
      ;;
    on-failure|onfailure)
      RESTART_POLICY_MODE="on-failure"
      ;;
    *)
      error "Invalid restart policy '$1'. Use: inherit|auto|manual|always|on-failure."
      ;;
  esac
}

ensure_profile_selection() {
  if [[ "$TARGET_MODE" != "all" || ${#PROFILES[@]} -ne 0 || ${#SERVICES[@]} -ne 0 ]]; then
    return
  fi
  local -a _auto_profiles=()
  mapfile -t _auto_profiles < <(available_profiles)
  if [[ "${#_auto_profiles[@]}" -gt 0 ]]; then
    PROFILES=("${_auto_profiles[@]}")
  fi
}

list_target_services() {
  ensure_profile_selection
  if [[ ${#SERVICES[@]} -gt 0 ]]; then
    printf '%s\n' "${SERVICES[@]}"
    return 0
  fi

  detect_compose
  local -a profile_flags=()
  for p in "${PROFILES[@]}"; do
    profile_flags+=(--profile "$p")
  done

  local services_out
  services_out=$("${DOCKER_COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" -p "$PROJECT_NAME" "${profile_flags[@]}" config --services 2>/dev/null || true)
  if [[ -z "$services_out" ]]; then
    warn "Could not resolve services for restart override."
    return 0
  fi

  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    printf '%s\n' "$svc"
  done <<<"$services_out"
}

prepare_restart_override() {
  COMPOSE_OVERRIDES=()
  RESTART_OVERRIDE_FILE=""

  if [[ "$RESTART_POLICY_MODE" == "inherit" ]]; then
    return
  fi

  local policy="$RESTART_POLICY_MODE"
  local mapped=""
  case "$policy" in
    no) mapped="no" ;;
    unless-stopped) mapped="unless-stopped" ;;
    always) mapped="always" ;;
    on-failure) mapped="on-failure" ;;
    *)
      error "Unhandled restart policy mode: $policy"
      ;;
  esac

  local -a _target_services=()
  mapfile -t _target_services < <(list_target_services)
  if [[ "${#_target_services[@]}" -eq 0 ]]; then
    warn "Restart policy override requested but no services matched current scope."
    return
  fi

  RESTART_OVERRIDE_FILE=$(mktemp "${TMPDIR:-/tmp}/stackctl_restart_override.XXXXXX.yml")
  {
    echo "services:"
    for svc in "${_target_services[@]}"; do
      echo "  ${svc}:"
      echo "    restart: ${mapped}"
    done
  } >"$RESTART_OVERRIDE_FILE"
  COMPOSE_OVERRIDES=(-f "$RESTART_OVERRIDE_FILE")
  log "Using restart policy '${mapped}' for services: ${_target_services[*]}"
}

compose() {
  detect_compose

  local log_cmd=true
  if [[ "${1:-}" == "--no-log" ]]; then
    log_cmd=false
    shift
  fi

  ensure_profile_selection

  local profile_flags=()
  for p in "${PROFILES[@]}"; do
    profile_flags+=(--profile "$p")
  done
  local full_cmd=(
    "${DOCKER_COMPOSE_CMD[@]}"
    -f "$COMPOSE_FILE"
    "${COMPOSE_OVERRIDES[@]}"
    -p "$PROJECT_NAME"
    "${profile_flags[@]}"
    "$@"
  )
  if [[ "$log_cmd" == true ]]; then
    printf '%b\n' "${BLUE}[stackctl][CMD]${RESET} ${full_cmd[*]}"
  fi
  "${full_cmd[@]}"
}

print_endpoints() {
  local filter="$1"

  # If no profiles specified, load all available profiles so config includes everything.
  local saved_profiles=("${PROFILES[@]}")
  if [[ ${#PROFILES[@]} -eq 0 ]]; then
    detect_compose
    mapfile -t PROFILES < <("${DOCKER_COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" -p "$PROJECT_NAME" config --profiles 2>/dev/null || true)
  fi

  local cfg
  if ! cfg=$(compose --no-log config --format json); then
    warn "Failed to read compose config."
    PROFILES=("${saved_profiles[@]}")
    return 1
  fi

  local py_script
  py_script=$(cat <<'PY'
import json, os, sys, textwrap

def guess_proto(host_port, container_port):
    https_ports = {"443", "8443", "9443", "7443"}
    if host_port and host_port in https_ports:
        return "https"
    if container_port:
        base = container_port.split("/")[0]
        if base in https_ports:
            return "https"
    return "http"

def chunk(lst, n):
    for i in range(0, len(lst), n):
        yield lst[i : i + n]

try:
    data = json.load(sys.stdin)
except Exception as e:
    sys.stderr.write(f"Failed to parse compose config: {e}\n")
    sys.exit(1)

services = data.get("services", {})
if not services:
    print("No services defined.")
    sys.exit(0)

filter_set = set()
raw_filter = os.environ.get("STACKCTL_SERVICE_FILTER", "")
if raw_filter:
    for item in raw_filter.split():
        filter_set.add(item)

for name in sorted(services):
    if filter_set and name not in filter_set:
        continue
    ports = services[name].get("ports") or []
    print(name)
    if not ports:
        print("  (no published ports)")
        continue
    rows = []
    for port in ports:
        proto = ""
        host_ip = host_port = container_port = ""
        if isinstance(port, dict):
            container_port = str(port.get("target", ""))
            host_port = str(port.get("published", "") or "")
            host_ip = port.get("host_ip") or ""
            proto = f"/{port.get('protocol')}" if port.get("protocol") else ""
        else:
            entry = str(port)
            if "/" in entry:
                entry, proto = entry.split("/", 1)
                proto = f"/{proto}"
            parts = entry.split(":")
            if len(parts) == 3:
                host_ip, host_port, container_port = parts
            elif len(parts) == 2:
                host_port, container_port = parts
            elif len(parts) == 1:
                container_port = parts[0]
        host_label = "(internal only)"
        if host_port:
            display_host = host_ip if host_ip and host_ip not in ("0.0.0.0", "::") else "localhost"
            scheme = guess_proto(host_port, container_port)
            host_label = f"{scheme}://{display_host}:{host_port}"
        target = container_port or "(container port n/a)"
        rows.append(f"{host_label} -> {target}{proto}")

    col_width = 48
    for pair in chunk(rows, 2):
        left = pair[0] if len(pair) > 0 else ""
        right = pair[1] if len(pair) > 1 else ""
        print(f"  {left.ljust(col_width)}{right}")
PY
)
  STACKCTL_SERVICE_FILTER="$filter" python3 -c "$py_script" <<<"$cfg"

  # Restore original profiles to avoid side effects
  PROFILES=("${saved_profiles[@]}")
}

set_target_mode() {
  local new="$1"
  if [[ "$TARGET_MODE" != "all" && "$TARGET_MODE" != "$new" ]]; then
    error "Cannot mix target modes (e.g. --profile and --service)."
  fi
  TARGET_MODE="$new"
}

parse_csv_append() {
  local csv="$1"; shift
  local -n arr="$1"
  IFS=',' read -ra parts <<<"$csv"
  for p in "${parts[@]}"; do
    [[ -z "$p" ]] && continue
    arr+=("$p")
  done
}

ensure_command_set() {
  if [[ -z "${CMD:-}" ]]; then
    usage
    error "Missing command."
  fi
}

#############################################
# Commands
#############################################

cmd_start() {
  log "Starting services (mode: ${TARGET_MODE})..."
  prepare_restart_override
  local extra=()
  if [[ ${#SERVICES[@]} -gt 0 ]]; then extra=("${SERVICES[@]}"); fi
  compose up -d "${extra[@]}" "${FORWARDED_ARGS[@]}"
  log "Endpoints for started scope:"
  if [[ ${#extra[@]} -gt 0 ]]; then
    print_endpoints "${extra[*]}"
  else
    print_endpoints ""
  fi
}

cmd_restart() {
  log "Restarting services (mode: ${TARGET_MODE})..."
  prepare_restart_override
  local extra=()
  if [[ ${#SERVICES[@]} -gt 0 ]]; then extra=("${SERVICES[@]}"); fi
  if [[ "$RESTART_POLICY_MODE" != "inherit" ]]; then
    compose up -d --force-recreate "${extra[@]}" "${FORWARDED_ARGS[@]}"
  else
    compose restart "${extra[@]}" "${FORWARDED_ARGS[@]}"
  fi
  log "Endpoints for restarted scope:"
  if [[ ${#extra[@]} -gt 0 ]]; then
    print_endpoints "${extra[*]}"
  else
    print_endpoints ""
  fi
}

cmd_stop() {
  log "Stopping services (mode: ${TARGET_MODE})..."
  local extra=()
  if [[ ${#SERVICES[@]} -gt 0 ]]; then extra=("${SERVICES[@]}"); fi
  compose stop "${extra[@]}" "${FORWARDED_ARGS[@]}"
}

cmd_rebuild() {
  log "Rebuilding images and starting services (mode: ${TARGET_MODE})..."
  prepare_restart_override
  local extra=()
  if [[ ${#SERVICES[@]} -gt 0 ]]; then extra=("${SERVICES[@]}"); fi
  compose up -d --build "${extra[@]}" "${FORWARDED_ARGS[@]}"
}

cmd_clean() {
  if [[ "$TARGET_MODE" == "service" && ${#SERVICES[@]} -gt 0 ]]; then
    warn "Clean in --service mode removes only selected services' containers."
    read -r -p "Proceed to remove containers for: ${SERVICES[*]} ? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { log "Aborting clean for selected services."; return; }
    compose rm -f "${SERVICES[@]}"
    log "Selected services removed."
    return
  fi

  warn "You are about to bring down the stack for project '${PROJECT_NAME}'."
  read -r -p "Proceed with docker compose down? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { log "Aborting clean."; return; }

  local down_args=(down --remove-orphans)
  read -r -p "Also remove named volumes? [y/N] " vans
  if [[ "$vans" =~ ^[Yy]$ ]]; then
    down_args+=(--volumes)
  fi
  log "Running docker compose down..."
  compose "${down_args[@]}" "${FORWARDED_ARGS[@]}"
}

cmd_logs() {
  log "Showing logs (mode: ${TARGET_MODE})..."
  local extra=()
  if [[ ${#SERVICES[@]} -gt 0 ]]; then extra=("${SERVICES[@]}"); fi
  compose logs "${extra[@]}" "${FORWARDED_ARGS[@]}"
}

cmd_shell() {
  if [[ ${#SERVICES[@]} -ne 1 ]]; then
    error "shell requires exactly one --service NAME."
  fi
  local svc="${SERVICES[0]}"
  log "Opening shell in service '${svc}'..."
  local cid
  cid=$(compose ps -q "$svc")
  if [[ -z "$cid" ]]; then
    error "No running container for service '$svc'."
  fi
  local shell_cmd="bash"
  if ! docker exec "$cid" bash -lc 'exit 0' >/dev/null 2>&1; then
    shell_cmd="sh"
  fi
  printf '%b\n' "${BLUE}[stackctl][CMD]${RESET} docker exec -it ${cid} ${shell_cmd}"
  docker exec -it "$cid" "$shell_cmd"
}

cmd_info() {
  log "Project info"
  printf '  %sStack name:%s       %s\n' "$BOLD" "$RESET" "$STACK_NAME"
  printf '  %sStack slug:%s       %s\n' "$BOLD" "$RESET" "$STACK_SLUG"
  printf '  %sStack version:%s    %s\n' "$BOLD" "$RESET" "$STACK_VERSION"
  printf '  %sProject name:%s     %s\n' "$BOLD" "$RESET" "$PROJECT_NAME"
  printf '  %sCompose file:%s     %s\n' "$BOLD" "$RESET" "$COMPOSE_FILE"
  printf '  %sRestart policy:%s   %s (default: %s)\n' "$BOLD" "$RESET" "$RESTART_POLICY_MODE" "$RESTART_POLICY_DEFAULT"
  printf '  %sTarget mode:%s      %s\n' "$BOLD" "$RESET" "$TARGET_MODE"

  local profiles_label=""
  if [[ ${#PROFILES[@]} -gt 0 ]]; then
    profiles_label="${PROFILES[*]}"
  else
    local -a _avail_profiles=()
    mapfile -t _avail_profiles < <(available_profiles)
    if [[ ${#_avail_profiles[@]} -gt 0 ]]; then
      profiles_label="(none; compose profiles available)"
    else
      profiles_label="(none; compose has no profiles)"
    fi
  fi
  printf '  %sProfiles:%s         %s\n' "$BOLD" "$RESET" "$profiles_label"

  if [[ ${#SERVICES[@]} -gt 0 ]]; then
    printf '  %sServices:%s         %s\n' "$BOLD" "$RESET" "${SERVICES[*]}"
  fi

  # Show last changelog entry from metadata if possible
  if [[ -f "$METADATA_FILE" ]] && command -v jq >/dev/null 2>&1; then
    local last_ver last_date last_title last_summary
    last_ver=$(jq -r '.changelog.last.version // empty' "$METADATA_FILE" 2>/dev/null || true)
    last_date=$(jq -r '.changelog.last.date // empty' "$METADATA_FILE" 2>/dev/null || true)
    last_title=$(jq -r '.changelog.last.title // empty' "$METADATA_FILE" 2>/dev/null || true)
    last_summary=$(jq -r '.changelog.last.summary // empty' "$METADATA_FILE" 2>/dev/null || true)
    if [[ -n "$last_ver" && "$last_ver" != "null" ]]; then
      echo
      log "Last changelog entry (from metadata.json):"
      printf '  %sVersion:%s   %s\n' "$BOLD" "$RESET" "$last_ver"
      [[ -n "$last_date" && "$last_date" != "null" ]] && \
        printf '  %sDate:%s      %s\n' "$BOLD" "$RESET" "$last_date"
      [[ -n "$last_title" && "$last_title" != "null" ]] && \
        printf '  %sTitle:%s     %s\n' "$BOLD" "$RESET" "$last_title"
      [[ -n "$last_summary" && "$last_summary" != "null" ]] && \
        printf '  %sSummary:%s   %s\n' "$BOLD" "$RESET" "$last_summary"
    fi
  fi

  echo
  log "Declared services:"
  compose config --services | sed 's/^/  - /'

  echo
  log "Current container status:"
  compose ps
}

cmd_status() {
  log "Stack status..."
  compose ps "${FORWARDED_ARGS[@]}"
}

cmd_health() {
  log "Health & mounts overview (mode: ${TARGET_MODE})..."
  local extra=()
  if [[ ${#SERVICES[@]} -gt 0 ]]; then extra=("${SERVICES[@]}"); fi
  local ids
  if ! ids=$(compose --no-log ps -q "${extra[@]}"); then
    warn "Failed to list containers."
    return 1
  fi
  if [[ -z "$ids" ]]; then
    warn "No containers found for selected target."
    return 0
  fi
  for id in $ids; do
    local name status health
    name=$(docker inspect --format '{{.Name}}' "$id" | sed 's#^/##')
    status=$(docker inspect --format '{{.State.Status}}' "$id")
    health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$id")
    local color="$GREEN"
    if [[ "$status" != "running" ]]; then color="$YELLOW"; fi
    if [[ -n "$health" && "$health" != "healthy" ]]; then color="$RED"; fi
    printf '%b\n' "${BOLD}Service:${RESET} ${name}"
    printf '  %bState:%b    %b%s%b' "$BOLD" "$RESET" "$color" "$status" "$RESET"
    if [[ -n "$health" ]]; then
      printf ' (health: %s)\n' "$health"
    else
      printf ' (no explicit healthcheck)\n'
    fi
    echo "  ${BOLD}Mounts:${RESET}"
    local mounts
    mounts=$(docker inspect --format '{{range .Mounts}}{{.Type}}: {{.Source}} -> {{.Destination}}{{"\n"}}{{end}}' "$id" || true)
    if [[ -z "$mounts" ]]; then
      echo "    (no mounts)"
    else
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        echo "    $line"
      done <<<"$mounts"
    fi
    echo
  done
}

cmd_endpoints() {
  log "Published endpoints (mode: ${TARGET_MODE})..."

  local filter=""
  if [[ ${#SERVICES[@]} -gt 0 ]]; then
    filter="${SERVICES[*]}"
  fi
  print_endpoints "$filter"
}

#############################################
# Argument parsing
#############################################

CMD=""

# Load metadata before parsing args so defaults reflect metadata.json
if [[ -n "${STACKCTL_METADATA_FILE:-}" ]]; then
  METADATA_FILE="$STACKCTL_METADATA_FILE"
fi

load_metadata

if [[ -n "${STACKCTL_DEFAULT_RESTART_POLICY:-}" ]]; then
  set_restart_policy_mode "$STACKCTL_DEFAULT_RESTART_POLICY"
  RESTART_POLICY_DEFAULT="$RESTART_POLICY_MODE"
fi

if [[ -n "${STACKCTL_RESTART_POLICY:-}" ]]; then
  set_restart_policy_mode "$STACKCTL_RESTART_POLICY"
fi

if [[ $# -eq 0 ]]; then
  usage
  exit 0
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    start|restart|stop|rebuild|clean|logs|shell|info|status|health|endpoints)
      if [[ -n "$CMD" ]]; then
        error "Multiple commands specified."
      fi
      CMD="$1"
      shift
      ;;
    --profile)
      shift
      [[ $# -gt 0 ]] || error "--profile requires value"
      set_target_mode "profile"
      parse_csv_append "$1" PROFILES
      shift
      ;;
    --service|--services)
      shift
      [[ $# -gt 0 ]] || error "--service requires value"
      set_target_mode "service"
      parse_csv_append "$1" SERVICES
      shift
      ;;
    --all)
      if [[ ${#PROFILES[@]} -gt 0 || ${#SERVICES[@]} -gt 0 ]]; then
        error "--all cannot be combined with --profile/--service"
      fi
      TARGET_MODE="all"
      shift
      ;;
    -f|--file)
      shift
      [[ $# -gt 0 ]] || error "--file requires value"
      COMPOSE_FILE="$1"
      shift
      ;;
    -p|--project-name)
      shift
      [[ $# -gt 0 ]] || error "--project-name requires value"
      PROJECT_NAME="$1"
      shift
      ;;
    --metadata)
      shift
      [[ $# -gt 0 ]] || error "--metadata requires value"
      METADATA_FILE="$1"
      shift
      ;;
    --restart-policy)
      shift
      [[ $# -gt 0 ]] || error "--restart-policy requires value"
      set_restart_policy_mode "$1"
      shift
      ;;
    --version)
      echo "${STACK_NAME} (${STACK_SLUG}) v${STACK_VERSION}"
      echo "source: ${METADATA_FILE}"
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      FORWARDED_ARGS=("$@")
      break
      ;;
    *)
      error "Unknown argument: $1"
      ;;
  esac
done

ensure_command_set

case "$CMD" in
  start)   cmd_start   ;;
  restart) cmd_restart ;;
  stop)    cmd_stop    ;;
  rebuild) cmd_rebuild ;;
  clean)   cmd_clean   ;;
  logs)    cmd_logs    ;;
  shell)   cmd_shell   ;;
  info)    cmd_info    ;;
  status)  cmd_status  ;;
  health)  cmd_health  ;;
  endpoints) cmd_endpoints ;;
  *)       error "Unhandled command: $CMD" ;;
esac

exit 0
