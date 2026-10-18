#!/usr/bin/env python3
"""labtui: a console UI for the lab.

Five tabs: the cluster's nodes, the labs, every guest, the lab's apps with
health checks, and the make workflows. Live from the Proxmox API.

    make tui      (uv run --project tui --locked python tui/labtui.py)

It reads the same settings as scripts/lab-ctl.sh:
  PROXMOX_VE_ENDPOINT   default https://<first host in ansible/inventory/hosts.yml>:8006/
  PROXMOX_VE_API_TOKEN  default: ~/.config/lab/proxmox-api-token (written by make iac)
  PROXMOX_VE_CACERT     the cluster CA to verify against (make iac copies it to ~/.config/lab/)
  PROXMOX_VE_INSECURE   true to accept the cluster's certificate unverified (the Makefile's default)
  LABTUI_REFRESH        seconds between refreshes (default 5)

Lab-wide actions (start in VMID order, stop, snapshot, rollback) run
scripts/lab-ctl.sh, so there is one implementation of each. Per-guest power
actions call the API directly, as lab-ctl does. The workflows tab runs make
targets in the real terminal, so prompts such as tofu apply's work.
"""

from __future__ import annotations

import json
import os
import re
import socket
import ssl
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from dataclasses import dataclass
from pathlib import Path

import yaml
from rich.text import Text
from textual import on, work
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.screen import ModalScreen
from textual.widgets import (
    Button,
    DataTable,
    Footer,
    Header,
    Input,
    Label,
    RichLog,
    Static,
    TabbedContent,
    TabPane,
)

REPO = Path(__file__).resolve().parent.parent
LAB_CTL = REPO / "scripts" / "lab-ctl.sh"
# lab-ctl's rule for snapshot names: a letter, then letters, digits, _ or -.
SNAPSHOT_NAME = re.compile(r"^[A-Za-z][A-Za-z0-9_-]{1,39}$")
# Targets with their own tab, or that make no sense from inside the UI.
HIDDEN_TARGETS = {"help", "lab", "tui"}


# --- Settings -------------------------------------------------------------------


@dataclass
class Settings:
    endpoint: str
    token: str | None
    tls: ssl.SSLContext
    tls_mode: str
    lab: dict
    inventory: dict
    refresh: float = 5.0


def load_settings(env: dict | None = None, repo: Path = REPO) -> Settings:
    env = dict(os.environ if env is None else env)
    lab = yaml.safe_load((repo / "config" / "lab.yml").read_text())
    inventory = yaml.safe_load((repo / "ansible" / "inventory" / "hosts.yml").read_text())

    endpoint = env.get("PROXMOX_VE_ENDPOINT")
    if not endpoint:
        nodes = inventory["all"]["children"]["proxmox"]["hosts"]
        endpoint = f"https://{next(iter(nodes.values()))['ansible_host']}:8006/"

    token = env.get("PROXMOX_VE_API_TOKEN") or None
    if not token:
        token_file = Path(env.get("HOME", "~")).expanduser() / ".config" / "lab" / "proxmox-api-token"
        if token_file.is_file():
            token = token_file.read_text().strip() or None

    if env.get("PROXMOX_VE_CACERT"):
        tls = ssl.create_default_context(cafile=env["PROXMOX_VE_CACERT"])
        tls_mode = "verified against PROXMOX_VE_CACERT"
    elif env.get("PROXMOX_VE_INSECURE", "false") == "true":
        tls = ssl.create_default_context()
        tls.check_hostname = False
        tls.verify_mode = ssl.CERT_NONE
        tls_mode = "unverified (PROXMOX_VE_INSECURE)"
    else:
        tls = ssl.create_default_context()
        tls_mode = "verified against the system trust store"

    refresh = float(env.get("LABTUI_REFRESH", "5"))
    return Settings(endpoint, token, tls, tls_mode, lab, inventory, refresh)


def inventory_hosts(inventory: dict, group: str) -> dict:
    """{name: address} for one inventory group (empty if the group is absent)."""
    hosts = (inventory["all"]["children"].get(group) or {}).get("hosts") or {}
    return {name: (h or {}).get("ansible_host") for name, h in hosts.items()}


# --- Proxmox API -----------------------------------------------------------------


class APIError(Exception):
    pass


class Proxmox:
    """GET and POST against /api2/json with the API token, as lab-ctl does."""

    def __init__(self, settings: Settings, timeout: float = 15):
        self.settings = settings
        self.timeout = timeout

    def _call(self, method: str, path: str, data: dict | None = None):
        url = self.settings.endpoint.rstrip("/") + "/api2/json" + path
        body = urllib.parse.urlencode(data).encode() if data is not None else None
        request = urllib.request.Request(
            url, data=body, method=method,
            headers={"Authorization": f"PVEAPIToken={self.settings.token}"},
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout, context=self.settings.tls) as response:
                payload = json.load(response)
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace").strip()[:200]
            raise APIError(f"{method} {path}: HTTP {e.code} {e.reason} {detail}".rstrip()) from None
        except (urllib.error.URLError, OSError, ValueError) as e:
            raise APIError(f"{method} {path}: {getattr(e, 'reason', e)}") from None
        return payload.get("data") if isinstance(payload, dict) else None

    def get(self, path: str):
        return self._call("GET", path)

    def post(self, path: str, data: dict | None = None):
        return self._call("POST", path, data or {})

    def wait_task(self, node: str, upid, limit: float = 600) -> str:
        """Wait for a task the way lab-ctl does; return its exit status."""
        if not isinstance(upid, str) or not upid.startswith("UPID:"):
            return "OK"
        quoted = urllib.parse.quote(upid, safe="")
        started = time.monotonic()
        while True:
            status = self.get(f"/nodes/{node}/tasks/{quoted}/status") or {}
            if status.get("status") == "stopped":
                return status.get("exitstatus") or "no exit status"
            if time.monotonic() - started >= limit:
                return f"still {status.get('status', 'unknown')} after {int(limit)}s"
            time.sleep(2)


# --- Cluster state -----------------------------------------------------------------


@dataclass
class Guest:
    vmid: int
    name: str
    node: str
    kind: str          # qemu or lxc
    status: str
    cpu: float
    maxcpu: int
    mem: int
    maxmem: int
    uptime: int
    tags: list[str]
    template: bool


@dataclass
class ClusterState:
    nodes: list[dict]
    guests: list[Guest]
    cluster_name: str | None
    quorate: bool | None
    error: str | None = None


def lab_names(lab: dict) -> list[str]:
    """The labs lab-ctl can address: every labs.<name>, plus infra (labgw, obs)."""
    return [*(lab.get("labs") or {}).keys(), "infra"]


def guest_lab(guest: Guest, labs: list[str]) -> str:
    return next((t for t in guest.tags if t in labs), "-")


def fetch_state(api: Proxmox) -> ClusterState:
    nodes = sorted(api.get("/cluster/resources?type=node") or [], key=lambda n: n.get("node", ""))
    guests = []
    for r in api.get("/cluster/resources?type=vm") or []:
        if r.get("type") not in ("qemu", "lxc"):
            continue
        guests.append(Guest(
            vmid=int(r.get("vmid", 0)), name=r.get("name") or "-", node=r.get("node", "-"),
            kind=r["type"], status=r.get("status", "unknown"),
            cpu=float(r.get("cpu") or 0), maxcpu=int(r.get("maxcpu") or 0),
            mem=int(r.get("mem") or 0), maxmem=int(r.get("maxmem") or 0),
            uptime=int(r.get("uptime") or 0),
            tags=[t for t in (r.get("tags") or "").split(";") if t],
            template=bool(r.get("template")),
        ))
    guests.sort(key=lambda g: g.vmid)
    cluster_name, quorate = None, None
    for entry in api.get("/cluster/status") or []:
        if entry.get("type") == "cluster":
            cluster_name, quorate = entry.get("name"), bool(entry.get("quorate"))
    return ClusterState(nodes, guests, cluster_name, quorate)


# --- Formatting ---------------------------------------------------------------------


def human_bytes(n: int) -> str:
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if n < 1024 or unit == "TiB":
            return f"{n:.0f} {unit}" if unit in ("B", "KiB") else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TiB"


def human_uptime(seconds: int) -> str:
    if seconds <= 0:
        return "-"
    days, rest = divmod(seconds, 86400)
    hours, rest = divmod(rest, 3600)
    return f"{days}d {hours}h" if days else f"{hours}h {rest // 60}m"


STATUS_STYLE = {"running": "bold green", "online": "bold green", "stopped": "dim",
                "offline": "bold red", "paused": "yellow", "unknown": "yellow"}


def status_text(status: str) -> Text:
    return Text(f"● {status}", style=STATUS_STYLE.get(status, "yellow"))


def meter(used: float, total: float, width: int = 10) -> Text:
    """A small bar plus percentage: green, yellow over 70 %, red over 90 %."""
    if total <= 0:
        return Text("-", style="dim")
    ratio = max(0.0, min(1.0, used / total))
    style = "red" if ratio > 0.9 else "yellow" if ratio > 0.7 else "green"
    filled = round(ratio * width)
    return Text.assemble(("█" * filled, style), ("░" * (width - filled), "dim"), f" {ratio * 100:4.0f}%")


# --- Apps ------------------------------------------------------------------------


@dataclass
class AppEntry:
    name: str
    host: str
    port: int
    url: str | None = None
    ssh: str | None = None
    health: str | None = None   # an HTTP path that answers JSON, else a TCP connect


def build_apps(settings: Settings) -> list[AppEntry]:
    """The lab's services, from the inventory and config/lab.yml only."""
    inv, lab = settings.inventory, settings.lab
    apps = []
    for name, ip in inventory_hosts(inv, "proxmox").items():
        apps.append(AppEntry(f"Proxmox web UI · {name}", ip, 8006, url=f"https://{ip}:8006/", ssh=name))
    for name, ip in inventory_hosts(inv, "lab_gateway").items():
        apps.append(AppEntry(f"{name}: DNS for lab names", ip, 53, ssh=name))
    obs = lab.get("observability") or {}
    for name, ip in inventory_hosts(inv, "observability").items():
        if not obs.get("enabled"):
            continue
        apps.append(AppEntry("Grafana", ip, 3000, url=f"http://{ip}:3000/", ssh=name, health="/api/health"))
        apps.append(AppEntry("Alloy: syslog receiver", ip, int(obs.get("syslog_port", 514))))
        apps.append(AppEntry("Alloy: OTLP receiver", ip, int(obs.get("otlp_port", 4318))))
    for name, ip in inventory_hosts(inv, "nas").items():
        apps.append(AppEntry(f"Pi-hole DNS · {name}", ip, 53))
        if (lab.get("nas") or {}).get("enabled"):
            apps.append(AppEntry(f"NFS · {name}", ip, 2049))
    return apps


def check_app(app: AppEntry, timeout: float = 2.0) -> tuple[bool, str]:
    if app.health:
        try:
            with urllib.request.urlopen(f"http://{app.host}:{app.port}{app.health}", timeout=timeout) as r:
                body = json.load(r)
            return True, f"HTTP {r.status} " + ", ".join(f"{k} {v}" for k, v in body.items() if k in ("database", "version"))
        except (urllib.error.URLError, OSError, ValueError) as e:
            return False, str(getattr(e, "reason", e))
    try:
        with socket.create_connection((app.host, app.port), timeout=timeout):
            return True, f"tcp/{app.port} open"
    except OSError as e:
        return False, f"tcp/{app.port}: {e.strerror or e}"


# --- Workflows -----------------------------------------------------------------------


def make_targets(makefile: Path = REPO / "Makefile") -> list[tuple[str, str]]:
    """(target, description) from the Makefile's '## ' comments, as make help reads them."""
    targets = []
    for line in makefile.read_text().splitlines():
        m = re.match(r"^([a-z-]+):.*## (.*)$", line)
        if m and m.group(1) not in HIDDEN_TARGETS:
            targets.append((m.group(1), m.group(2)))
    return targets


# --- Dialogs ---------------------------------------------------------------------------


class Confirm(ModalScreen[bool]):
    BINDINGS = [Binding("escape", "dismiss(False)", "Cancel")]

    def __init__(self, question: str, danger: bool = False):
        super().__init__()
        self.question, self.danger = question, danger

    def compose(self) -> ComposeResult:
        with Vertical(id="dialog"):
            yield Label(self.question, id="question")
            with Horizontal(id="buttons"):
                yield Button("Yes", variant="error" if self.danger else "primary", id="yes")
                yield Button("No", id="no")

    def on_mount(self) -> None:
        # A stray Enter must not confirm something destructive.
        self.query_one("#no", Button).focus()

    @on(Button.Pressed)
    def answer(self, event: Button.Pressed) -> None:
        self.dismiss(event.button.id == "yes")


class Ask(ModalScreen[str | None]):
    """One line of input. `rule` is a regex the answer must match (or None)."""

    BINDINGS = [Binding("escape", "dismiss(None)", "Cancel")]

    def __init__(self, question: str, placeholder: str = "", rule: re.Pattern | None = None, hint: str = ""):
        super().__init__()
        self.question, self.placeholder, self.rule, self.hint = question, placeholder, rule, hint

    def compose(self) -> ComposeResult:
        with Vertical(id="dialog"):
            yield Label(self.question, id="question")
            yield Input(placeholder=self.placeholder, id="answer")
            yield Label(self.hint, id="hint")
            with Horizontal(id="buttons"):
                yield Button("OK", variant="primary", id="ok")
                yield Button("Cancel", id="cancel")

    def _submit(self) -> None:
        value = self.query_one("#answer", Input).value.strip()
        if self.rule is not None and not self.rule.match(value):
            self.query_one("#hint", Label).update(Text(f"✗ {self.hint}", style="bold red"))
            return
        self.dismiss(value)

    @on(Input.Submitted)
    def submitted(self) -> None:
        self._submit()

    @on(Button.Pressed)
    def pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "ok":
            self._submit()
        else:
            self.dismiss(None)


# --- The app ------------------------------------------------------------------------------


class LabTUI(App):
    TITLE = "Lab"
    CSS = """
    Screen { background: $surface; overflow: hidden; }
    #tabs { height: 1fr; }
    #summary { height: auto; padding: 1 2; background: $boost; }
    DataTable { height: 1fr; }
    TabPane { padding: 0 1; }
    .help { color: $text-muted; padding: 0 1; height: auto; }
    #activity { height: 9; border-top: hkey $primary; background: $panel; }
    #dialog { width: 72; height: auto; padding: 1 2; border: thick $primary; background: $panel; }
    #question { width: 100%; margin-bottom: 1; }
    #hint { color: $text-muted; height: auto; }
    #buttons { height: auto; align-horizontal: right; margin-top: 1; }
    #buttons Button { margin-left: 2; }
    Confirm, Ask { align: center middle; }
    """

    BINDINGS = [
        Binding("q", "quit", "Quit"),
        Binding("ctrl+r", "refresh", "Refresh"),
        Binding("1", "tab('cluster')", "Cluster", show=False),
        Binding("2", "tab('labs')", "Labs", show=False),
        Binding("3", "tab('guests')", "Guests", show=False),
        Binding("4", "tab('apps')", "Apps", show=False),
        Binding("5", "tab('workflows')", "Workflows", show=False),
        Binding("s", "start", "Start"),
        Binding("d", "shutdown", "Shut down"),
        Binding("x", "force_stop", "Force stop"),
        Binding("e", "reboot", "Reboot"),
        Binding("n", "snapshot", "Snapshot"),
        Binding("b", "rollback", "Roll back"),
        Binding("l", "snapshots", "Snapshots"),
        Binding("o", "open", "Open"),
        Binding("h", "ssh", "SSH"),
        Binding("c", "check_apps", "Check now"),
    ]

    # Which tab each action belongs to. check_action hides the others (False),
    # so the footer shows only the current tab's keys.
    ACTION_TABS = {
        "start": {"labs", "guests"}, "shutdown": {"labs", "guests"},
        "force_stop": {"guests"}, "reboot": {"guests"},
        "snapshot": {"labs"}, "rollback": {"labs"}, "snapshots": {"labs"},
        "open": {"apps"}, "ssh": {"apps"}, "check_apps": {"apps"},
    }

    def __init__(self, settings: Settings):
        super().__init__()
        self.settings = settings
        self.api = Proxmox(settings)
        self.labs = lab_names(settings.lab)
        self.apps = build_apps(settings)
        self.targets = make_targets()
        self.state: ClusterState | None = None

    # --- layout ---
    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        with TabbedContent(initial="cluster", id="tabs"):
            with TabPane("Cluster", id="cluster"):
                yield Static("Connecting…", id="summary")
                yield DataTable(id="nodes", cursor_type="row", zebra_stripes=True)
            with TabPane("Labs", id="labs"):
                yield Static("Lab-wide actions run scripts/lab-ctl.sh: start in VMID order, "
                             "stop in reverse, snapshots on every guest of the lab.", classes="help")
                yield DataTable(id="labtable", cursor_type="row", zebra_stripes=True)
            with TabPane("Guests", id="guests"):
                yield DataTable(id="guesttable", cursor_type="row", zebra_stripes=True)
            with TabPane("Apps", id="apps"):
                yield Static("The lab's services, from the inventory and config/lab.yml. "
                             "o opens a web UI, h opens SSH (names from make control).", classes="help")
                yield DataTable(id="apptable", cursor_type="row", zebra_stripes=True)
            with TabPane("Workflows", id="workflows"):
                yield Static("make targets, from the Makefile. Enter runs one in this terminal; "
                             "the UI comes back when it finishes.", classes="help")
                yield DataTable(id="maketable", cursor_type="row", zebra_stripes=True)
        yield RichLog(id="activity", wrap=True, markup=False, max_lines=500)
        yield Footer()

    def on_mount(self) -> None:
        self.sub_title = self.settings.endpoint
        self.query_one("#nodes", DataTable).add_columns("Node", "Status", "CPU", "Memory", "Uptime")
        self.query_one("#labtable", DataTable).add_columns("Lab", "Description", "Guests", "Running", "Nodes")
        self.query_one("#guesttable", DataTable).add_columns(
            "VMID", "Name", "Lab", "Node", "Type", "Status", "CPU", "Memory", "Uptime")
        apps = self.query_one("#apptable", DataTable)
        apps.add_columns("App", "Address", "Health", "Detail")
        for i, a in enumerate(self.apps):
            apps.add_row(a.name, f"{a.host}:{a.port}", Text("… checking", style="dim"), "", key=str(i))
        make = self.query_one("#maketable", DataTable)
        make.add_columns("Target", "What it does")
        for target, description in self.targets:
            make.add_row(Text(f"make {target}", style="bold"), description, key=target)
        self.log_line(f"labtui: {self.settings.endpoint}, TLS {self.settings.tls_mode}")
        if not self.settings.token:
            self.query_one("#summary", Static).update(Text(
                "No API token: run make iac (it writes ~/.config/lab/proxmox-api-token), "
                "or set PROXMOX_VE_API_TOKEN. Apps and Workflows work without it.", style="bold yellow"))
        else:
            self.refresh_state()
            self.set_interval(self.settings.refresh, self.refresh_state)
        self.check_apps()
        self.set_interval(30, self.check_apps)

    # --- helpers ---
    def log_line(self, line: str) -> None:
        self.query_one("#activity", RichLog).write(f"{time.strftime('%H:%M:%S')}  {line}")

    @property
    def tab(self) -> str:
        return self.query_one("#tabs", TabbedContent).active

    def check_action(self, action: str, parameters: tuple) -> bool | None:
        tabs = self.ACTION_TABS.get(action)
        return tabs is None or self.tab in tabs

    @on(TabbedContent.TabActivated)
    def tab_changed(self) -> None:
        self.refresh_bindings()

    def action_tab(self, tab: str) -> None:
        self.query_one("#tabs", TabbedContent).active = tab

    def selected_key(self, table_id: str) -> str | None:
        table = self.query_one(f"#{table_id}", DataTable)
        if table.row_count == 0:
            return None
        return table.coordinate_to_cell_key(table.cursor_coordinate).row_key.value

    def selected_guest(self) -> Guest | None:
        key = self.selected_key("guesttable")
        if key is None or self.state is None:
            return None
        return next((g for g in self.state.guests if str(g.vmid) == key), None)

    @staticmethod
    def refill(table: DataTable, rows: list[tuple[str, tuple]]) -> None:
        """Replace the rows, keeping the cursor on the same key when it still exists."""
        current = None
        if table.row_count:
            current = table.coordinate_to_cell_key(table.cursor_coordinate).row_key.value
        table.clear()
        for key, cells in rows:
            table.add_row(*cells, key=key)
        keys = [key for key, _ in rows]
        if current in keys:
            table.move_cursor(row=keys.index(current))

    # --- refresh ---
    def action_refresh(self) -> None:
        if self.settings.token:
            self.refresh_state()
        self.check_apps()

    @work(thread=True, exclusive=True, group="refresh")
    def refresh_state(self) -> None:
        try:
            state = fetch_state(self.api)
        except APIError as e:
            state = ClusterState([], [], None, None, error=str(e))
        self.call_from_thread(self.show_state, state)

    def show_state(self, state: ClusterState) -> None:
        summary = self.query_one("#summary", Static)
        if state.error:
            summary.update(Text.assemble(("Can't reach the cluster: ", "bold red"), state.error))
            if self.state is None or self.state.error is None:
                self.log_line(f"API: {state.error}")
            self.state = state
            return
        if self.state is not None and self.state.error:
            self.log_line("API: reachable again")
        self.state = state
        running = sum(g.status == "running" for g in state.guests)
        quorum = ("quorate", "bold green") if state.quorate else ("NOT quorate", "bold red") \
            if state.quorate is not None else ("single node", "yellow")
        summary.update(Text.assemble(
            ("Cluster ", "bold"), (state.cluster_name or "(none)", "bold cyan"), "   ",
            quorum, "   ", (f"{len(state.nodes)} nodes", "bold"), "   ",
            (f"{running}/{len(state.guests)} guests running", "bold"), "   ",
            (f"TLS {self.settings.tls_mode}", "dim"), "   ",
            (f"refreshed {time.strftime('%H:%M:%S')}", "dim")))

        self.refill(self.query_one("#nodes", DataTable), [
            (n.get("node", "?"), (
                Text(n.get("node", "?"), style="bold"), status_text(n.get("status", "unknown")),
                meter(float(n.get("cpu") or 0), 1.0),
                Text.assemble(meter(n.get("mem") or 0, n.get("maxmem") or 0),
                              f"  {human_bytes(n.get('mem') or 0)} / {human_bytes(n.get('maxmem') or 0)}"),
                human_uptime(int(n.get("uptime") or 0))))
            for n in state.nodes])

        pools = self.settings.lab.get("pools") or {}
        rows = []
        for name in self.labs:
            members = [g for g in state.guests if name in g.tags]
            up = sum(g.status == "running" for g in members)
            rows.append((name, (
                Text(name, style="bold"), pools.get(name, ""), str(len(members)),
                Text(f"{up}/{len(members)}", style="bold green" if members and up == len(members)
                     else "yellow" if up else "dim"),
                ", ".join(sorted({g.node for g in members})) or "-")))
        self.refill(self.query_one("#labtable", DataTable), rows)

        self.refill(self.query_one("#guesttable", DataTable), [
            (str(g.vmid), (
                str(g.vmid), Text(g.name, style="bold"), guest_lab(g, self.labs), g.node,
                "VM" if g.kind == "qemu" else "CT", status_text(g.status),
                meter(g.cpu, 1.0, width=6) if g.status == "running" else Text("-", style="dim"),
                f"{human_bytes(g.mem)} / {human_bytes(g.maxmem)}" if g.status == "running"
                else f"- / {human_bytes(g.maxmem)}",
                human_uptime(g.uptime)))
            for g in state.guests if not g.template])

    # --- apps ---
    @work(thread=True, exclusive=True, group="health")
    def check_apps(self) -> None:
        for i, app in enumerate(self.apps):
            ok, detail = check_app(app)
            self.call_from_thread(self.show_health, i, ok, detail)

    def action_check_apps(self) -> None:
        self.check_apps()

    def show_health(self, index: int, ok: bool, detail: str) -> None:
        table = self.query_one("#apptable", DataTable)
        health = Text("● up", style="bold green") if ok else Text("● down", style="bold red")
        table.update_cell(str(index), table.ordered_columns[2].key, health)
        table.update_cell(str(index), table.ordered_columns[3].key, detail, update_width=True)

    def selected_app(self) -> AppEntry | None:
        key = self.selected_key("apptable")
        return self.apps[int(key)] if key is not None else None

    def action_open(self) -> None:
        app = self.selected_app()
        if app is None or not app.url:
            self.notify("This app has no web UI.", severity="warning")
            return
        webbrowser.open(app.url)
        self.log_line(f"opened {app.url}")

    @on(DataTable.RowSelected, "#apptable")
    def app_selected(self) -> None:
        self.action_open()

    def action_ssh(self) -> None:
        app = self.selected_app()
        if app is None or not app.ssh:
            self.notify("No SSH host for this app.", severity="warning")
            return
        self.run_in_terminal(["ssh", app.ssh], f"ssh {app.ssh}")

    # --- workflows ---
    @on(DataTable.RowSelected, "#maketable")
    def target_selected(self, event: DataTable.RowSelected) -> None:
        target = event.row_key.value
        description = dict(self.targets).get(target, "")

        def run(extra: str | None) -> None:
            if extra is None:
                return
            argv = ["make", target, *extra.split()]
            self.run_in_terminal(argv, " ".join(argv))

        self.push_screen(Ask(
            f"make {target}\n{description}",
            placeholder="extra arguments, e.g. OVA=~/x.ova (empty for none)",
            hint="Runs in this terminal; Enter or OK to run, Esc to cancel."), run)

    def run_in_terminal(self, argv: list[str], label: str) -> None:
        self.log_line(f"$ {label}")
        with self.suspend():
            print(f"\n$ {label}\n", flush=True)
            rc = subprocess.call(argv, cwd=REPO)
            input(f"\n[{label}: exit {rc}] Press Enter to return to labtui ")
        self.log_line(f"{label}: exit {rc}")
        self.action_refresh()

    # --- labs (scripts/lab-ctl.sh) ---
    def selected_lab(self) -> str | None:
        return self.selected_key("labtable")

    @work(thread=True, group="lab-ctl")
    def lab_ctl(self, *args: str) -> None:
        label = "lab-ctl " + " ".join(args)
        self.call_from_thread(self.log_line, f"$ {label}")
        proc = subprocess.Popen([str(LAB_CTL), *args], cwd=REPO, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        assert proc.stdout is not None
        for line in proc.stdout:
            self.call_from_thread(self.log_line, "  " + line.rstrip())
        rc = proc.wait()
        self.call_from_thread(self.log_line, f"{label}: {'done' if rc == 0 else f'exit {rc}'}")
        self.call_from_thread(self.notify, f"{label}: {'done' if rc == 0 else f'failed (exit {rc})'}",
                              severity="information" if rc == 0 else "error")
        if self.settings.token:
            self.call_from_thread(self.refresh_state)

    def lab_action(self, command: str, confirm: str | None = None) -> None:
        lab = self.selected_lab()
        if lab is None:
            return
        if confirm is None:
            self.lab_ctl(lab, command)
            return
        self.push_screen(Confirm(confirm.format(lab=lab), danger=True),
                         lambda yes: self.lab_ctl(lab, command) if yes else None)

    def snapshot_name(self, question: str, then) -> None:
        self.push_screen(Ask(question, placeholder="e.g. clean", rule=SNAPSHOT_NAME,
                             hint="A letter, then letters, digits, _ or -, 2 to 40 characters."), then)

    def action_snapshots(self) -> None:
        lab = self.selected_lab()
        if lab:
            self.lab_ctl(lab, "snapshots")

    # --- guests (API) ---
    @work(thread=True, group="guest")
    def guest_power(self, guest: Guest, action: str) -> None:
        path = f"/nodes/{guest.node}/{guest.kind}/{guest.vmid}/status/{action}"
        data = {"timeout": "180", "forceStop": "1"} if action == "shutdown" else None
        self.call_from_thread(self.log_line, f"{action} {guest.vmid} {guest.name} on {guest.node}")
        try:
            result = self.api.wait_task(guest.node, self.api.post(path, data))
        except APIError as e:
            result = str(e)
        ok = result == "OK"
        self.call_from_thread(self.log_line, f"{action} {guest.vmid} {guest.name}: {result}")
        self.call_from_thread(self.notify, f"{action} {guest.name}: {result}",
                              severity="information" if ok else "error")
        self.call_from_thread(self.refresh_state)

    def guest_action(self, action: str, confirm: str | None = None) -> None:
        guest = self.selected_guest()
        if guest is None:
            return
        if confirm is None:
            self.guest_power(guest, action)
            return
        self.push_screen(Confirm(confirm.format(g=guest), danger=True),
                         lambda yes: self.guest_power(guest, action) if yes else None)

    # --- actions, dispatched by tab ---
    def action_start(self) -> None:
        if self.tab == "labs":
            self.lab_action("start")
        else:
            self.guest_action("start")

    def action_shutdown(self) -> None:
        if self.tab == "labs":
            self.lab_action("stop", "Shut down every guest of lab '{lab}' (reverse VMID order)?")
        else:
            self.guest_action("shutdown", "Shut down {g.vmid} {g.name}? Forced after 180 s.")

    def action_force_stop(self) -> None:
        self.guest_action("stop", "Force-stop {g.vmid} {g.name}? Like pulling the power cord.")

    def action_reboot(self) -> None:
        self.guest_action("reboot", "Reboot {g.vmid} {g.name}?")

    def action_snapshot(self) -> None:
        lab = self.selected_lab()
        if lab:
            self.snapshot_name(f"Snapshot every guest of lab '{lab}' as:",
                               lambda name: self.lab_ctl(lab, "snapshot", name) if name else None)

    def action_rollback(self) -> None:
        lab = self.selected_lab()
        if not lab:
            return

        def confirm(name: str | None) -> None:
            if name:
                self.push_screen(
                    Confirm(f"Roll every guest of lab '{lab}' back to '{name}'? "
                            "Changes since then are lost.", danger=True),
                    lambda yes: self.lab_ctl(lab, "rollback", name) if yes else None)

        self.snapshot_name(f"Roll lab '{lab}' back to snapshot:", confirm)


def main() -> None:
    LabTUI(load_settings()).run()


if __name__ == "__main__":
    main()
