"""Client failure boundaries; never changes this Mac's power settings."""
import json
from pathlib import Path
import socket
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.path.append(str(Path(__file__).resolve().parent.parent))
from dashboard import awake


class AwakeClientTest(unittest.TestCase):
    def setUp(self):
        self.config = Path.home() / '.config/td'

    def test_missing_helper_does_not_claim_protection(self):
        with patch.object(awake, 'request', side_effect=FileNotFoundError), patch.object(awake, 'legacy_status', return_value={'state': 'off', 'closed_lid': False}):
            self.assertFalse(awake.status(self.config)['closed_lid'])
            with self.assertRaisesRegex(RuntimeError, 'td awake setup'):
                awake.change('1h', self.config)

    def test_failed_start_preserves_existing_legacy_timer(self):
        with patch.object(awake, 'request', return_value={'state': 'off', 'error': 'battery too low'}), patch.object(awake, 'stop_legacy') as stop:
            with self.assertRaisesRegex(RuntimeError, 'battery too low'):
                awake.change('4h', self.config)
            stop.assert_not_called()

    def test_successful_start_retires_legacy_timer(self):
        result = {'state': '4h', 'closed_lid': True}
        with patch.object(awake, 'request', return_value=result) as request, patch.object(awake, 'stop_legacy') as stop:
            self.assertEqual(awake.change('4h', self.config), result)
            request.assert_called_once_with('start', '4h')
            stop.assert_called_once_with(self.config)

    def test_isolated_configs_never_call_machine_service(self):
        with tempfile.TemporaryDirectory() as config, patch.object(awake, 'request') as request:
            self.assertEqual(awake.status(config)['state'], 'off')
            awake.change('off', config)
            with self.assertRaisesRegex(RuntimeError, 'isolated'):
                awake.change('1h', config)
            request.assert_not_called()

    def test_status_timeout_is_visible_not_false_success(self):
        with patch.object(awake, 'request', side_effect=socket.timeout('timed out')):
            status = awake.status(self.config)
            self.assertFalse(status['closed_lid'])
            self.assertIn('timed out', status['error'])

    def test_invalid_duration_never_calls_service(self):
        with patch.object(awake, 'request') as request:
            with self.assertRaises(ValueError):
                awake.change('1h; id', self.config)
            request.assert_not_called()

    def test_malformed_legacy_state_is_off(self):
        with tempfile.TemporaryDirectory() as config:
            for value in ('null', '[]', '"off"', '{"pid": {}}', '{'):
                (Path(config) / 'awake.state').write_text(value)
                self.assertEqual(awake.legacy_status(config)['state'], 'off')

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS peer credentials')
    def test_real_socket_rejects_non_root_server(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / 'control.sock')
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(path)
                server.listen(1)
                server.settimeout(3)
                def accept():
                    connection, _ = server.accept()
                    connection.close()
                thread = threading.Thread(target=accept)
                thread.start()
                try:
                    with patch.object(awake, 'SOCKET', path):
                        with self.assertRaisesRegex(RuntimeError, 'not owned by root'):
                            awake.request('status')
                finally:
                    thread.join(timeout=3)


if __name__ == '__main__':
    unittest.main(verbosity=2)
