#!/usr/bin/env python3
"""Optional E2E: python3 -I tests/test-workspace-browser.py (Playwright + Chrome)."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

from playwright.sync_api import sync_playwright, expect

ROOT = Path(__file__).resolve().parent.parent

with tempfile.TemporaryDirectory(prefix='td-browser-state-') as config:
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    url = f'http://127.0.0.1:{port}'
    env = dict(os.environ, TD_CONFIG_DIR=config)
    service = subprocess.Popen([sys.executable, '-B', '-I', str(ROOT/'dashboard/cli.py'), 'dashboard', 'serve',
                                '--demo', '--no-open', '--port', str(port)], env=env,
                                cwd=tempfile.gettempdir(), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        for _ in range(120):
            try:
                with urllib.request.urlopen(url+'/health', timeout=1) as response:
                    if response.status == 200:
                        break
            except OSError:
                if service.poll() is not None:
                    raise RuntimeError(service.stderr.read().decode())
                time.sleep(.25)
        else:
            raise RuntimeError('Demo service did not start within 30 seconds')
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True, channel='chrome')
            page = browser.new_page(viewport={'width':1440,'height':1000}, device_scale_factor=1)
            page.emulate_media(reduced_motion='reduce')
            errors = []
            page.on('pageerror', lambda error: errors.append(str(error)))
            page.goto(url, wait_until='networkidle')
            expect(page.locator('#overview-view')).to_be_visible()
            page.locator('#navigator-select').select_option('demo:1')
            page.locator('#navigation-toggle').click(force=True)
            expect(page.locator('#navigator-state')).to_contain_text('awaiting check-in')
            page.locator('#handoff-button').click(force=True)
            expect(page.locator('#handoff-dialog')).to_be_visible()
            assert 'TD_AGENT_TOKEN=' in page.locator('#handoff-text').input_value()
            assert 'TD_CONFIG_DIR=' in page.locator('#handoff-text').input_value()
            page.get_by_role('button', name='Close agent handoff', exact=True).click(force=True)
            page.locator('#demo-walkthrough').click(force=True)
            expect(page.locator('#activity-view')).to_be_visible()
            expect(page.locator('.proposal-card').first).to_contain_text('Penny')
            page.locator('.proposal-card').first.get_by_role('button', name='Inspect terminal').click(force=True)
            page.locator('#inspect-button').click(force=True)
            expect(page.locator('#terminal-output')).to_contain_text('no live terminal output')
            page.get_by_role('button', name='Close terminal details', exact=True).click(force=True)
            page.get_by_role('button', name='Approve & send').first.click(force=True)
            expect(page.locator('#all-events')).to_contain_text('Approved prompt delivered')
            page.keyboard.press('2')
            page.locator('#session-search').fill('edward')
            expect(page.locator('#all-sessions .session-row')).to_have_count(2)
            page.locator('#all-sessions .session-main').first.click(force=True)
            page.get_by_role('button', name='Make this my focus').click(force=True)
            expect(page.locator('#detail-dialog')).not_to_be_visible()
            page.keyboard.press('1')
            expect(page.locator('#focus-title')).to_contain_text('is your focus')
            page.locator('#navigation-toggle').click(force=True)
            expect(page.locator('#navigation-toggle')).to_have_attribute('aria-checked','false')
            # A disabled navigator cannot expose an active handoff.
            expect(page.locator('#handoff-button')).to_be_disabled()
            page.set_viewport_size({'width':390,'height':844})
            assert page.evaluate('document.documentElement.scrollWidth <= innerWidth'), 'Mobile horizontal overflow'
            page.keyboard.press('2')
            page.locator('#session-search').fill('no-such-terminal')
            expect(page.locator('#all-sessions')).to_contain_text('No matching terminals')
            page.locator('#session-search').fill('')
            assert page.evaluate('document.documentElement.scrollWidth <= innerWidth'), 'Session list overflow'
            # HTTP outage keeps last data but disables the navigator control.
            page.route('**/api/state', lambda route: route.abort())
            page.evaluate("document.dispatchEvent(new Event('visibilitychange'))")
            expect(page.locator('#error-banner')).to_contain_text('Connection paused', timeout=10000)
            page.keyboard.press('Tab')
            assert not errors, errors
            print(json.dumps({'result':'PASS','flows':['handoff','Edward check-in','inspection','proposal approval',
                'delivery receipt','duplicate session search','pin','revoke','responsive layout','empty search','connection recovery'],
                'browser_errors':errors}))
            browser.close()
    finally:
        service.terminate()
        try:
            service.wait(timeout=10)
        except subprocess.TimeoutExpired:
            service.kill()
            service.wait()
        service.stderr.close()
