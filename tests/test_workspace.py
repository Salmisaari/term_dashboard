#!/usr/bin/env python3
"""Behavioral contract tests. Run: python3 -I tests/test_workspace.py"""
import concurrent.futures
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import urllib.error
import urllib.request

sys.path.append(str(Path(__file__).resolve().parent.parent))
from dashboard.bridge import BridgeError, DemoBridge, MacBridge, provider_for, project_for, redact
from dashboard.core import Workspace, WorkspaceError, REPORT_TTL
from dashboard.server import Server


class WorkspaceTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="td-test-")
        self.addCleanup(self.temp.cleanup)
        self.bridge = DemoBridge()
        self.work = Workspace(self.temp.name, self.bridge)
        self.work.refresh(force=True)
        self.work.configure_controller("demo:1", True)
        with self.work.db() as conn:
            self.token = self.work.get(conn, "controller")["token"]

    def report(self, sid="demo:3", status="waiting", summary="Ready for a prompt", evidence="Input prompt visible"):
        return self.work.report(sid, status, summary, evidence, self.token)

    def proposal(self):
        return self.work.propose("demo:3", "Run the focused tests", "Close the test loop", self.token)["id"]

    def test_exact_session_identity_with_duplicate_projects(self):
        edwards = [s for s in self.work.view()["sessions"] if s["project"] == "edward_agent"]
        self.assertEqual(len(edwards), 2)
        self.work.session_action("demo:6", "focus", self.token)
        self.assertEqual(self.bridge.calls, [("demo:6", "focus", "")])

    def test_revocation_and_switch_invalidate_previous_handoff(self):
        self.work.configure_controller(None, False)
        with self.assertRaisesRegex(WorkspaceError, "revoked"):
            self.work.session_action("demo:3", "focus", self.token)
        self.work.configure_controller("demo:2", True)
        with self.assertRaises(WorkspaceError):
            self.work.check(self.token)
        self.assertEqual(self.bridge.calls, [])

    def test_enabling_does_not_claim_agent_is_working(self):
        self.assertEqual(self.work.view()["controller"]["state"], "ready")
        self.work.check(self.token)
        self.assertEqual(self.work.view()["controller"]["state"], "active")
        self.assertNotIn("token", self.work.view()["controller"])

    def test_repeated_enable_is_idempotent(self):
        self.work.configure_controller("demo:1", True)
        self.assertTrue(self.work.check(self.token)["enabled"])

    def test_disconnected_controller_and_restarted_pid_cannot_act(self):
        self.bridge.sessions[0]["instance"] = "new-process"
        self.work.refresh(force=True)
        self.assertEqual(self.work.view()["controller"]["state"], "disconnected")
        with self.assertRaisesRegex(WorkspaceError, "restarted"):
            self.work.check(self.token)
        self.assertEqual(self.bridge.calls, [])

    def test_report_expiry_never_implies_readiness(self):
        self.report()
        with self.work.db() as conn:
            conn.execute("UPDATE reports SET updated=? WHERE session='demo:3'", (time.time()-REPORT_TTL-1,))
        s = next(s for s in self.work.view()["sessions"] if s["id"] == "demo:3")
        self.assertFalse(s["ready_to_send"])
        self.assertFalse(s["needs_attention"])
        self.assertIsNone(s["report_at"])
        self.assertEqual(s["status"], "running")

    def test_reports_do_not_follow_reused_processes(self):
        self.report()
        self.bridge.sessions[2]["instance"] = "replacement"
        self.work.refresh(force=True)
        s = next(s for s in self.work.view()["sessions"] if s["id"] == "demo:3")
        self.assertIsNone(s["report_at"])
        self.assertFalse(s["ready_to_send"])

    def test_done_requires_evidence(self):
        with self.assertRaisesRegex(WorkspaceError, "evidence"):
            self.report(status="done", evidence="")
        self.report(status="done", evidence="24 tests passed")
        self.assertEqual(next(s for s in self.work.view()["sessions"] if s["id"] == "demo:3")["evidence"], "24 tests passed")

    def test_acknowledge_only_hides_current_update(self):
        self.report()
        self.work.note("demo:3", "acknowledge")
        self.assertFalse(next(s for s in self.work.view()["sessions"] if s["id"] == "demo:3")["needs_attention"])
        self.report(summary="A new decision is needed")
        self.assertTrue(next(s for s in self.work.view()["sessions"] if s["id"] == "demo:3")["needs_attention"])

    def test_only_one_focus_and_snooze_preserves_session(self):
        self.work.note("demo:1", "pin")
        self.work.note("demo:3", "pin")
        self.assertEqual([s["id"] for s in self.work.view()["sessions"] if s["pinned"]], ["demo:3"])
        self.work.note("demo:3", "snooze")
        view = self.work.view()
        self.assertEqual([s["id"] for s in view["sessions"] if s["pinned"]], [])
        self.assertEqual(len(view["sessions"]), 6)
        self.assertFalse(next(s for s in view["sessions"] if s["id"] == "demo:3")["needs_attention"])

    def test_failed_discovery_preserves_snapshot_but_blocks_actions(self):
        with patch.object(self.bridge, "discover", side_effect=BridgeError("Automation unavailable")):
            self.work.refresh(force=True)
            self.assertEqual(len(self.work.view()["sessions"]), 6)
            self.assertTrue(self.work.view()["stale"])
            with self.assertRaises(WorkspaceError):
                self.work.session_action("demo:3", "focus", self.token)
            self.work.configure_controller(None, False)  # Always allow pausing.
        self.assertEqual(self.bridge.calls, [])

    def test_shell_cannot_be_navigator_or_prompt_target(self):
        with self.assertRaises(WorkspaceError):
            self.work.configure_controller("demo:6", True)
        with self.assertRaises(WorkspaceError):
            self.work.propose("demo:6", "echo hello", "test", self.token)

    def test_proposal_is_held_and_duplicate_is_coalesced(self):
        ident = self.proposal()
        self.assertEqual(self.proposal(), ident)
        self.assertEqual(self.bridge.calls, [])
        self.assertEqual(self.work.view()["proposals"][0]["status"], "pending")

    def test_proposal_delivers_exact_text_once(self):
        prompt = 'Review "quoted text"\nDo not run $(touch /tmp/td-should-not-exist)'
        self.report()
        ident = self.work.propose("demo:3", prompt, "Verify literal transport", self.token)["id"]
        self.work.resolve_proposal(ident, "approve")
        self.assertEqual(self.bridge.calls, [("demo:3", "send", prompt)])
        with self.assertRaises(WorkspaceError):
            self.work.resolve_proposal(ident, "approve")
        self.assertEqual(len(self.bridge.calls), 1)
        self.assertEqual(self.work.view()["proposals"][0]["status"], "delivered")

    def test_busy_and_restarted_targets_reject_delivery(self):
        ident = self.proposal()
        self.report(status="running")
        with self.assertRaisesRegex(WorkspaceError, "waiting"):
            self.work.resolve_proposal(ident, "approve")
        self.bridge.sessions[2]["instance"] = "replacement"
        with self.assertRaisesRegex(WorkspaceError, "restarted"):
            self.work.resolve_proposal(ident, "approve")
        self.assertEqual(self.bridge.calls, [])

    def test_two_workers_cannot_send_same_proposal_twice(self):
        self.report()
        ident = self.proposal()
        other = Workspace(self.temp.name, self.bridge)
        def approve(work):
            try:
                work.resolve_proposal(ident, "approve")
                return True
            except WorkspaceError:
                return False
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(approve, [self.work, other]))
        self.assertEqual(sum(results), 1)
        self.assertEqual(len(self.bridge.calls), 1)

    def test_two_proposals_cannot_consume_one_waiting_report(self):
        self.report()
        first = self.proposal()
        second = self.work.propose("demo:3", "Review the result", "Follow up", self.token)["id"]
        self.work.resolve_proposal(first, "approve")
        with self.assertRaises(WorkspaceError):
            self.work.resolve_proposal(second, "approve")
        self.assertEqual(len(self.bridge.calls), 1)

    def test_delivery_timeout_is_uncertain_and_never_retried(self):
        ident = self.proposal()
        with patch.object(self.bridge, "perform", side_effect=BridgeError("timeout")) as perform:
            with self.assertRaisesRegex(WorkspaceError, "uncertain"):
                self.work.resolve_proposal(ident, "approve")
            with self.assertRaises(WorkspaceError):
                self.work.resolve_proposal(ident, "approve")
            self.assertEqual(perform.call_count, 1)
        self.assertEqual(self.work.view()["proposals"][0]["status"], "uncertain")

    def test_revoke_cancels_pending_proposals(self):
        self.proposal()
        self.work.configure_controller(None, False)
        self.assertEqual(self.work.view()["proposals"][0]["status"], "cancelled")

    def test_state_persists_and_demo_is_isolated(self):
        self.work.note("demo:3", "pin")
        self.report(summary="Persistent update")
        new = Workspace(self.temp.name, DemoBridge())
        self.assertEqual(new.view()["next_session"], "demo:3")
        self.assertTrue(any(e["message"] == "Persistent update" for e in new.view()["events"]))
        live = Workspace(self.temp.name, MacBridge(self.temp.name))
        self.assertEqual(live.view()["sessions"], [])
        self.assertNotEqual(new.path, live.path)

    def test_demo_loop_produces_real_workflow_receipts(self):
        self.work.demo_loop()
        view = self.work.view()
        self.assertEqual(view["controller"]["state"], "active")
        self.assertEqual(view["proposals"][0]["status"], "pending")
        self.work.resolve_proposal(view["proposals"][0]["id"], "approve")
        self.assertTrue(any(e["kind"] == "delivered" for e in self.work.view()["events"]))


class AdapterTest(unittest.TestCase):
    def test_bulk_inventory_resolves_process_directories_without_changing_identity(self):
        def command(argv, timeout=12):
            if argv[0] == 'ps':
                return ('101 1 s001 S+ Sat Sep 5 22:00:00 2026 codex\n'
                        '201 1 s002 S+ Sat Sep 5 22:01:00 2026 codex\n')
            if argv[0] == 'osascript':
                return json.dumps([
                    {'native_id': 'edward-one', 'tty': '/dev/ttys001', 'name': 'Edward', 'window': '42'},
                    {'native_id': 'edward-two', 'tty': '/dev/ttys002', 'name': 'Edward', 'window': '43'},
                ]) if 'iTerm2' in argv[2] else '[]'
            if argv[0] == '/usr/sbin/lsof':
                self.assertIn('101,201', argv)
                return 'p101\nn/code/edward_agent\np201\nn/code/edward_agent\n'
            raise AssertionError(argv)
        with tempfile.TemporaryDirectory() as config, patch('dashboard.bridge.run', side_effect=command):
            sessions, warnings = MacBridge(config).discover()
        self.assertEqual(warnings, [])
        self.assertEqual([s['project'] for s in sessions], ['edward_agent', 'edward_agent'])
        self.assertEqual([s['id'] for s in sessions], ['iTerm2:edward-one', 'iTerm2:edward-two'])
        self.assertNotEqual(sessions[0]['instance'], sessions[1]['instance'])

    def test_native_discovery_normalizes_mac_tty_and_excludes_helpers(self):
        def command(argv, timeout=12):
            if argv[0] == 'ps':
                return ('101 1 s001 S+ Sat Sep 5 22:00:00 2026 codex\n'
                        '102 101 s001 S Sat Sep 5 22:00:01 2026 /Users/me/.codex/bin/codex-code-mode-host\n')
            if argv[0] == 'osascript':
                return json.dumps([{'native_id':'exact-id','tty':'/dev/ttys001','name':'Edward (codex)',
                                    'window':'42','cwd':'/code/edward_agent'}]) if 'iTerm2' in argv[2] else '[]'
            raise AssertionError('iTerm CWD should avoid lsof: ' + repr(argv))
        with tempfile.TemporaryDirectory() as config, patch('dashboard.bridge.run', side_effect=command):
            sessions, warnings = MacBridge(config).discover()
        self.assertEqual(warnings, [])
        self.assertEqual(len(sessions), 1)
        self.assertEqual(sessions[0]['provider'], 'codex')
        self.assertEqual(sessions[0]['project'], 'edward_agent')
        self.assertTrue(sessions[0]['instance'].startswith('101:'))

    def test_agent_titles_cannot_impersonate_a_live_process(self):
        self.assertEqual(provider_for(['/bin/zsh'], 'edward (codex)'), 'shell')
        self.assertEqual(provider_for(['/opt/bin/codex']), 'codex')
        self.assertEqual(provider_for(['/bin/claudex']), 'claudex')
        self.assertEqual(provider_for(['/Users/me/.grok/bin/grok']), 'grok')
        self.assertEqual(provider_for(['/usr/bin/notcodex']), 'shell')
        self.assertEqual(provider_for(['/Users/me/.codex/bin/codex-code-mode-host']), 'shell')

    def test_longest_project_boundary_wins(self):
        registry = {'parent': {'path': '/code/app'}, 'child': {'path': '/code/app/child'}}
        self.assertEqual(project_for('/code/app/child/src', registry), 'child')
        self.assertEqual(project_for('/code/application', registry), 'application')

    def test_bound_and_mask_terminal_content(self):
        text = 'api_key=secret_value\n' + 'a\n'*150 + 'password=hidden\nghp_abcdefghijklmnopqrstuvwxyz12345'
        result = redact(text)
        self.assertLessEqual(len(result.splitlines()), 100)
        self.assertNotIn('hidden', result)
        self.assertNotIn('ghp_', result)


class HTTPTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="td-http-test-")
        self.work = Workspace(self.temp.name, DemoBridge())
        self.work.refresh()
        self.server = Server(("127.0.0.1", 0), self.work)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = self.server.origin
        self.addCleanup(self.cleanup)

    def cleanup(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.temp.cleanup()

    def request(self, path, body=None, token=True, headers=None):
        h = {'Content-Type': 'application/json'}
        if token:
            h['X-TD-Token'] = self.server.token
        h.update(headers or {})
        req = urllib.request.Request(self.url+path, data=None if body is None else json.dumps(body).encode(), headers=h)
        try:
            response = urllib.request.urlopen(req, timeout=5)
        except urllib.error.HTTPError as exc:
            response = exc
        with response:
            return response.status, response.read().decode(), response.headers

    def test_browser_bootstrap_and_inventory(self):
        code, html, headers = self.request('/', token=False)
        self.assertEqual(code, 200)
        self.assertIn(self.server.token, html)
        self.assertIn("frame-ancestors 'none'", headers['Content-Security-Policy'])
        code, body, _ = self.request('/api/state')
        self.assertEqual(code, 200)
        self.assertEqual(json.loads(body)['counts']['total'], 6)

    def test_auth_origin_and_host_are_enforced(self):
        self.assertEqual(self.request('/api/state', token=False)[0], 403)
        self.assertEqual(self.request('/api/note', {'action':'pin','session':'demo:1'}, headers={'Origin':'https://evil.example'})[0], 403)
        self.assertEqual(self.request('/api/state', headers={'Host':'evil.example'})[0], 403)
        self.assertEqual(self.request('/api/state', headers={'X-TD-Token':'wrong'})[0], 403)

    def test_malformed_body_and_unknown_routes(self):
        self.assertEqual(self.request('/api/controller', [1,2,3])[0], 400)
        self.assertEqual(self.request('/api/controller', {'enabled':'yes','session':'demo:1'})[0], 400)
        self.assertEqual(self.request('/../../README.md')[0], 404)
        self.assertEqual(self.request('/api/execute', {'command':'ls'})[0], 404)

    def test_http_edward_review_loop(self):
        self.assertEqual(self.request('/api/demo', {})[0], 200)
        view = json.loads(self.request('/api/state')[1])
        self.assertEqual(view['controller']['state'], 'active')
        proposal = view['proposals'][0]
        code, data, _ = self.request('/api/proposal', {'id':proposal['id'],'action':'approve'})
        self.assertEqual(code, 200, data)
        self.assertEqual(self.request('/api/proposal', {'id':proposal['id'],'action':'approve'})[0], 400)
        self.assertEqual(self.request('/api/controller', {'enabled':False})[0], 200)
        self.assertEqual(self.request('/api/guide')[0], 400)


if __name__ == '__main__':
    unittest.main(verbosity=2)
