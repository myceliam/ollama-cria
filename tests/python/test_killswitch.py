"""Tests for linux/stages/10-killswitch.py, Stage 10's kill-switch test.

Run: python -m unittest discover -s tests/python -v

The network calls are replaced: these tests check the order of what the
script does to the tunnel, that it always starts the tunnel again, and
that it prints only facts.
"""

import contextlib
import importlib.util
import io
import json
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[2] / 'linux' / 'stages' / '10-killswitch.py'


def load():
    spec = importlib.util.spec_from_file_location('killswitch', SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Tunnel:
    """gluetun's control server: remembers each status it was set to."""

    def __init__(self, status='running', refuse_stop=False, restarts=False):
        self.status = status
        self.calls = []
        self.refuse_stop = refuse_stop
        self.restarts = restarts

    def control(self, status=None):
        self.calls.append(status or 'get')
        if status == 'stopped' and self.refuse_stop:
            raise OSError('HTTP Error 401: Unauthorized')
        if status:
            self.status = status
        elif self.restarts and self.status == 'stopped':
            self.status = 'running'
        return self.status


class KillSwitchTests(unittest.TestCase):

    def run_main(self, ks, tunnel, **patches):
        out = io.StringIO()
        up = lambda: tunnel.status == 'running'
        defaults = {
            'control': tunnel.control,
            'tcp': lambda family, address, timeout=8: 'connected' if up() else 'blocked',
            'lookup': lambda name: 'resolved' if up() else 'no-address',
            'gateway': lambda path, body, timeout: 'ok' if up() else 'network_error',
            'reader': lambda url, timeout=40: 'read' if up() else 'blocked',
            'searxng': lambda query, timeout=30: 'results' if up() else 'none',
            'proxy': lambda port, timeout=15: 'connected' if up() else 'blocked',
            'plain_dns': lambda server, timeout=5: 'no-answer',
        }
        defaults.update(patches)
        with contextlib.ExitStack() as stack:
            for name, fake in defaults.items():
                stack.enter_context(mock.patch.object(ks, name, fake))
            stack.enter_context(mock.patch.object(ks.time, 'sleep', lambda s: None))
            stack.enter_context(contextlib.redirect_stdout(out))
            code = ks.main()
        lines = out.getvalue().splitlines()
        facts = dict(line.split(' ', 2)[1:] for line in lines if line.startswith('FACT '))
        return code, lines, facts

    def test_everything_fails_closed_then_the_tunnel_comes_back(self):
        ks = load()
        tunnel = Tunnel()
        code, lines, facts = self.run_main(ks, tunnel)
        self.assertEqual(code, 0)
        self.assertEqual(tunnel.calls, ['get', 'stopped', 'get', 'running'])
        self.assertEqual(tunnel.status, 'running')
        self.assertEqual(facts['ks_search'], 'network_error')
        self.assertEqual(facts['ks_read'], 'network_error')
        for name in ('tcp4', 'tcp6', 'proxy_8888', 'proxy_8889', 'reader'):
            self.assertEqual(facts['ks_' + name], 'blocked', name)
        self.assertEqual(facts['ks_searxng'], 'none')
        self.assertEqual(facts['ks_dns_new_name'], 'no-address')
        self.assertEqual(facts['ks_dns_plain_1'], 'no-answer')
        self.assertEqual(facts['ks_still_stopped'], 'yes')
        self.assertEqual(facts['ks_recovered'], 'yes')
        for line in lines:
            self.assertRegex(line, r'^(FACT ks_[a-z0-9_]+ [a-z_-]+|STEP .+)$')

    def test_a_leak_is_reported_and_the_tunnel_still_comes_back(self):
        ks = load()
        tunnel = Tunnel()
        code, _, facts = self.run_main(ks, tunnel, plain_dns=lambda server, timeout=5: 'answered',
                                       tcp=lambda family, address, timeout=8: 'connected')
        self.assertEqual(code, 0)
        self.assertEqual(facts['ks_dns_plain_2'], 'answered')
        self.assertEqual(facts['ks_tcp4'], 'connected')
        self.assertEqual(tunnel.calls[-1], 'running')

    def test_gluetun_starting_the_tunnel_on_its_own_is_reported(self):
        ks = load()
        code, _, facts = self.run_main(ks, Tunnel(restarts=True))
        self.assertEqual(code, 0)
        self.assertEqual(facts['ks_still_stopped'], 'no')

    def test_a_tunnel_that_does_not_work_before_changes_nothing(self):
        ks = load()
        tunnel = Tunnel()
        code, lines, _ = self.run_main(ks, tunnel, tcp=lambda family, address, timeout=8: 'blocked')
        self.assertEqual(code, 1)
        self.assertNotIn('stopped', tunnel.calls)
        self.assertTrue(any(line.startswith('FAIL the tunnel does not work before the test') for line in lines))

    def test_a_refused_stop_changes_nothing_and_says_so(self):
        ks = load()
        tunnel = Tunnel(refuse_stop=True)
        code, lines, _ = self.run_main(ks, tunnel)
        self.assertEqual(code, 1)
        self.assertEqual(tunnel.status, 'running')
        self.assertTrue(any("would not stop the tunnel (OSError)" in line for line in lines))
        self.assertNotIn('401', '\n'.join(lines))

    def test_each_run_asks_for_something_no_cache_holds(self):
        ks = load()
        asked = []

        def gateway(path, body, timeout):
            asked.append(json.dumps(body, sort_keys=True))
            return 'ok' if path == '/search' and len(asked) > 2 else 'network_error'

        self.run_main(ks, Tunnel(), gateway=gateway)
        first = asked[:2]
        asked.clear()
        self.run_main(ks, Tunnel(), gateway=gateway)
        self.assertNotEqual(first, asked[:2])

    def test_the_tunnel_is_started_again_when_a_probe_crashes(self):
        ks = load()
        tunnel = Tunnel()

        def crash(url, timeout=40):
            raise RuntimeError('boom')

        with self.assertRaises(RuntimeError):
            self.run_main(ks, tunnel, reader=crash)
        self.assertEqual(tunnel.calls[-1], 'running')
        self.assertEqual(tunnel.status, 'running')


if __name__ == '__main__':
    unittest.main()
