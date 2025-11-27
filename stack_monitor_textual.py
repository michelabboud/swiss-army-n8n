#!/usr/bin/env python3
"""
Textual-based stack monitor for docker compose projects.

- Uses metadata.json (or STACKCTL_METADATA_FILE/--metadata from the wrapper) to pick defaults.
- Same env overrides as the basic monitor:
  STACK_MON_REFRESH, STACK_MON_PROFILES, STACK_MON_SERVICES,
  STACK_MON_COMPOSE_FILE, STACK_MON_PROJECT, STACK_MON_PROBE_PORTS,
  STACK_MON_LOG_ERRORS.
- Designed to be called from stack_monitor.sh with --ui textual (or auto when available).
"""
import json
import os
import re
import socket
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import Dict, List, Tuple

import textwrap
from rich.text import Text
from textual import events
from textual.app import App, ComposeResult
from textual.containers import Vertical
from textual.reactive import reactive
from textual.widgets import DataTable, Static

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

def build_service_meta(cfg: Dict) -> List[Tuple[str, List[str]]]:
  meta: List[Tuple[str, List[str]]] = []
  services = cfg.get("services", {}) if isinstance(cfg, dict) else {}
  for name, data in services.items():
    profs = data.get("profiles") or []
    meta.append((name, profs))
  return meta


@dataclass
class ComposeContext:
  stack_name: str
  stack_slug: str
  stack_version: str
  compose_file: str
  project: str
  profiles: List[str]
  services: List[str]
  port_map: Dict[str, List[Tuple[str, int]]]
  service_meta: List[Tuple[str, List[str]]]
  base_cmd: List[str]
  refresh: float
  probe_ports_enabled: bool
  log_errors_enabled: bool
  metadata_path: str


def build_context() -> ComposeContext:
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
  service_meta = build_service_meta(cfg_json) if cfg_json else []

  probe_setting = os.environ.get("STACK_MON_PROBE_PORTS", "auto").lower()
  probe_enabled = True
  if probe_setting in ("off", "false", "0", "no"):
    probe_enabled = False
  elif probe_setting == "on":
    probe_enabled = True
  elif probe_setting == "auto":
    probe_enabled = any(port_map.get(svc) for svc in services)

  log_errors_enabled = os.environ.get("STACK_MON_LOG_ERRORS", "on").lower() not in ("off", "false", "0", "no")

  return ComposeContext(
    stack_name=stack_name,
    stack_slug=stack_slug,
    stack_version=stack_ver,
    compose_file=compose_file,
    project=project,
    profiles=profiles,
    services=services,
    port_map=port_map,
    service_meta=service_meta,
    base_cmd=base_cmd,
    refresh=refresh,
    probe_ports_enabled=probe_enabled,
    log_errors_enabled=log_errors_enabled,
    metadata_path=metadata_path,
  )


class MonitorApp(App):
  """Textual monitor app."""

  CSS = """
  Screen {
    layout: vertical;
  }
  #header {
    dock: top;
    padding: 1 1;
  }
  #table {
    dock: top;
  }
  """

  BINDINGS = [("q", "quit", "Quit"), ("r", "refresh_now", "Refresh now")]

  ctx: ComposeContext
  table: DataTable
  header: Static
  last_refresh = reactive(0.0)

  def __init__(self, ctx: ComposeContext):
    super().__init__()
    self.ctx = ctx
    self.log_cache: Dict[str, Dict] = {}

  def compose(self) -> ComposeResult:
    self.header = Static(id="header")
    self.table = DataTable(id="table", zebra_stripes=True)
    yield Vertical(self.header, self.table)

  def on_mount(self) -> None:
    self.table.clear(columns=True)
    self.table.add_columns("Container", "Service", "State", "Health", "Errors", "Ports")
    self.set_interval(self.ctx.refresh, self.refresh_data)
    self.refresh_data()

  def action_quit(self) -> None:
    self.exit()

  def action_refresh_now(self) -> None:
    self.refresh_data()

  def _format_header(self) -> str:
    port_label = "on" if self.ctx.probe_ports_enabled else "off"
    line1 = f"{self.ctx.stack_name} ({self.ctx.stack_slug}) v{self.ctx.stack_version}"
    line2 = f"project: {self.ctx.project or '-'} | compose: {self.ctx.compose_file}"
    sep_len = max(len(line1), len(line2), 60)

    def wrap_list(label: str, items: List[str]) -> str:
      if not items:
        return f"{label}: (none)"
      text = ", ".join(items)
      first = f"{label}: "
      return textwrap.fill(
        text,
        width=sep_len,
        initial_indent=first,
        subsequent_indent=" " * len(first),
      )

    profiles_line = wrap_list("profiles", self.ctx.profiles)
    services_line = wrap_list("services", self.ctx.services)

    return "\n".join(
      [
        line1,
        line2,
        "=" * sep_len,
        profiles_line,
        services_line,
        f"refresh: {self.ctx.refresh}s",
        f"port probing: {port_label}",
        f"metadata: {self.ctx.metadata_path}",
        "",
        "keys: q quit, r refresh",
      ]
    )

  def _row_styles(self, state: str, health: str, err: str, ports: str) -> Tuple[str, str, str, str]:
    if state == "running":
      state_style = "green"
    elif state in ("restarting", "starting"):
      state_style = "yellow"
    else:
      state_style = "red"

    if health in ("healthy", "n/a"):
      health_style = "green"
    elif health == "starting":
      health_style = "yellow"
    else:
      health_style = "red"

    if err in ("-", "n/a"):
      err_style = "yellow" if err == "n/a" else ""
    else:
      try:
        cnt = int(err)
        if cnt == 0:
          err_style = "green"
        elif cnt < 3:
          err_style = "yellow"
        else:
          err_style = "red"
      except ValueError:
        err_style = ""

    if ports.startswith("OK"):
      port_style = "green"
    elif ports.startswith("FAIL"):
      port_style = "red"
    elif ports.startswith("PART"):
      port_style = "yellow"
    else:
      port_style = ""
    return state_style, health_style, err_style, port_style

  def refresh_data(self) -> None:
    # Update header
    self.header.update(self._format_header())

    rows = []
    now = time.time()
    service_order = [name for name, _ in self.ctx.service_meta] if self.ctx.service_meta else self.ctx.services
    for svc in service_order:
      if svc not in self.ctx.services:
        continue
      cid = get_container_id(self.ctx.base_cmd, svc)
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
          self.log_cache,
          now,
          enabled=self.ctx.log_errors_enabled,
        )
        if err_cnt == -2:
          err_txt = "-"
        elif err_cnt < 0:
          err_txt = "n/a"
        else:
          err_txt = str(err_cnt)
        ports = "-"
        if self.ctx.probe_ports_enabled:
          ports = probe_ports(self.ctx.port_map.get(svc, []))

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

    profile_order = self.ctx.profiles[:] if self.ctx.profiles else []
    meta_by_name = {n: profs for n, profs in self.ctx.service_meta}
    grouped_rows = []
    seen_groups = []
    for r in rows:
      svc_profs = meta_by_name.get(r["service"], [])
      group = None
      for p in svc_profs:
        if not profile_order or p in profile_order:
          group = p
          break
      if group is None:
        group = "(no-profile)"
      if group not in seen_groups:
        grouped_rows.append({"group": group})
        seen_groups.append(group)
      grouped_rows.append(r)

    self.table.clear()
    if not self.table.columns:
      self.table.add_columns("Container", "Service", "State", "Health", "Errors", "Ports")
    for r in grouped_rows:
      if "group" in r:
        self.table.add_row(
          Text(f"[{r['group']}]", style="bold yellow"),
          Text(""),
          Text(""),
          Text(""),
          Text(""),
          Text(""),
        )
        continue
      state_style, health_style, err_style, port_style = self._row_styles(r["state"], r["health"], r["errors"], r["ports"])
      self.table.add_row(
        Text(r["cid"]),
        Text(r["service"]),
        Text(r["state"], style=state_style),
        Text(r["health"], style=health_style),
        Text(r["errors"], style=err_style),
        Text(r["ports"], style=port_style),
      )
    self.last_refresh = now

  def on_key(self, event: events.Key) -> None:
    if event.key == "q":
      self.exit()
    elif event.key == "r":
      self.refresh_data()


def main():
  ctx = build_context()
  app = MonitorApp(ctx)
  try:
    app.run()
  except KeyboardInterrupt:
    pass


if __name__ == "__main__":
  main()
