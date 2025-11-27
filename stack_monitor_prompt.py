#!/usr/bin/env python3
"""
prompt_toolkit-based stack monitor for docker compose projects.

Uses the same env/metadata config as the basic monitor:
  STACKCTL_METADATA_FILE, STACK_MON_REFRESH, STACK_MON_PROFILES, STACK_MON_SERVICES,
  STACK_MON_COMPOSE_FILE, STACK_MON_PROJECT, STACK_MON_PROBE_PORTS, STACK_MON_LOG_ERRORS.

Dependencies: prompt_toolkit (install via stack_monitor.sh --install-prompt).
"""
import asyncio
import json
import os
import re
import socket
import subprocess
import sys
import time
from typing import Dict, List, Tuple

from prompt_toolkit.application import Application
from prompt_toolkit.formatted_text import FormattedText
from prompt_toolkit.key_binding import KeyBindings
from prompt_toolkit.layout import HSplit, Layout
from prompt_toolkit.styles import Style
from prompt_toolkit.widgets import Frame, TextArea

ERR_PAT = re.compile(r"(ERROR|Error|error|CRIT|FATAL)")


def eprint(*args, **kwargs):
  print(*args, file=sys.stderr, **kwargs)


def detect_compose() -> List[str]:
  candidates = [["docker", "compose"], ["docker-compose"]]
  for cand in candidates:
    try:
      subprocess.run(cand + ["version"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
      return cand
    except Exception:
      continue
  eprint("[stack-monitor][ERROR] Neither 'docker compose' nor 'docker-compose' found.")
  sys.exit(1)


def load_metadata(path: str) -> Dict:
  if not path or not os.path.isfile(path):
    return {}
  try:
    with open(path, "r", encoding="utf-8") as f:
      return json.load(f)
  except Exception as exc:
    eprint(f"[stack-monitor][WARN] Failed to read metadata {path}: {exc}")
    return {}


def env_csv(name: str) -> List[str]:
  raw = os.environ.get(name, "")
  parts = []
  for chunk in raw.split(","):
    chunk = chunk.strip()
    if chunk:
      parts.append(chunk)
  return parts


def run_capture(cmd: List[str]) -> str:
  return subprocess.check_output(cmd, text=True)


def list_profiles(compose_cmd: List[str], compose_file: str, project: str) -> List[str]:
  try:
    out = run_capture(compose_cmd + ["-f", compose_file, "-p", project, "config", "--profiles"])
    return [ln.strip() for ln in out.splitlines() if ln.strip()]
  except Exception:
    return []


def list_services(compose_cmd: List[str], compose_file: str, project: str, profiles: List[str]) -> List[str]:
  base = compose_cmd + ["-f", compose_file]
  if project:
    base += ["-p", project]
  for p in profiles:
    base += ["--profile", p]
  out = run_capture(base + ["config", "--services"])
  return [ln.strip() for ln in out.splitlines() if ln.strip()]


def compose_config_json(base_cmd: List[str]) -> Dict:
  try:
    out = run_capture(base_cmd + ["config", "--format", "json"])
    return json.loads(out)
  except Exception:
    return {}


def build_base_cmd(compose_cmd: List[str], compose_file: str, project: str, profiles: List[str]) -> List[str]:
  base = compose_cmd + ["-f", compose_file]
  if project:
    base += ["-p", project]
  for p in profiles:
    base += ["--profile", p]
  return base


def get_container_id(base_cmd: List[str], service: str) -> str:
  try:
    out = run_capture(base_cmd + ["ps", "-q", service])
    cid = out.strip().splitlines()
    if not cid:
      return ""
    return cid[0]
  except Exception:
    return ""


def inspect_container(cid: str) -> Dict:
  try:
    out = run_capture(["docker", "inspect", cid])
    data = json.loads(out)[0]
    state = data.get("State", {}) or {}
    status = state.get("Status", "unknown")
    health = (state.get("Health") or {}).get("Status", "n/a")
    return {"status": status, "health": health}
  except Exception:
    return {"status": "unknown", "health": "n/a"}


def count_errors(cid: str, cache: Dict, now: float, window: float = 10, tail: int = 80, since: str = "45s", enabled: bool = True) -> int:
  if not enabled:
    return -2
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


def probe_ports(port_defs: List[Tuple[str, int]]) -> str:
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
      pass
  if total == 0:
    return "-"
  if ok == total:
    return f"OK({ok}/{total})"
  if ok == 0:
    return "FAIL"
  return f"PART({ok}/{total})"


def build_ports_map(cfg: Dict) -> Dict[str, List[Tuple[str, int]]]:
  port_map: Dict[str, List[Tuple[str, int]]] = {}
  services = cfg.get("services", {}) if isinstance(cfg, dict) else {}
  for name, data in services.items():
    ports = data.get("ports") or []
    host_ports: List[Tuple[str, int]] = []
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


def build_context():
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
  if not refresh or refresh <= 0:
    refresh = 1.0

  compose_file = os.environ.get("STACK_MON_COMPOSE_FILE") or meta.get("compose", {}).get("file") or "docker-compose.yml"
  project = os.environ.get("STACK_MON_PROJECT") or meta.get("compose", {}).get("project_name_default") or ""

  profiles = env_csv("STACK_MON_PROFILES")
  services = env_csv("STACK_MON_SERVICES")

  compose_cmd = detect_compose()
  if not profiles and not services:
    profiles = list_profiles(compose_cmd, compose_file, project)

  base_cmd = build_base_cmd(compose_cmd, compose_file, project, profiles)
  if not services:
    services = list_services(compose_cmd, compose_file, project, profiles)

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

  log_errors_enabled = os.environ.get("STACK_MON_LOG_ERRORS", "on").lower() not in ("off", "false", "0", "no")

  return {
    "stack_name": stack_name,
    "stack_slug": stack_slug,
    "stack_version": stack_ver,
    "compose_file": compose_file,
    "project": project,
    "profiles": profiles,
    "services": services,
    "port_map": port_map,
    "base_cmd": base_cmd,
    "refresh": refresh,
    "probe_ports_enabled": probe_enabled,
    "log_errors_enabled": log_errors_enabled,
    "metadata_path": metadata_path,
  }


def format_header(ctx) -> str:
  profiles_label = ",".join(ctx["profiles"]) if ctx["profiles"] else "(none)"
  services_label = ",".join(ctx["services"]) if ctx["services"] else "(none)"
  port_label = "on" if ctx["probe_ports_enabled"] else "off"
  return (
    f"{ctx['stack_name']} ({ctx['stack_slug']}) v{ctx['stack_version']}\n"
    f"project: {ctx['project'] or '-'} | compose: {ctx['compose_file']}\n"
    f"profiles: {profiles_label} | services: {services_label}\n"
    f"refresh: {ctx['refresh']}s | metadata: {ctx['metadata_path']} | port probing: {port_label}\n"
    "keys: q quit, r refresh"
  )


def build_rows(ctx, log_cache, now):
  rows = []
  for svc in ctx["services"]:
    cid = get_container_id(ctx["base_cmd"], svc)
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
        enabled=ctx["log_errors_enabled"],
      )
      if err_cnt == -2:
        err_txt = "-"
      elif err_cnt < 0:
        err_txt = "n/a"
      else:
        err_txt = str(err_cnt)
      ports = "-"
      if ctx["probe_ports_enabled"]:
        ports = probe_ports(ctx["port_map"].get(svc, []))

    rows.append(
      {
        "cid": cid[:12] if cid else "-",
        "service": svc,
        "state": state,
        "health": health,
        "errors": err_txt,
        "ports": ports,
      }
    )
  return rows


def style_state(text: str) -> Tuple[str, str]:
  if text == "running":
    return ("class:green", text)
  if text in ("restarting", "starting"):
    return ("class:yellow", text)
  return ("class:red", text)


def style_health(text: str) -> Tuple[str, str]:
  if text in ("healthy", "n/a"):
    return ("class:green", text)
  if text == "starting":
    return ("class:yellow", text)
  return ("class:red", text)


def style_errors(text: str) -> Tuple[str, str]:
  if text in ("-", "n/a"):
    return ("class:yellow", text) if text == "n/a" else ("", text)
  try:
    cnt = int(text)
    if cnt == 0:
      return ("class:green", text)
    if cnt < 3:
      return ("class:yellow", text)
    return ("class:red", text)
  except ValueError:
    return ("", text)


def style_ports(text: str) -> Tuple[str, str]:
  if text.startswith("OK"):
    return ("class:green", text)
  if text.startswith("FAIL"):
    return ("class:red", text)
  if text.startswith("PART"):
    return ("class:yellow", text)
  return ("", text)


def render_table(rows) -> str:
  cid_w = 13
  svc_w = max(12, min(28, max(len(r["service"]) for r in rows) + 2)) if rows else 12
  state_w = 14
  health_w = 12
  err_w = 12
  port_w = 16
  header = f"{'Container'.ljust(cid_w)}{'Service'.ljust(svc_w)}{'State'.ljust(state_w)}{'Health'.ljust(health_w)}{'Errors'.ljust(err_w)}{'Ports'.ljust(port_w)}"
  lines = [header, "-" * len(header)]
  for r in rows:
    lines.append(
      f"{r['cid'].ljust(cid_w)}"
      f"{r['service'].ljust(svc_w)}"
      f"{r['state'].ljust(state_w)}"
      f"{r['health'].ljust(health_w)}"
      f"{r['errors'].ljust(err_w)}"
      f"{r['ports'].ljust(port_w)}"
    )
  return "\n".join(lines)

def ansi_color(text: str, color: str) -> str:
  code = {"green": "32", "yellow": "33", "red": "31"}.get(color, "")
  if not code:
    return text
  return f"\033[{code}m{text}\033[0m"


class MonitorAppPT:
  def __init__(self, ctx):
    self.ctx = ctx
    self.log_cache: Dict[str, Dict] = {}
    self.header = TextArea(style="class:header", text=format_header(ctx), focusable=False, scrollbar=False)
    self.body = TextArea(style="class:body", text="", focusable=False, scrollbar=True, wrap_lines=False)

    kb = KeyBindings()
    @kb.add("q")
    def _(event):
      event.app.exit()
    @kb.add("r")
    def _(event):
      asyncio.create_task(self.refresh())

    root_container = HSplit([
      Frame(self.header),
      Frame(self.body),
    ])
    self.style = Style.from_dict(
      {
        "header": "bold",
        "body": "",
        "green": "fg:ansigreen",
        "yellow": "fg:ansiyellow",
        "red": "fg:ansired",
      }
    )
    self.app = Application(
      layout=Layout(root_container),
      key_bindings=kb,
      full_screen=True,
      mouse_support=False,
      style=self.style,
    )
    self.refresh_interval = self.ctx["refresh"]
    self._running = False

  async def refresh(self):
    now = time.time()
    rows = build_rows(self.ctx, self.log_cache, now)
    table_text = render_table(rows)
    # Apply simple ANSI colors
    lines = table_text.splitlines()
    if len(lines) >= 2:
      colored_lines = [lines[0], lines[1]]
      cid_w = 13
      svc_w = max(12, min(28, max(len(r["service"]) for r in rows) + 2)) if rows else 12
      state_w = 14
      health_w = 12
      err_w = 12
      port_w = 16
      for r in rows:
        state_style, health_style, err_style, port_style = style_state(r["state"])[0], style_health(r["health"])[0], style_errors(r["errors"])[0], style_ports(r["ports"])[0]
        colored_lines.append(
          f"{r['cid'].ljust(cid_w)}"
          f"{r['service'].ljust(svc_w)}"
          f"{ansi_color(r['state'].ljust(state_w), state_style.replace('class:', ''))}"
          f"{ansi_color(r['health'].ljust(health_w), health_style.replace('class:', ''))}"
          f"{ansi_color(r['errors'].ljust(err_w), err_style.replace('class:', ''))}"
          f"{ansi_color(r['ports'].ljust(port_w), port_style.replace('class:', ''))}"
        )
      table_text = "\n".join(colored_lines)
    self.header.text = format_header(self.ctx)
    self.body.text = table_text

  async def run(self):
    self._running = True
    asyncio.create_task(self._ticker())
    await self.refresh()
    try:
      await self.app.run_async()
    finally:
      self._running = False

  async def _ticker(self):
    while self._running:
      await asyncio.sleep(self.refresh_interval)
      await self.refresh()


async def amain():
  ctx = build_context()
  app = MonitorAppPT(ctx)
  await app.run()


def main():
  try:
    asyncio.run(amain())
  except KeyboardInterrupt:
    pass


if __name__ == "__main__":
  main()
