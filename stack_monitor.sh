#!/usr/bin/env bash
set -Eeuo pipefail

# stack_monitor.sh - lightweight stack monitor for docker compose projects
# Uses a small embedded Python helper (stdlib only) to render a refreshing view
# of service state/health/log error signal/connectivity. Defaults come from
# metadata (metadata.json) or environment, so it can be reused across stacks.

TARGET_MODE="all" # all|profile|service
PROFILES=()
SERVICES=()
REFRESH_OVERRIDE=""
METADATA_FILE="${STACKCTL_METADATA_FILE:-metadata.json}"
COMPOSE_FILE_OVERRIDE="${STACK_MON_COMPOSE_FILE:-}"
PROJECT_NAME_OVERRIDE="${STACK_MON_PROJECT:-}"
PROBE_PORTS="${STACK_MON_PROBE_PORTS:-auto}"
UI_MODE="${STACK_MON_UI:-auto}"
VENV_DIR="${STACK_MON_VENV:-.venv_stack_monitor}"
PYTHON_BIN="${STACK_MON_PYTHON:-}"
REQ_TEXTUAL="${STACK_MON_REQ_TEXTUAL:-requirements-textual.txt}"
REQ_PROMPT="${STACK_MON_REQ_PROMPT:-requirements-prompt.txt}"

usage() {
  cat <<EOF
stack_monitor.sh - live TUI-ish view of docker compose services

Usage:
  stack_monitor.sh [options]

Options:
  --all                   Monitor all services (default)
  --profile NAME          Limit to profiles (can repeat or CSV)
  --service NAME          Limit to services (can repeat or CSV)
  --refresh SECONDS       Refresh interval override (env: STACK_MON_REFRESH)
  -f, --file FILE         Compose file override (env: STACK_MON_COMPOSE_FILE)
  -p, --project-name NAME Project name override (env: STACK_MON_PROJECT)
  --metadata FILE         Metadata file (env: STACKCTL_METADATA_FILE) [default: metadata.json]
  --probe-ports [on|off]  Enable/disable port reachability probes (env: STACK_MON_PROBE_PORTS, default: auto)
  --ui MODE               UI: textual|prompt|basic|auto (default: auto; requires 'textual' or 'prompt_toolkit' for those UIs)
  --install-textual       Install textual into a local venv (default: .venv_stack_monitor)
  --install-prompt        Install prompt_toolkit into a local venv (default: .venv_stack_monitor)
  -h, --help              Show this help

Env defaults (also read by the embedded monitor):
  STACK_MON_REFRESH            Refresh interval (seconds)
  STACK_MON_PROFILES           Comma-separated profiles
  STACK_MON_SERVICES           Comma-separated services
  STACK_MON_COMPOSE_FILE       Compose file override
  STACK_MON_PROJECT            Project name override
  STACKCTL_METADATA_FILE       Metadata file path
  STACK_MON_PROBE_PORTS        on|off|auto (auto = on if ports are published)
  STACK_MON_UI                 textual|basic|auto
  STACK_MON_VENV               Virtualenv path for textual (default: .venv_stack_monitor)
  STACK_MON_PYTHON             Python interpreter to use (optional)
  STACK_MON_REQ_TEXTUAL        Requirements file for textual install (default: requirements-textual.txt)
  STACK_MON_REQ_PROMPT         Requirements file for prompt_toolkit install (default: requirements-prompt.txt)
EOF
}

join_csv() {
  local IFS=','; echo "$*"
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

ensure_target_mode() {
  local new="$1"
  if [[ "$TARGET_MODE" != "all" && "$TARGET_MODE" != "$new" ]]; then
    printf '[stack-monitor][ERROR] Cannot mix target modes (profile/service/all)\n' >&2
    exit 1
  fi
  TARGET_MODE="$new"
}

install_textual() {
  local venv="${STACK_MON_VENV:-.venv_stack_monitor}"
  local py="${STACK_MON_PYTHON:-}"
  if [[ -z "$py" ]]; then
    if command -v python3 >/dev/null 2>&1; then
      py="python3"
    elif command -v python >/dev/null 2>&1; then
      py="python"
    else
      printf '[stack-monitor][ERROR] python/python3 not found; cannot create venv.\n' >&2
      exit 1
    fi
  fi
  printf '[stack-monitor] Creating/updating venv at %s using %s...\n' "$venv" "$py"
  "$py" -m venv "$venv" || {
    printf '[stack-monitor][ERROR] Failed to create venv at %s.\n' "$venv" >&2
    exit 1
  }
  local pip_bin=""
  if [[ -x "$venv/bin/pip" ]]; then
    pip_bin="$venv/bin/pip"
  elif [[ -x "$venv/bin/pip3" ]]; then
    pip_bin="$venv/bin/pip3"
  else
    printf '[stack-monitor][ERROR] pip not found in venv at %s.\n' "$venv" >&2
    exit 1
  fi
  local req="${REQ_TEXTUAL}"
  printf '[stack-monitor] Installing textual (%s) into %s...\n' "$req" "$venv"
  if [[ -f "$req" ]]; then
    "$pip_bin" install --upgrade pip && "$pip_bin" install -r "$req" || {
      printf '[stack-monitor][ERROR] Failed to install textual from %s into %s.\n' "$req" "$venv" >&2
      exit 1
    }
  else
    "$pip_bin" install --upgrade pip textual || {
      printf '[stack-monitor][ERROR] Failed to install textual into %s.\n' "$venv" >&2
      exit 1
    }
  fi
  printf '[stack-monitor] textual installed successfully into %s.\n' "$venv"
  exit 0
}

install_prompt() {
  local venv="${STACK_MON_VENV:-.venv_stack_monitor}"
  local py="${STACK_MON_PYTHON:-}"
  if [[ -z "$py" ]]; then
    if command -v python3 >/dev/null 2>&1; then
      py="python3"
    elif command -v python >/dev/null 2>&1; then
      py="python"
    else
      printf '[stack-monitor][ERROR] python/python3 not found; cannot create venv.\n' >&2
      exit 1
    fi
  fi
  printf '[stack-monitor] Creating/updating venv at %s using %s...\n' "$venv" "$py"
  "$py" -m venv "$venv" || {
    printf '[stack-monitor][ERROR] Failed to create venv at %s.\n' "$venv" >&2
    exit 1
  }
  local pip_bin=""
  if [[ -x "$venv/bin/pip" ]]; then
    pip_bin="$venv/bin/pip"
  elif [[ -x "$venv/bin/pip3" ]]; then
    pip_bin="$venv/bin/pip3"
  else
    printf '[stack-monitor][ERROR] pip not found in venv at %s.\n' "$venv" >&2
    exit 1
  fi
  local req="${REQ_PROMPT}"
  printf '[stack-monitor] Installing prompt_toolkit (%s) into %s...\n' "$req" "$venv"
  if [[ -f "$req" ]]; then
    "$pip_bin" install --upgrade pip && "$pip_bin" install -r "$req" || {
      printf '[stack-monitor][ERROR] Failed to install prompt_toolkit from %s into %s.\n' "$req" "$venv" >&2
      exit 1
    }
  else
    "$pip_bin" install --upgrade pip prompt_toolkit || {
      printf '[stack-monitor][ERROR] Failed to install prompt_toolkit into %s.\n' "$venv" >&2
      exit 1
    }
  fi
  printf '[stack-monitor] prompt_toolkit installed successfully into %s.\n' "$venv"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      shift; [[ $# -gt 0 ]] || { usage; exit 1; }
      ensure_target_mode "profile"
      parse_csv_append "$1" PROFILES
      shift
      ;;
    --service|--services)
      shift; [[ $# -gt 0 ]] || { usage; exit 1; }
      ensure_target_mode "service"
      parse_csv_append "$1" SERVICES
      shift
      ;;
    --all)
      TARGET_MODE="all"; shift
      ;;
    --refresh)
      shift; [[ $# -gt 0 ]] || { usage; exit 1; }
      REFRESH_OVERRIDE="$1"; shift
      ;;
    -f|--file)
      shift; [[ $# -gt 0 ]] || { usage; exit 1; }
      COMPOSE_FILE_OVERRIDE="$1"; shift
      ;;
    -p|--project-name)
      shift; [[ $# -gt 0 ]] || { usage; exit 1; }
      PROJECT_NAME_OVERRIDE="$1"; shift
      ;;
    --metadata)
      shift; [[ $# -gt 0 ]] || { usage; exit 1; }
      METADATA_FILE="$1"; shift
      ;;
    --probe-ports)
      shift; [[ $# -gt 0 ]] || { usage; exit 1; }
      PROBE_PORTS="$1"; shift
      ;;
    --ui)
      shift; [[ $# -gt 0 ]] || { usage; exit 1; }
      UI_MODE="$1"; shift
      ;;
    --install-textual)
      install_textual
      ;;
    --install-prompt)
      install_prompt
      ;;
    -h|--help)
      usage; exit 0
      ;;
    *)
      printf '[stack-monitor][ERROR] Unknown argument: %s\n' "$1" >&2
      usage
      exit 1
      ;;
  esac
done

if ! command -v python3 >/dev/null 2>&1; then
  printf '[stack-monitor][ERROR] python3 is required.\n' >&2
  exit 1
fi

# Export config for the embedded Python monitor
export STACKCTL_METADATA_FILE="$METADATA_FILE"
[[ -n "$REFRESH_OVERRIDE" ]] && export STACK_MON_REFRESH="$REFRESH_OVERRIDE"
[[ -n "$COMPOSE_FILE_OVERRIDE" ]] && export STACK_MON_COMPOSE_FILE="$COMPOSE_FILE_OVERRIDE"
[[ -n "$PROJECT_NAME_OVERRIDE" ]] && export STACK_MON_PROJECT="$PROJECT_NAME_OVERRIDE"
[[ -n "$PROBE_PORTS" ]] && export STACK_MON_PROBE_PORTS="$PROBE_PORTS"

if [[ ${#PROFILES[@]} -gt 0 ]]; then
  STACK_MON_PROFILES=$(join_csv "${PROFILES[@]}")
  export STACK_MON_PROFILES
fi

if [[ ${#SERVICES[@]} -gt 0 ]]; then
  STACK_MON_SERVICES=$(join_csv "${SERVICES[@]}")
  export STACK_MON_SERVICES
fi

use_textual=false
use_prompt=false
if [[ "$UI_MODE" == "textual" ]]; then
  use_textual=true
elif [[ "$UI_MODE" == "auto" ]]; then
  :
elif [[ "$UI_MODE" == "prompt" ]]; then
  use_prompt=true
fi

python_search() {
  if [[ -n "$PYTHON_BIN" ]]; then
    echo "$PYTHON_BIN"; return 0
  fi
  if [[ -x "$VENV_DIR/bin/python3" ]]; then
    echo "$VENV_DIR/bin/python3"; return 0
  fi
  if [[ -x "$VENV_DIR/bin/python" ]]; then
    echo "$VENV_DIR/bin/python"; return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    echo "python3"; return 0
  fi
  if command -v python >/dev/null 2>&1; then
    echo "python"; return 0
  fi
  return 1
}

PYTHON_BIN_RESOLVED=$(python_search || true)
if [[ -z "$PYTHON_BIN_RESOLVED" ]]; then
  printf '[stack-monitor][ERROR] No python interpreter found.\n' >&2
  exit 1
fi

if [[ "$UI_MODE" == "auto" ]]; then
  if "$PYTHON_BIN_RESOLVED" - <<'PY' >/dev/null 2>&1
import importlib
import sys
sys.exit(0 if importlib.util.find_spec("textual") else 1)
PY
  then
    use_textual=true
  elif "$PYTHON_BIN_RESOLVED" - <<'PY' >/dev/null 2>&1
import importlib
import sys
sys.exit(0 if importlib.util.find_spec("prompt_toolkit") else 1)
PY
  then
    use_prompt=true
  fi
fi

if [[ "$use_textual" == true ]]; then
  if [[ ! -f "stack_monitor_textual.py" ]]; then
    printf '[stack-monitor][ERROR] textual UI selected but stack_monitor_textual.py not found.\n' >&2
    exit 1
  fi
  if [[ -d "$VENV_DIR/bin" ]]; then
    PATH="$VENV_DIR/bin:$PATH"
    export PATH
  fi
  exec "$PYTHON_BIN_RESOLVED" stack_monitor_textual.py
fi

if [[ "$use_prompt" == true ]]; then
  if [[ ! -f "stack_monitor_prompt.py" ]]; then
    printf '[stack-monitor][ERROR] prompt UI selected but stack_monitor_prompt.py not found.\n' >&2
    exit 1
  fi
  if [[ -d "$VENV_DIR/bin" ]]; then
    PATH="$VENV_DIR/bin:$PATH"
    export PATH
  fi
  exec "$PYTHON_BIN_RESOLVED" stack_monitor_prompt.py
fi

python3 - <<'PY'
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time

ERR_PAT = re.compile(r"(ERROR|Error|error|CRIT|FATAL)")
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")

def eprint(*args, **kwargs):
  print(*args, file=sys.stderr, **kwargs)

def detect_compose():
  candidates = [["docker", "compose"], ["docker-compose"]]
  for cand in candidates:
    try:
      subprocess.run(cand + ["version"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
      return cand
    except Exception:
      continue
  eprint("[stack-monitor][ERROR] Neither 'docker compose' nor 'docker-compose' found.")
  sys.exit(1)

def load_metadata(path):
  if not path or not os.path.isfile(path):
    return {}
  try:
    with open(path, "r", encoding="utf-8") as f:
      return json.load(f)
  except Exception as exc:
    eprint(f"[stack-monitor][WARN] Failed to read metadata {path}: {exc}")
    return {}

def env_csv(name):
  raw = os.environ.get(name, "")
  parts = []
  for chunk in raw.split(","):
    chunk = chunk.strip()
    if chunk:
      parts.append(chunk)
  return parts

def build_compose_base(compose_cmd, compose_file, project, profiles):
  base = compose_cmd + ["-f", compose_file]
  if project:
    base += ["-p", project]
  for p in profiles:
    base += ["--profile", p]
  return base

def run_capture(cmd):
  return subprocess.check_output(cmd, text=True)

def try_run_capture(cmd):
  try:
    return subprocess.check_output(cmd, text=True)
  except subprocess.CalledProcessError as exc:
    return exc.output

def list_profiles(base_cmd):
  try:
    out = run_capture(base_cmd + ["config", "--profiles"])
    return [ln.strip() for ln in out.splitlines() if ln.strip()]
  except Exception:
    return []

def list_services(base_cmd):
  out = run_capture(base_cmd + ["config", "--services"])
  return [ln.strip() for ln in out.splitlines() if ln.strip()]

def compose_config_json(base_cmd):
  try:
    out = run_capture(base_cmd + ["config", "--format", "json"])
    return json.loads(out)
  except Exception:
    return {}

def get_container_id(base_cmd, service):
  out = try_run_capture(base_cmd + ["ps", "-q", service])
  cid = out.strip().splitlines()
  if not cid:
    return ""
  return cid[0]

def inspect_container(cid):
  try:
    out = run_capture(["docker", "inspect", cid])
    data = json.loads(out)[0]
    state = data.get("State", {}) or {}
    status = state.get("Status", "unknown")
    health = (state.get("Health") or {}).get("Status", "n/a")
    started_at = state.get("StartedAt", "")
    return {"status": status, "health": health, "started_at": started_at}
  except Exception:
    return {"status": "unknown", "health": "n/a", "started_at": ""}

def count_errors(cid, cache, now, window=10, tail=80, since="45s", enabled=True):
  if not enabled:
    return -2  # sentinel for disabled
  last = cache.get(cid)
  if last and now - last["ts"] < window:
    return last["count"]
  try:
    out = subprocess.check_output(["docker", "logs", "--tail", str(tail), "--since", since, cid], text=True, stderr=subprocess.STDOUT)
    cnt = 0
    for line in out.splitlines():
      if ERR_PAT.search(line):
        cnt += 1
    cache[cid] = {"ts": now, "count": cnt}
    return cnt
  except Exception:
    cache[cid] = {"ts": now, "count": -1}
    return -1

def probe_ports(port_defs):
  if not port_defs:
    return "-"
  ok = 0
  total = 0
  for host, port in port_defs:
    total += 1
    try:
      with socket.create_connection((host, port), timeout=0.5):
        ok += 1
    except Exception:
      continue
  if total == 0:
    return "-"
  if ok == total:
    return f"OK({ok}/{total})"
  if ok == 0:
    return "FAIL"
  return f"PART({ok}/{total})"

def colorize(text, color_code, enabled):
  if not enabled:
    return text
  return f"\033[{color_code}m{text}\033[0m"

def visible_len(s):
  return len(ANSI_RE.sub("", s))

def pad_field(s, width):
  return s + " " * max(0, width - visible_len(s))

def clear_screen(enabled):
  if enabled:
    sys.stdout.write("\033[H\033[2J")
    sys.stdout.flush()

def render(rows, header_lines, tty):
  clear_screen(tty)
  for line in header_lines:
    print(line)
  if not rows:
    print("No services to display.")
    return
  cols = shutil.get_terminal_size((120, 40)).columns
  cid_w = 13
  svc_w = max(12, min(28, max(visible_len(r["service_disp"]) for r in rows) + 2))
  state_w = 14
  health_w = 12
  err_w = 12
  port_w = 16
  header = (
    f"{pad_field('Container', cid_w)}"
    f"{pad_field('Service', svc_w)}"
    f"{pad_field('State', state_w)}"
    f"{pad_field('Health', health_w)}"
    f"{pad_field('Errors', err_w)}"
    f"{pad_field('Ports', port_w)}"
  )
  print(header)
  print("-" * min(cols, len(header)))
  for r in rows:
    print(
      f"{pad_field(r['cid_disp'], cid_w)}"
      f"{pad_field(r['service_disp'], svc_w)}"
      f"{pad_field(r['state_disp'], state_w)}"
      f"{pad_field(r['health_disp'], health_w)}"
      f"{pad_field(r['errors_disp'], err_w)}"
      f"{pad_field(r['ports_disp'], port_w)}"
    )
  sys.stdout.flush()

def build_ports_map(cfg):
  port_map = {}
  services = cfg.get("services", {}) if isinstance(cfg, dict) else {}
  for name, data in services.items():
    ports = data.get("ports") or []
    host_ports = []
    for entry in ports:
      if isinstance(entry, dict):
        host = entry.get("host_ip") or "localhost"
        published = entry.get("published")
        if published:
          host_ports.append((host, int(str(published))))
      else:
        part = str(entry)
        proto_split = part.split("/", 1)[0]
        bits = proto_split.split(":")
        if len(bits) == 3:
          host, pub, _ = bits
        elif len(bits) == 2:
          host = "localhost"
          pub, _ = bits
        else:
          continue
        if pub:
          host_ports.append((host or "localhost", int(pub)))
    port_map[name] = host_ports
  return port_map

def main():
  tty = sys.stdout.isatty()
  metadata_path = os.environ.get("STACKCTL_METADATA_FILE", "metadata.json")
  meta = load_metadata(metadata_path)

  stack = meta.get("stack", {}) or {}
  stack_name = stack.get("name", "Stack")
  stack_slug = stack.get("slug", "stack")
  stack_ver = stack.get("version", "dev")

  refresh = os.environ.get("STACK_MON_REFRESH")
  if refresh:
    try:
      refresh = float(refresh)
    except ValueError:
      refresh = 1.0
  else:
    refresh = meta.get("monitor", {}).get("refresh_seconds", 1.0)
  if refresh <= 0:
    refresh = 1.0

  compose_file = os.environ.get("STACK_MON_COMPOSE_FILE") or meta.get("compose", {}).get("file") or "docker-compose.yml"
  project = os.environ.get("STACK_MON_PROJECT") or meta.get("compose", {}).get("project_name_default") or ""

  profiles = env_csv("STACK_MON_PROFILES")
  services = env_csv("STACK_MON_SERVICES")

  compose_cmd = detect_compose()
  auto_profiles = False
  if not profiles and not services:
    auto_profiles = True

  base_for_profiles = build_compose_base(compose_cmd, compose_file, project, [])
  if auto_profiles:
    profiles = list_profiles(base_for_profiles)

  base_cmd = build_compose_base(compose_cmd, compose_file, project, profiles)
  try:
    if not services:
      services = list_services(base_cmd)
  except Exception as exc:
    eprint(f"[stack-monitor][ERROR] Failed to list services: {exc}")
    sys.exit(1)

  cfg_json = compose_config_json(base_cmd)
  port_map = build_ports_map(cfg_json) if cfg_json else {}

  probe_setting = os.environ.get("STACK_MON_PROBE_PORTS", "auto").lower()
  probe_enabled = True
  if probe_setting in ("off", "false", "0", "no"):
    probe_enabled = False
  elif probe_setting == "on":
    probe_enabled = True
  elif probe_setting == "auto":
    probe_enabled = any(port_map.get(svc) for svc in services)

  log_cache = {}
  profiles_label = ",".join(profiles) if profiles else "(none)"
  services_label = ",".join(services) if services else "(none)"
  header_static = [
    f"{stack_name} ({stack_slug}) v{stack_ver} | project: {project or '-'}",
    f"compose: {compose_file} | profiles: {profiles_label} | services: {services_label}",
    f"refresh: {refresh}s | metadata: {metadata_path} | port probing: {'on' if probe_enabled else 'off'}",
  ]

  while True:
    now = time.time()
    rows = []
    for svc in services:
      cid = get_container_id(base_cmd, svc)
      if not cid:
        state = "down"
        health = "-"
        err_txt = "-"
        ports = "-"
      else:
        info = inspect_container(cid)
        state = info["status"]
        health = info["health"]
        err_cnt = count_errors(
          cid,
          log_cache,
          now,
          enabled=os.environ.get("STACK_MON_LOG_ERRORS", "on").lower() not in ("off", "false", "0", "no"),
        )
        if err_cnt == -2:
          err_txt = "-"
        elif err_cnt < 0:
          err_txt = "n/a"
        else:
          err_txt = str(err_cnt)
        ports = "-"
        if probe_enabled:
          ports = probe_ports(port_map.get(svc, []))
      rows.append(
        {
          "service": svc,
          "state": state,
          "health": health,
          "errors": err_txt,
          "ports": ports,
          "cid": cid[:12] if cid else "-",
        }
      )

    # Colorize based on state/health/errors
    for r in rows:
      state = r["state"]
      health = r["health"]
      err = r["errors"]
      ports_val = r["ports"]

      if state == "running":
        r["state_disp"] = colorize(state, "32", tty)
      elif state in ("restarting", "starting"):
        r["state_disp"] = colorize(state, "33", tty)
      else:
        r["state_disp"] = colorize(state, "31", tty)

      if health in ("healthy", "n/a"):
        r["health_disp"] = colorize(health, "32", tty)
      elif health == "starting":
        r["health_disp"] = colorize(health, "33", tty)
      else:
        r["health_disp"] = colorize(health, "31", tty)

      if err == "-" or err == "n/a":
        r["errors_disp"] = colorize(err, "33", tty) if err == "n/a" else err
      else:
        try:
          cnt = int(err)
          if cnt == 0:
            r["errors_disp"] = colorize(err, "32", tty)
          elif cnt < 3:
            r["errors_disp"] = colorize(err, "33", tty)
          else:
            r["errors_disp"] = colorize(err, "31", tty)
        except ValueError:
          r["errors_disp"] = err

      if ports_val.startswith("OK"):
        r["ports_disp"] = colorize(ports_val, "32", tty)
      elif ports_val.startswith("FAIL"):
        r["ports_disp"] = colorize(ports_val, "31", tty)
      elif ports_val.startswith("PART"):
        r["ports_disp"] = colorize(ports_val, "33", tty)
      else:
        r["ports_disp"] = ports_val

      r["cid_disp"] = r["cid"]
      r["service_disp"] = r["service"]

    render(rows, header_static, tty)

    if not tty:
      break
    time.sleep(refresh)

if __name__ == "__main__":
  try:
    main()
  except KeyboardInterrupt:
    pass
PY
