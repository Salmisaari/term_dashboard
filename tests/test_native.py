#!/usr/bin/env python3
"""Native transport behavior, exercised without opening or messaging real terminals."""
import json
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.append(str(Path(__file__).resolve().parent.parent))
from dashboard.bridge import DemoBridge, MacBridge
from dashboard.core import Workspace, WorkspaceError
from dashboard.native import dispatch, launch_command


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

    def test_launch_quotes_paths_and_multiline_prompts(self):
        root = Path(self.temp.name)
        project = root / "Edward's $(touch unwanted)"; project.mkdir()
        prompt = "Read `not a command`\nthen explain $HOME and 'quotes'"
        for provider in ("claude", "claudex", "codex"):
            command = launch_command(str(project), provider, prompt, root)
            tokens = shlex.split(command)
            self.assertIn(str(project.resolve()), tokens)
            self.assertEqual(tokens[-1], prompt)
            self.assertIn(provider, tokens)
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
