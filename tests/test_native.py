#!/usr/bin/env python3
"""Native transport behavior, exercised without opening or messaging real terminals."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.append(str(Path(__file__).resolve().parent.parent))
from dashboard.bridge import DemoBridge, MacBridge, is_awake_process
from dashboard.core import Workspace, WorkspaceError
from dashboard.native import (
    apply_iterm_window_title, continue_prompt, dispatch, ensure_grok_compact_mode,
    fallback_title, launch_command, pick_source_title, source_window_title,
    window_id_for_session, _pb_bytes, _pb_str,
)


class NativeTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="td-native-test-")
        self.addCleanup(self.temp.cleanup)
        self.bridge = DemoBridge()
        self.work = Workspace(self.temp.name, self.bridge)

    def call(self, action, **fields):
        return dispatch(self.work, dict(action=action, **fields))

    def test_native_edward_loop_without_server(self):
        state = self.call("state")["state"]
        edwards = [s for s in state["sessions"] if s["project"] == "edward_agent"]
        self.assertEqual(len(edwards), 2)
        self.call("focus", session="demo:6")
        self.assertEqual(self.bridge.calls, [("demo:6", "focus", "")])
        self.call("controller", session="demo:1", enabled=True)
        guide = self.call("guide")["result"]["text"]
        self.assertIn("TD_AGENT_TOKEN", guide)
        self.assertEqual(self.call("state")["state"]["controller"]["state"], "ready")
        state = self.call("demo")["state"]
        self.assertEqual(state["controller"]["state"], "active")
        proposal = next(p for p in state["proposals"] if p["status"] == "pending")
        self.call("approve", proposal=proposal["id"])
        self.assertEqual(self.bridge.calls[-1], ("demo:3", "send", proposal["prompt"]))
        with self.assertRaises(WorkspaceError):
            self.call("approve", proposal=proposal["id"])
        self.call("controller", enabled=False)
        with self.assertRaises(WorkspaceError):
            self.call("guide")

    def test_native_focus_notes_and_awake_persist(self):
        self.call("state")
        self.call("pin", session="demo:1")
        self.assertEqual(self.call("state")["state"]["next_session"], "demo:1")
        self.call("snooze", session="demo:1")
        s = next(s for s in self.call("state")["state"]["sessions"] if s["id"] == "demo:1")
        self.assertFalse(s["pinned"])
        self.assertFalse(s["needs_attention"])
        self.call("awake", duration="1h")
        self.assertEqual(self.call("state")["state"]["awake"]["state"], "1h")
        with patch.object(MacBridge, "discover", side_effect=AssertionError("Demo touched live terminal")):
            other = Workspace(self.temp.name, DemoBridge())
            self.assertEqual(dispatch(other, {})["state"]["awake"]["state"], "1h")

    def test_stale_state_allows_pause_and_retains_notes(self):
        self.call("controller", session="demo:1", enabled=True)
        with patch.object(self.bridge, "discover", side_effect=RuntimeError("Offline")):
            self.call("refresh")
            self.call("controller", enabled=False)
            self.call("pin", session="demo:1")
            with self.assertRaises(WorkspaceError):
                self.call("focus", session="demo:1")
        self.assertEqual(self.call("state")["state"]["controller"]["state"], "off")

    def test_invalid_native_input_never_calls_bridge(self):
        for request in [[], {"action": []}, {"action": "send"}, {"action": "focus", "session": {}},
                        {"action": "approve", "proposal": []}, {"action": "controller", "enabled": "true"}]:
            with self.assertRaises(WorkspaceError):
                dispatch(self.work, request)
        self.assertEqual(self.bridge.calls, [])

    def test_cached_view_does_not_request_os_access(self):
        self.call("state")
        with patch.object(self.bridge, "discover", side_effect=AssertionError("Permission is missing")):
            self.assertEqual(len(self.call("cached")["state"]["sessions"]), 6)

    def test_standalone_native_runtime_and_first_awake_use(self):
        source = Path(__file__).resolve().parent.parent
        runtime = Path(self.temp.name) / "standalone"
        (runtime / "dashboard").mkdir(parents=True)
        (runtime / "lib").mkdir()
        for name in ("__init__", "bridge", "core", "native", "cli"):
            shutil.copyfile(source / "dashboard" / (name + ".py"), runtime / "dashboard" / (name + ".py"))
        shutil.copyfile(source / "menubar/runtime.sh", runtime / "td")
        shutil.copyfile(source / "lib/awake.sh", runtime / "lib/awake.sh")
        (runtime / "td").chmod(0o755)
        env = dict(os.environ, TD_CONFIG_DIR=str(Path(self.temp.name) / "standalone-state"))
        def invoke(*args, payload=None):
            return subprocess.run([str(runtime / "td"), *args], input=json.dumps(payload or {}),
                                  capture_output=True, text=True, env=env, cwd="/", timeout=10)
        result = invoke("workspace", "--demo")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(json.loads(result.stdout)["state"]["sessions"]), 6)
        result = invoke("workspace", "--demo", payload={"action": "controller", "enabled": True, "session": "demo:1"})
        self.assertEqual(result.returncode, 0, result.stderr)
        result = invoke("agent", "guide", "--demo")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(str(runtime / "td"), json.loads(result.stdout)["text"])
        self.assertNotIn(str(source / "td"), json.loads(result.stdout)["text"])
        result = invoke("awake", "status")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("awake: off", result.stdout)

    def test_folder_permission_failure_is_explained(self):
        self.call("state")
        with patch.object(Path, "iterdir", side_effect=PermissionError("Desktop access denied")):
            state = self.call("cached")["state"]
        self.assertEqual(state["folders"], [])
        self.assertIn("Files & Folders", state["folders_error"])

    @unittest.skipUnless(sys.platform == "darwin", "macOS awake timer")
    def test_stale_awake_pid_cannot_stop_an_unrelated_process(self):
        sentinel = subprocess.Popen(["/bin/sleep", "30"])
        def cleanup():
            if sentinel.poll() is None:
                sentinel.terminate()
            sentinel.wait(timeout=3)
        self.addCleanup(cleanup)
        state = Path(self.temp.name) / "awake.state"
        state.write_text(json.dumps({"state": "1h", "pid": sentinel.pid, "end_ts": time.time()+3600}))
        self.bridge.demo = False
        self.assertEqual(self.work.awake_status()["state"], "off")
        cli = Path(__file__).resolve().parent.parent / "td"
        result = subprocess.run([str(cli), "awake", "off"], capture_output=True, text=True,
                                env=dict(os.environ, TD_CONFIG_DIR=self.temp.name), timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(sentinel.poll(), "Turning awake off must leave unrelated processes alone")
        self.assertFalse(is_awake_process(-1))
        self.assertFalse(is_awake_process(1))
        state.write_text("incomplete state {")
        result = subprocess.run([str(cli), "awake", "off"], capture_output=True, text=True,
                                env=dict(os.environ, TD_CONFIG_DIR=self.temp.name), timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(state.read_text())["state"], "off")

    @unittest.skipUnless(sys.platform == "darwin", "macOS awake timer")
    def test_awake_recognizes_and_stops_its_actual_timer(self):
        timer = subprocess.Popen(["/usr/bin/caffeinate", "-d", "-t", "30"])
        def cleanup():
            if timer.poll() is None:
                timer.terminate()
            timer.wait(timeout=3)
        self.addCleanup(cleanup)
        (Path(self.temp.name) / "awake.state").write_text(json.dumps({"state": "1h", "pid": timer.pid, "end_ts": time.time()+3600}))
        self.bridge.demo = False
        self.assertEqual(self.work.awake_status()["state"], "1h")
        cli = Path(__file__).resolve().parent.parent / "td"
        result = subprocess.run([str(cli), "awake", "off"], capture_output=True, text=True,
                                env=dict(os.environ, TD_CONFIG_DIR=self.temp.name), timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        timer.wait(timeout=3)

    def test_launch_quotes_paths_and_multiline_prompts(self):
        root = Path(self.temp.name)
        project = root / "Edward's $(touch unwanted)"; project.mkdir()
        prompt = "Read `not a command`\nthen explain $HOME and 'quotes'"
        for provider in ("claude", "claudex", "codex", "grok"):
            command = launch_command(str(project), provider, prompt, root)
            tokens = shlex.split(command)
            self.assertIn(str(project.resolve()), tokens)
            self.assertEqual(tokens[-1], prompt)
            self.assertIn(provider, tokens)
        grok = launch_command(str(project), "grok", prompt, root)
        self.assertIn("--always-approve", grok)
        hermes = launch_command(str(project), "hermes", prompt, root)
        self.assertTrue(hermes.endswith("hermes --yolo --cli"))
        self.assertNotIn("--oneshot", hermes)
        for folder, provider in [(str(root), "codex"), ("/tmp", "codex"), (str(project), "shell")]:
            with self.assertRaises(WorkspaceError):
                launch_command(folder, provider, prompt, root)

    def test_launch_transport_uses_argv_and_does_not_retry(self):
        self.bridge.demo = False
        with patch("dashboard.native.launch_command", return_value="quoted command"), patch("dashboard.native.run") as run:
            self.call("launch", folder="/any", provider="hermes", prompt="quoted 'prompt'\nnext line")
            self.assertEqual(run.call_args.args[0][-2:], ["quoted command", "quoted 'prompt'\nnext line"])
        with patch("dashboard.native.launch_command", return_value="quoted command"), patch("dashboard.native.run", side_effect=TimeoutError("late")) as run:
            with self.assertRaisesRegex(WorkspaceError, "Check iTerm"):
                self.call("launch", folder="/any", provider="codex")
            self.assertEqual(run.call_count, 1)

    def test_continue_prompt_mentions_handoff_file_and_stays_compact(self):
        root = Path(self.temp.name)
        (root / "NEXT_SESSION.md").write_text("resume here")
        session = {"provider": "codex", "project": "hiring_agent", "summary": "Careers restore done."}
        prompt = continue_prompt(session, "secret password=hunter2\nkeep going", "grok", root)
        self.assertIn("swapped to grok", prompt)
        self.assertIn("Read NEXT_SESSION.md first.", prompt)
        self.assertIn("untrusted context", prompt)
        self.assertIn("Leave the previous codex terminal running.", prompt)
        self.assertLessEqual(len(prompt), 8000)
        self.assertNotIn("hunter2", prompt)

    def test_swap_reads_source_and_does_not_send_into_it(self):
        result = self.call("swap", session="demo:3", provider="grok", folder=self.temp.name)["result"]
        self.assertIn("grok", result["message"])
        self.assertIn("untrusted context", result["prompt"])
        self.assertIn("penny_agent", result["prompt"])
        self.assertIn(("demo:3", "read", ""), self.bridge.calls)
        self.assertFalse(any(call[1] == "send" for call in self.bridge.calls))
        self.assertEqual(result["title"], "penny_agent")
        with self.assertRaisesRegex(WorkspaceError, "different agent"):
            self.call("swap", session="demo:3", provider="claude")
        with self.assertRaisesRegex(WorkspaceError, "Select a live terminal"):
            self.call("swap", provider="grok")

    def test_swap_transport_launches_destination_once(self):
        self.bridge.demo = False
        with patch.object(self.work, "session_action", return_value={"text": "recent work on hiring"}), \
             patch("dashboard.native.launch_command", return_value="quoted command") as launch, \
             patch("dashboard.native.source_window_title", return_value="hiring"), \
             patch("dashboard.native.apply_iterm_window_title") as apply_title, \
             patch("dashboard.native.run") as run:
            run.return_value = "NEW-SESSION-ID\n"
            self.call("swap", session="demo:3", provider="grok", folder="/any")
            self.assertEqual(launch.call_args.args[1], "grok")
            self.assertIn("recent work on hiring", launch.call_args.args[2])
            self.assertEqual(run.call_count, 1)
            self.assertEqual(run.call_args.args[0][-2:], ["quoted command", "hiring"])
            apply_title.assert_called_once_with("NEW-SESSION-ID", "hiring")

    def test_ensure_grok_compact_mode_is_sticky(self):
        path = Path(self.temp.name) / "grok.toml"
        ensure_grok_compact_mode(path)
        self.assertIn("compact_mode = true", path.read_text())
        ensure_grok_compact_mode(path)
        self.assertEqual(path.read_text().count("compact_mode = true"), 1)
        path.write_text("[ui]\ncompact_mode = false\nyolo = false\n")
        ensure_grok_compact_mode(path)
        text = path.read_text()
        self.assertIn("compact_mode = true", text)
        self.assertNotIn("compact_mode = false", text)
        self.assertIn("yolo = false", text)

    def test_fallback_title_keeps_short_window_names(self):
        self.assertEqual(source_window_title({"window_name": "hiring", "project": "hiring_agent", "name": "long | hiring_agent (codex)"}), "hiring")
        self.assertEqual(fallback_title({"name": "hiring", "project": "hiring_agent"}), "hiring")
        self.assertEqual(
            fallback_title({"name": "Elevate hiring page positioning | hiring_agent (codex)", "project": "hiring_agent"}),
            "hiring_agent",
        )

    def test_pick_source_title_prefers_window_title_field(self):
        self.assertEqual(pick_source_title("paypal", "paypal (python3)", "paypal", "x"), "paypal")
        self.assertEqual(
            pick_source_title("", "d2c_invoicing", "◑ Debtist reconciliation VAT and payments", "project"),
            "d2c_invoicing",
        )
        self.assertEqual(
            pick_source_title("", "Find Previously Worked Smart Catalog - grok", "⠙ status line", "dev_agent"),
            "dev_agent",
        )

    def test_window_id_for_session_walks_list_sessions(self):
        summary = _pb_str(1, "SESSION-GUID")
        node = _pb_bytes(2, _pb_bytes(1, summary))
        window = _pb_bytes(1, _pb_bytes(3, node)) + _pb_str(2, "pty-WINDOW")
        message = _pb_bytes(106, _pb_bytes(1, window))
        self.assertEqual(window_id_for_session(message, "SESSION-GUID"), "pty-WINDOW")
        self.assertEqual(window_id_for_session(message, "missing"), "")

    def test_source_window_title_uses_session_name_when_bar_shows_status(self):
        with patch("dashboard.native.run", return_value="\nd2c_invoicing\n◑ Debtist reconciliation VAT and payments\n"):
            self.assertEqual(source_window_title({
                "app": "iTerm2", "native_id": "guid",
                "window_name": "◑ Debtist reconciliation VAT and payments",
                "project": "invoice_template", "name": "d2c_invoicing (caffeinate)",
            }), "d2c_invoicing")

    def test_apply_iterm_window_title_rejects_empty_ids(self):
        self.assertFalse(apply_iterm_window_title("", "hiring"))
        self.assertFalse(apply_iterm_window_title("guid", ""))
        self.assertFalse(apply_iterm_window_title("guid", "hiring\nnext"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
