"""Tests for labtui, against a fake Proxmox API on localhost (no cluster needed).

    make check      (uv run --project tui --locked pytest -q tui)
"""

from __future__ import annotations

import json
import stat
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest
from textual.widgets import DataTable, RichLog

import labtui

TOKEN = "terraform@pve!provider=secret"

NODES = [
    {"type": "node", "node": "pve1", "status": "online", "cpu": 0.12, "maxcpu": 4,
     "mem": 6 * 2**30, "maxmem": 16 * 2**30, "uptime": 3 * 86400 + 7200},
    {"type": "node", "node": "pve2", "status": "online", "cpu": 0.03, "maxcpu": 4,
     "mem": 3 * 2**30, "maxmem": 16 * 2**30, "uptime": 3600},
]
VMS = [
    {"type": "lxc", "vmid": 110, "name": "labgw", "node": "pve1", "status": "running",
     "cpu": 0.01, "maxcpu": 1, "mem": 60 * 2**20, "maxmem": 256 * 2**20, "uptime": 7200, "tags": "infra;lab"},
    {"type": "qemu", "vmid": 120, "name": "obs", "node": "pve1", "status": "running",
     "cpu": 0.2, "maxcpu": 2, "mem": 3 * 2**30, "maxmem": 4 * 2**30, "uptime": 7000, "tags": "infra;obs"},
    {"type": "qemu", "vmid": 1001, "name": "bastion", "node": "pve1", "status": "running",
     "cpu": 0.1, "maxcpu": 2, "mem": 2 * 2**30, "maxmem": 4 * 2**30, "uptime": 600, "tags": "lab;wallix"},
    {"type": "qemu", "vmid": 3001, "name": "kali", "node": "pve2", "status": "stopped",
     "cpu": 0, "maxcpu": 2, "mem": 0, "maxmem": 2 * 2**30, "uptime": 0, "tags": "cyber;lab"},
]
CLUSTER = [
    {"type": "cluster", "name": "lab", "quorate": 1, "nodes": 2},
    {"type": "node", "name": "pve1", "online": 1},
    {"type": "node", "name": "pve2", "online": 1},
]


class FakeProxmox(BaseHTTPRequestHandler):
    calls: list = []

    def log_message(self, *args):  # keep test output quiet
        pass

    def reply(self, data, code=200):
        body = json.dumps({"data": data}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.calls.append(("GET", self.path, None, self.headers.get("Authorization")))
        if self.headers.get("Authorization") != f"PVEAPIToken={TOKEN}":
            return self.reply(None, 401)
        path = self.path.removeprefix("/api2/json")
        if path == "/cluster/resources?type=node":
            return self.reply(NODES)
        if path == "/cluster/resources?type=vm":
            return self.reply(VMS)
        if path == "/cluster/status":
            return self.reply(CLUSTER)
        if "/tasks/" in path:
            return self.reply({"status": "stopped", "exitstatus": "OK"})
        return self.reply(None, 404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode()
        self.calls.append(("POST", self.path, body, self.headers.get("Authorization")))
        node = self.path.split("/")[4]
        return self.reply(f"UPID:{node}:0000AAAA:00000000:00000000:qmstart:3001:root@pam:")


@pytest.fixture
def fake_api():
    FakeProxmox.calls = []
    server = ThreadingHTTPServer(("127.0.0.1", 0), FakeProxmox)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    yield server
    server.shutdown()


@pytest.fixture
def settings(fake_api, monkeypatch):
    env = {"HOME": "/nonexistent", "PROXMOX_VE_API_TOKEN": TOKEN,
           "PROXMOX_VE_ENDPOINT": f"http://127.0.0.1:{fake_api.server_port}/", "LABTUI_REFRESH": "60"}
    # no real network in tests: every app is "up"
    monkeypatch.setattr(labtui, "check_app", lambda app, timeout=2.0: (True, f"tcp/{app.port} open"))
    return labtui.load_settings(env)


@pytest.fixture
def stub_lab_ctl(tmp_path, monkeypatch):
    """A stand-in for scripts/lab-ctl.sh that records its arguments."""
    record = tmp_path / "lab-ctl.args"
    script = tmp_path / "lab-ctl.sh"
    script.write_text(f'#!/bin/sh\necho "$@" >> {record}\necho "==> stub $*"\n')
    script.chmod(script.stat().st_mode | stat.S_IEXEC)
    monkeypatch.setattr(labtui, "LAB_CTL", script)
    return record


def activity(app) -> str:
    return "\n".join(line.text for line in app.query_one("#activity", RichLog).lines)


def select_lab(app, name: str) -> None:
    labs = app.query_one("#labtable", DataTable)
    labs.move_cursor(row=[labs.get_row_at(i)[0].plain for i in range(labs.row_count)].index(name))


async def settle(pilot, check, tries=50):
    for _ in range(tries):
        await pilot.pause(0.05)
        if check():
            return True
    return False


# --- pure functions ----------------------------------------------------------------


def test_settings_follow_lab_ctl(tmp_path):
    (tmp_path / ".config" / "lab").mkdir(parents=True)
    (tmp_path / ".config" / "lab" / "proxmox-api-token").write_text(TOKEN + "\n")
    s = labtui.load_settings({"HOME": str(tmp_path), "PROXMOX_VE_INSECURE": "true"})
    first = next(iter(s.inventory["all"]["children"]["proxmox"]["hosts"].values()))["ansible_host"]
    assert s.endpoint == f"https://{first}:8006/"
    assert s.token == TOKEN
    assert s.tls_mode.startswith("unverified")
    assert labtui.load_settings({"HOME": "/nonexistent"}).token is None


def test_labs_come_from_lab_yml(settings):
    assert labtui.lab_names(settings.lab) == [*settings.lab["labs"].keys(), "infra"]


def test_apps_come_from_the_inventory(settings):
    names = [a.name for a in labtui.build_apps(settings)]
    assert "Proxmox web UI · pve1" in names and "Grafana" in names
    grafana = next(a for a in labtui.build_apps(settings) if a.name == "Grafana")
    obs_ip = settings.inventory["all"]["children"]["observability"]["hosts"]["obs"]["ansible_host"]
    assert grafana.url == f"http://{obs_ip}:3000/" and grafana.ssh == "obs"


def test_workflows_are_the_makefile_targets():
    targets = dict(labtui.make_targets())
    assert {"plan", "apply", "gateway", "obs", "kali"} <= targets.keys()
    assert not labtui.HIDDEN_TARGETS & targets.keys()


def test_formatting():
    assert labtui.human_bytes(16 * 2**30) == "16.0 GiB"
    assert labtui.human_uptime(3 * 86400 + 7200) == "3d 2h"
    assert labtui.human_uptime(0) == "-"


def test_fetch_state(settings, fake_api):
    state = labtui.fetch_state(labtui.Proxmox(settings))
    assert [n["node"] for n in state.nodes] == ["pve1", "pve2"]
    assert [g.vmid for g in state.guests] == [110, 120, 1001, 3001]
    assert state.cluster_name == "lab" and state.quorate is True
    labs = labtui.lab_names(settings.lab)
    assert {g.name: labtui.guest_lab(g, labs) for g in state.guests} == {
        "labgw": "infra", "obs": "infra", "bastion": "wallix", "kali": "cyber"}


def test_api_errors_are_reported(settings):
    settings.token = "wrong"
    with pytest.raises(labtui.APIError, match="HTTP 401"):
        labtui.Proxmox(settings).get("/cluster/status")


# --- the app ----------------------------------------------------------------------------


async def test_tables_fill_from_the_api(settings):
    app = labtui.LabTUI(settings)
    async with app.run_test(size=(150, 45)) as pilot:
        guests = app.query_one("#guesttable", DataTable)
        assert await settle(pilot, lambda: guests.row_count == 4)
        assert app.query_one("#nodes", DataTable).row_count == 2
        labs = app.query_one("#labtable", DataTable)
        rows = {labs.get_row_at(i)[0].plain: labs.get_row_at(i) for i in range(labs.row_count)}
        assert list(rows) == labtui.lab_names(settings.lab)
        assert rows["infra"][2] == "2" and rows["cyber"][3].plain == "0/1"
        assert "quorate" in str(app.query_one("#summary").render())


async def test_guest_start_calls_the_api(settings, fake_api):
    app = labtui.LabTUI(settings)
    async with app.run_test(size=(150, 45)) as pilot:
        guests = app.query_one("#guesttable", DataTable)
        assert await settle(pilot, lambda: guests.row_count == 4)
        await pilot.press("3")
        guests.move_cursor(row=3)                      # kali, stopped
        await pilot.press("s")
        posts = lambda: [c for c in FakeProxmox.calls if c[0] == "POST"]  # noqa: E731
        assert await settle(pilot, lambda: posts())
        assert posts()[0][1] == "/api2/json/nodes/pve2/qemu/3001/status/start"
        assert posts()[0][3] == f"PVEAPIToken={TOKEN}"
        assert await settle(pilot, lambda: "start 3001 kali: OK" in activity(app))


async def test_force_stop_needs_confirmation(settings, fake_api):
    app = labtui.LabTUI(settings)
    async with app.run_test(size=(150, 45)) as pilot:
        guests = app.query_one("#guesttable", DataTable)
        assert await settle(pilot, lambda: guests.row_count == 4)
        await pilot.press("3")
        guests.move_cursor(row=2)                      # bastion, running
        await pilot.press("x")
        assert isinstance(app.screen, labtui.Confirm)
        await pilot.click("#no")
        await pilot.pause(0.2)
        assert not [c for c in FakeProxmox.calls if c[0] == "POST"]
        await pilot.press("x")
        await pilot.click("#yes")
        assert await settle(pilot, lambda: any(c[0] == "POST" for c in FakeProxmox.calls))
        assert [c[1] for c in FakeProxmox.calls if c[0] == "POST"] == [
            "/api2/json/nodes/pve1/qemu/1001/status/stop"]


async def test_shutdown_matches_lab_ctl(settings, fake_api):
    app = labtui.LabTUI(settings)
    async with app.run_test(size=(150, 45)) as pilot:
        guests = app.query_one("#guesttable", DataTable)
        assert await settle(pilot, lambda: guests.row_count == 4)
        await pilot.press("3")
        guests.move_cursor(row=2)
        await pilot.press("d")
        await pilot.click("#yes")
        assert await settle(pilot, lambda: any(c[0] == "POST" for c in FakeProxmox.calls))
        post = next(c for c in FakeProxmox.calls if c[0] == "POST")
        assert post[1].endswith("/qemu/1001/status/shutdown")
        assert post[2] == "timeout=180&forceStop=1"


async def test_lab_actions_run_lab_ctl(settings, stub_lab_ctl):
    app = labtui.LabTUI(settings)
    async with app.run_test(size=(150, 45)) as pilot:
        labs = app.query_one("#labtable", DataTable)
        assert await settle(pilot, lambda: labs.row_count == len(labtui.lab_names(settings.lab)))
        await pilot.press("2")
        select_lab(app, "cyber")
        await pilot.press("s")
        assert await settle(pilot, lambda: stub_lab_ctl.exists())
        assert stub_lab_ctl.read_text().split("\n")[0] == "cyber start"
        assert await settle(pilot, lambda: "==> stub cyber start" in activity(app))


async def test_snapshot_names_are_checked(settings, stub_lab_ctl):
    app = labtui.LabTUI(settings)
    async with app.run_test(size=(150, 45)) as pilot:
        labs = app.query_one("#labtable", DataTable)
        assert await settle(pilot, lambda: labs.row_count == len(labtui.lab_names(settings.lab)))
        await pilot.press("2")
        select_lab(app, "cyber")
        await pilot.press("n")
        assert isinstance(app.screen, labtui.Ask)
        await pilot.press(*"1bad", "enter")
        assert isinstance(app.screen, labtui.Ask)    # refused, still asking
        app.screen.query_one("#answer").value = "clean"
        await pilot.press("enter")
        assert await settle(pilot, lambda: stub_lab_ctl.exists())
        assert stub_lab_ctl.read_text().strip() == "cyber snapshot clean"


async def test_rollback_asks_twice(settings, stub_lab_ctl):
    app = labtui.LabTUI(settings)
    async with app.run_test(size=(150, 45)) as pilot:
        labs = app.query_one("#labtable", DataTable)
        assert await settle(pilot, lambda: labs.row_count == len(labtui.lab_names(settings.lab)))
        await pilot.press("2")
        select_lab(app, "wallix")
        await pilot.press("b")
        await pilot.press(*"baseline", "enter")
        assert isinstance(app.screen, labtui.Confirm)
        await pilot.click("#yes")
        assert await settle(pilot, lambda: stub_lab_ctl.exists())
        assert stub_lab_ctl.read_text().strip() == "wallix rollback baseline"


async def test_destructive_dialogs_focus_no(settings):
    app = labtui.LabTUI(settings)
    async with app.run_test(size=(150, 45)) as pilot:
        guests = app.query_one("#guesttable", DataTable)
        assert await settle(pilot, lambda: guests.row_count == 4)
        await pilot.press("3")
        guests.move_cursor(row=2)
        await pilot.press("x")
        await pilot.press("enter")                     # Enter on the focused button: No
        await pilot.pause(0.3)
        assert not [c for c in FakeProxmox.calls if c[0] == "POST"]


async def test_app_details_are_not_cut(settings):
    app = labtui.LabTUI(settings)
    async with app.run_test(size=(150, 45)) as pilot:
        table = app.query_one("#apptable", DataTable)
        assert await settle(pilot, lambda: str(table.get_row_at(0)[3]) == "tcp/8006 open")
        assert table.ordered_columns[3].content_width >= len("tcp/8006 open")


async def test_footer_shows_the_tabs_actions(settings):
    app = labtui.LabTUI(settings)
    async with app.run_test(size=(150, 45)) as pilot:
        await pilot.press("4")
        assert app.check_action("open", ()) is True and app.check_action("force_stop", ()) is False
        await pilot.press("3")
        assert app.check_action("force_stop", ()) is True and app.check_action("open", ()) is False


async def test_without_a_token_the_ui_still_runs(settings):
    settings.token = None
    app = labtui.LabTUI(settings)
    async with app.run_test(size=(150, 45)) as pilot:
        await pilot.pause(0.2)
        assert "No API token" in str(app.query_one("#summary").render())
        assert app.query_one("#maketable", DataTable).row_count == len(labtui.make_targets())


def test_tui_is_a_make_target():
    assert "tui:" in Path(labtui.REPO / "Makefile").read_text()
